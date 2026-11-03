import Foundation

/// Checks of intro/outro ducking, multitrack crossgating and chapters.
extension SelfTest {
    static func musicDucking() -> Result {
        let rate = 48000.0
        // Programme: 2 s of "speech" (a 600 Hz tone). Intro: 6 s of 220 Hz "music" that overlaps it by 3 s.
        let program = PlanarBuffer([sine(600, amplitude: 0.3, seconds: 2)])
        let music = sine(220, amplitude: 0.3, seconds: 6)
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ven-selftest-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let intro = dir.appendingPathComponent("intro.wav")
            try AudioIO.write(PlanarBuffer([music]), to: intro, format: .wav24)
            var s = MasteringSettings()
            s.introPath = intro.path
            s.introOverlap = 3
            s.duckingDB = 15
            let (out, start) = try Production.addIntroOutro(program, settings: s)
            let x = out.array(0)
            let before = goertzelDB(x[Int(1.0 * rate)..<Int(2.0 * rate)], 220)
            let under = goertzelDB(x[Int(3.8 * rate)..<Int(4.8 * rate)], 220)
            let speech = goertzelDB(x[Int(3.8 * rate)..<Int(4.8 * rate)], 600)
            let ducked = before - under
            let ok = abs(start - 3) < 0.01 && abs(ducked - 15) < 2 && speech > under + 10
            return Result(name: "Intro music ducks under speech", passed: ok,
                          detail: String(format: "programme starts at %.2f s, music %.1f dB down under speech", start, ducked))
        } catch {
            return Result(name: "Intro music ducks under speech", passed: false, detail: error.localizedDescription)
        }
    }

    static func crossgateBleed() -> Result {
        let rate = 48000.0
        // Host speaks 0–1 s, guest 1.5–2.5 s; each mic hears the other 20 dB down, and both "VADs" fire on it.
        let a = sine(300, amplitude: 0.3, seconds: 1) + [Float](repeating: 0, count: Int(1.5 * rate))
        let b = [Float](repeating: 0, count: Int(1.5 * rate)) + sine(200, amplitude: 0.3, seconds: 1)
        let host = zip(a, b).map { $0 + 0.1 * $1 }, guest = zip(b, a).map { $0 + 0.1 * $1 }
        func track(_ x: [Float]) -> Mastering.PreparedTrack {
            let buf = PlanarBuffer([x])
            let vad: [Float] = Mastering.blockPowers(buf).map { $0 > 1e-6 ? 1 : 0 }
            return Mastering.PreparedTrack(audio: buf, original: buf, vad: vad, humHz: 0, eqBands: [], breaths: 0,
                                           inLoudness: Loudness.measure(buf))
        }
        let gates = Mastering.crossgate([track(host), track(guest)])
        func mean(_ g: [Float], _ from: Double, _ to: Double) -> Float {
            let s = g[Int(from * 100)..<Int(to * 100)]
            return s.reduce(0, +) / Float(s.count)
        }
        let hostOwn = mean(gates[0], 0.2, 0.9), hostBleed = mean(gates[0], 1.9, 2.4)
        let guestOwn = mean(gates[1], 1.7, 2.4), guestBleed = mean(gates[1], 0.2, 0.9)
        let ok = hostOwn > -1 && guestOwn > -1 && hostBleed < -15 && guestBleed < -15
        return Result(name: "Crossgate shuts out the other speaker", passed: ok,
                      detail: String(format: "own speech %.1f / %.1f dB, bleed %.1f / %.1f dB", hostOwn, guestOwn, hostBleed, guestBleed))
    }

    static func chapterTiming() -> Result {
        let parsed = Chapters.parse("0:00 Intro\n1:02.5 Gear talk\n# comment\n01:10:00 Wrap-up") + Chapters.parse("90.25\t90.25\tFrom Audacity")
        // 10 s of intro, then a 5 s cut at 30–35 s; the gear chapter at 62.5 s lands at 62.5 - 5.015 + 10.
        let map = TimeMap(cuts: [EditCut(kind: .silence, start: 30, end: 35, label: "")], offset: 10)
        let out = Chapters.remap(parsed.sorted { $0.start < $1.start }, map)
        let expected: [Double] = [0, 67.485, 95.235, 4204.985]
        let ok = out.count == 4 && zip(out.map(\.start), expected).allSatisfy { abs($0 - $1) < 0.001 } && out[1].title == "Gear talk"
        return Result(name: "Chapters follow cuts and intro", passed: ok,
                      detail: out.map { String(format: "%.3f %@", $0.start, $0.title) }.joined(separator: ", "))
    }

    static func studioEngine() -> Result {
        let name = "Studio engine (DeepFilterNet) keeps voice, aligned"
        guard StudioDenoiser.isAvailable else { return Result(name: name, passed: true, detail: "not installed, skipped") }
        // The synthetic programme's voiced "words" over a faint noise floor. They're a buzz rather than real speech,
        // so DeepFilterNet turns them down somewhat; this checks timing and that the voice isn't removed.
        let p = syntheticProgramme()
        do {
            let out = try StudioDenoiser.process(p.audio, strength: 1) { _ in }
            let x = p.audio.array(0), y = out.array(0)
            let lag = StudioDenoiser.measureDelay(x, y + [Float](repeating: 0, count: 600), maxLag: 500)
            let word = p.spoken[0]
            let r = Int(word.lowerBound * 48000)..<Int(word.upperBound * 48000)
            let change = rmsDB(y[r]) - rmsDB(x[r])
            let ok = lag <= 2 && change > -12 && change < 1
            return Result(name: name, passed: ok, detail: String(format: "offset %d samples, voice level %+.1f dB", lag, change))
        } catch {
            return Result(name: name, passed: false, detail: error.localizedDescription)
        }
    }
}
