import Foundation

/// Checks of cutting and transcripts that don't need whisper: synthetic "speech" with known word, filler and
/// cough positions, and a transcript built by hand.
extension SelfTest {
    struct Programme {
        let audio: PlanarBuffer
        let vad: [Float]
        let words: [Transcript.Word]
        let filler: ClosedRange<Double>
        let cough: ClosedRange<Double>
        let spoken: [ClosedRange<Double>]
    }

    /// Word, gap, "um", gap, word, pause, cough, pause, word, over a faint noise floor.
    static func syntheticProgramme() -> Programme {
        let rate = 48000.0
        var x: [Float] = []
        var spans: [(String, ClosedRange<Double>)] = []
        func add(_ samples: [Float], _ label: String? = nil) {
            let start = Double(x.count) / rate
            x += samples
            if let label { spans.append((label, start...(Double(x.count) / rate))) }
        }
        func silence(_ s: Double) -> [Float] { [Float](repeating: 0, count: Int(s * rate)) }
        func voiced(_ f0: Double, _ seconds: Double) -> [Float] {
            let n = Int(seconds * rate)
            return (0..<n).map { i in
                let t = Double(i) / rate
                let fade = min(1, t / 0.01, (seconds - t) / 0.01)
                let s = (1...10).reduce(0.0) { $0 + sin(2 * .pi * f0 * Double($1) * t) / Double($1) }
                return Float(0.15 * fade * s)
            }
        }
        func cough(_ seconds: Double) -> [Float] {
            let n = noise(1, count: Int(seconds * rate), seed: 7)
            return n.enumerated().map { i, v in
                let t = Double(i) / rate
                return Float(0.5 * min(1, t / 0.005) * exp(-t / 0.05)) * v
            }
        }
        add(silence(0.3)); add(voiced(180, 0.45), "Hello"); add(silence(0.12)); add(voiced(120, 0.3), "um")
        add(silence(0.15)); add(voiced(200, 0.5), "there"); add(silence(0.6)); add(cough(0.3), "cough")
        add(silence(0.6)); add(voiced(170, 0.4), "again."); add(silence(0.3))
        let floor = noise(0.0003, count: x.count, seed: 3)
        let audio = PlanarBuffer([zip(x, floor).map { $0 + $1 }])

        let block = Double(Mastering.block) / rate
        let speech = spans.filter { $0.0 != "cough" }.map(\.1)
        let vad: [Float] = (0..<(x.count / Mastering.block + 1)).map { b in
            let t = (Double(b) + 0.5) * block
            return speech.contains { $0.contains(t) } ? 1 : 0
        }
        // Anchors where whisper's alignment tends to put them: late in the word, a little off.
        let words = spans.filter { $0.0 != "cough" }.enumerated().map { i, s -> Transcript.Word in
            let d = s.1.upperBound - s.1.lowerBound
            let anchor = s.1.lowerBound + d * 0.75 + (i.isMultiple(of: 2) ? 0.04 : -0.03)
            return Transcript.Word(text: s.0, start: s.1.lowerBound, end: s.1.upperBound, anchor: anchor, probability: 0.9)
        }
        return Programme(audio: audio, vad: vad, words: words, filler: spans[1].1, cough: spans[3].1,
                         spoken: [spans[0].1, spans[2].1, spans[4].1])
    }

    static func fillerAndCoughPlacement() -> Result {
        let p = syntheticProgramme()
        var options = Cutting.Options()
        options.fillers = true
        options.coughs = true
        let cuts = Cutting.detect(p.audio, original: p.audio, vad: p.vad, words: p.words, options: options)
        let blind = Cutting.detect(p.audio, original: p.audio, vad: p.vad, words: nil, options: options)

        func covers(_ c: EditCut?, _ r: ClosedRange<Double>) -> Bool {
            guard let c else { return false }
            return c.start <= r.lowerBound + 0.01 && c.end >= r.upperBound - 0.02
        }
        let filler = cuts.first { $0.kind == .filler }, cough = cuts.first { $0.kind == .cough }
        // Every cut stays at least 10 ms clear of the real words.
        let clearance = cuts.flatMap { c in p.spoken.map { w in max(w.lowerBound - c.end, c.start - w.upperBound) } }.min() ?? 0
        let ok = cuts.count == 2 && covers(filler, p.filler) && covers(cough, p.cough) && clearance >= 0.01
            && blind.count == 1 && covers(blind.first, p.cough)
        let detail = cuts.map { String(format: "%@ %.2f–%.2f", $0.label, $0.start, $0.end) }.joined(separator: ", ")
            + String(format: " (truth um %.2f–%.2f, cough %.2f–%.2f; %.0f ms clear of words; %d without transcript)",
                     p.filler.lowerBound, p.filler.upperBound, p.cough.lowerBound, p.cough.upperBound, clearance * 1000, blind.count)
        return Result(name: "Filler and cough cuts land on them", passed: ok, detail: detail)
    }

    static func cutEditing() -> Result {
        let rate = 48000.0
        let ramp = PlanarBuffer([(0..<Int(3 * rate)).map { Float(Double($0) / rate) }])   // each sample holds its own time
        var skipped = EditCut(kind: .cough, start: 1.2, end: 1.3, label: "kept")
        skipped.accepted = false
        let map = TimeMap(cuts: [EditCut(kind: .silence, start: 0.5, end: 1.0, label: ""), skipped,
                                 EditCut(kind: .filler, start: 2.0, end: 2.2, label: "")])
        let out = Cutting.apply(ramp, map: map)
        let expected = Int(3 * rate) - Int(0.7 * rate) - 2 * Int(TimeMap.fade * rate)
        var worst = 0.0
        for t in [0.25, 1.25, 1.5, 1.9, 2.5, 2.9] {
            let m = map.map(t)!
            worst = max(worst, abs(Double(out.channel(0)[Int((m * rate).rounded())]) - t))
        }
        let ok = out.frames == expected && worst < 0.001 && map.map(0.7) == nil && map.map(2.1) == nil
        return Result(name: "Cuts and time map agree", passed: ok,
                      detail: "\(out.frames) frames (expected \(expected)), worst timing error \(String(format: "%.2f", worst * 1000)) ms")
    }

    static func subtitles() -> Result {
        func w(_ text: String, _ s: Double, _ e: Double) -> Transcript.Word {
            Transcript.Word(text: text, start: s, end: e, anchor: (s + e) / 2, probability: 1)
        }
        let t = Transcript(language: "en", words: [w("Hello", 0.5, 0.9), w("world.", 0.9, 1.4), w("Um,", 1.6, 1.9),
                                                  w("this", 2.0, 2.2), w("is", 2.2, 2.3), w("fine.", 2.3, 2.8)])
        let map = TimeMap(cuts: [EditCut(kind: .filler, start: 1.55, end: 1.95, label: "um")])
        let srt = t.export(.srt, map: map)
        let expected = "1\n00:00:00,500 --> 00:00:01,400\nHello world.\n\n2\n00:00:01,585 --> 00:00:02,385\nThis is fine.\n"
        return Result(name: "Subtitles follow the edit", passed: srt == expected,
                      detail: srt == expected ? "fillers dropped, times shifted, sentence re-capitalised" : srt.debugDescription)
    }
}
