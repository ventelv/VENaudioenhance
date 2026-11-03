import Accelerate
import Foundation

/// A stretch of audio to remove, in seconds of the processed (pre-cut) timeline.
public struct EditCut: Codable, Identifiable, Hashable {
    public enum Kind: String, Codable, CaseIterable, Identifiable {
        case filler, cough, silence
        public var id: String { rawValue }
        public var label: String {
            switch self {
            case .filler: return "Filler"
            case .cough: return "Cough"
            case .silence: return "Pause"
            }
        }
    }

    public var id = UUID()
    public var kind: Kind
    public var start: Double
    public var end: Double
    public var label: String
    public var accepted = true

    public var duration: Double { end - start }

    public init(kind: Kind, start: Double, end: Double, label: String) {
        self.kind = kind
        self.start = start
        self.end = end
        self.label = label
    }
}

/// Maps times in the uncut audio to times in the cut audio.
public struct TimeMap {
    /// Accepted cuts, sorted and merged.
    public let ranges: [ClosedRange<Double>]
    /// Each joint is crossfaded, which overlaps the two sides by this much.
    public static let fade = 0.015

    /// Added to every mapped time: where the programme starts in the output (after an intro).
    public var offset = 0.0

    public init(cuts: [EditCut], offset: Double = 0) {
        self.offset = offset
        var merged: [ClosedRange<Double>] = []
        for c in cuts.filter(\.accepted).sorted(by: { $0.start < $1.start }) where c.end > c.start {
            if let last = merged.last, c.start <= last.upperBound + 2 * Self.fade {
                merged[merged.count - 1] = last.lowerBound...max(last.upperBound, c.end)
            } else {
                merged.append(c.start...c.end)
            }
        }
        ranges = merged
    }

    /// The cut-timeline time for `t`, or nil if `t` was cut out.
    public func map(_ t: Double) -> Double? {
        var removed = 0.0
        for r in ranges {
            if t < r.lowerBound { break }
            if t <= r.upperBound { return nil }
            removed += r.upperBound - r.lowerBound + Self.fade
        }
        return max(0, t - removed) + offset
    }

    /// Like `map`, but a time inside a cut goes to the joint where the cut was.
    public func mapClamped(_ t: Double) -> Double {
        if let m = map(t) { return m }
        let r = ranges.first { $0.contains(t) }!
        return map(r.upperBound + 1e-6) ?? offset
    }

    public var totalRemoved: Double { ranges.reduce(0) { $0 + $1.upperBound - $1.lowerBound } }
}

public enum Cutting {
    static let rate = Mastering.rate
    static let block = Mastering.block
    static let blockSeconds = Double(block) / rate
    static let debug = ProcessInfo.processInfo.environment["VEN_DEBUG_CUTS"] != nil

    /// Level per 10 ms block, with the programme's noise floor and speech level.
    struct Envelope {
        let db: [Float]
        let floor: Float
        let speech: Float
        /// Below this, a block counts as a gap between words.
        let quiet: Float

        init(_ a: PlanarBuffer, vad: [Float]) {
            db = Mastering.blockPowers(a).map { 10 * log10($0 + 1e-12) }
            let sorted = db.sorted()
            floor = sorted.isEmpty ? -100 : sorted[sorted.count / 10]
            let voiced = zip(db, vad).filter { $0.1 > 0.5 }.map(\.0).sorted()
            speech = voiced.isEmpty ? (sorted.last ?? -20) : voiced[voiced.count * 9 / 10]
            quiet = max(floor + 6, min(speech - 24, floor + 0.6 * (speech - floor)))
        }

        func block(_ t: Double) -> Int { min(max(0, Int(t / blockSeconds)), db.count - 1) }
        func time(_ b: Int) -> Double { Double(b) * blockSeconds }

        /// Length in blocks of the quiet run starting at `from` and moving by `step`.
        func gap(from: Int, step: Int, limit: Int = 300) -> Int {
            var n = 0, i = from
            while i >= 0, i < db.count, db[i] <= quiet, n < limit { n += 1; i += step }
            return n
        }

        /// The cut for a sound occupying blocks s...e: the sound itself plus enough of the pauses on either
        /// side that what's left reads as one natural pause.
        func cutAround(_ s: Int, _ e: Int) -> (Double, Double) {
            // Stay 20 ms clear of the neighbouring words: a block that holds a word's first moments can still read as quiet.
            let gapL = Double(max(0, gap(from: s - 1, step: -1) - 2)), gapR = Double(max(0, gap(from: e + 1, step: 1) - 2))
            let keep = min(gapL + gapR, min(40, max(gapL, gapR, 12)))
            let keepL = gapL + gapR > 0 ? keep * gapL / (gapL + gapR) : 0
            let keepR = keep - keepL
            return (time(s) - (gapL - keepL) * blockSeconds, time(e + 1) + (gapR - keepR) * blockSeconds)
        }
    }

    // MARK: Fillers

    /// Cuts for filler words, placed on the audio: from the gap before the "um" to the gap after it.
    static func fillerCuts(words: [Transcript.Word], env: Envelope) -> [EditCut] {
        var cuts: [EditCut] = []
        for (i, w) in words.enumerated() where w.isFiller {
            let lo = i > 0 ? env.block(words[i - 1].anchor) + 1 : 0
            let hi = i + 1 < words.count ? env.block(words[i + 1].anchor) - 1 : env.db.count - 1
            guard let island = island(near: w.anchor, lo: lo, hi: hi, env: env) else { continue }
            let (start, end) = env.cutAround(island.lowerBound, island.upperBound)
            cuts.append(EditCut(kind: .filler, start: start, end: end, label: w.normalized))
        }
        return cuts
    }

    /// The loud stretch containing the word whose alignment anchor is at `t`, bounded by quiet gaps or, where
    /// the speaker ran words together, by the quietest point between the word and its neighbours.
    static func island(near t: Double, lo: Int, hi: Int, env: Envelope) -> ClosedRange<Int>? {
        guard lo < hi else { return nil }
        let a = env.block(t)
        // whisper's anchor sits in the middle-to-late part of the word.
        let searchLo = max(lo, a - 25), searchHi = min(hi, a + 8)
        guard searchLo <= searchHi, let peak = (searchLo...searchHi).max(by: { env.db[$0] < env.db[$1] }),
              env.db[peak] > env.quiet
        else { return nil }
        var s = peak, e = peak
        while s - 1 >= lo, env.db[s - 1] > env.quiet { s -= 1 }
        while e + 1 <= hi, env.db[e + 1] > env.quiet { e += 1 }
        if s == lo, lo < peak { s = (lo...peak).min { env.db[$0] < env.db[$1] }! }
        if e == hi, hi > peak { e = (peak...hi).min { env.db[$0] < env.db[$1] }! }
        guard e - s >= 4, e - s <= 150 else { return nil }   // 50 ms – 1.5 s, else it's not a lone filler
        return s...e
    }

    // MARK: Coughs

    /// Short, loud, noisy bursts with an abrupt start, standing alone between pauses and holding no words.
    /// Found in `mono`, the audio before noise reduction (which can turn a cough into a muffled thump), and
    /// cut using `env`, the processed audio's envelope.
    static func coughCuts(_ mono: PlanarBuffer, vad: [Float], words: [Transcript.Word]?, env: Envelope) -> [EditCut] {
        let raw = Envelope(mono, vad: vad)
        let db = raw.db
        let loud = max(raw.floor + 15, raw.speech - 30)
        // Where a burst's tail has died away.
        let settled = min(raw.quiet, loud - 6)
        // How many of the 8 blocks from `from` are settled (allowing for a background that wobbles a few dB).
        func calm(_ from: Int, _ step: Int) -> Int {
            (0..<8).filter { k in
                let b = from + k * step
                return b < 0 || b >= db.count || db[b] <= settled + 3
            }.count
        }
        var cuts: [EditCut] = []

        // Whisper sometimes labels them outright: "[coughs]", "(coughing)".
        for (i, w) in (words ?? []).enumerated() where w.isAnnotation && ["cough", "sneez", "throat"].contains(where: w.text.lowercased().contains) {
            let lo = i > 0 ? env.block(words![i - 1].anchor) + 1 : 0
            let hi = i + 1 < words!.count ? env.block(words![i + 1].anchor) - 1 : db.count - 1
            if let isl = island(near: w.anchor, lo: lo, hi: hi, env: raw) {
                let (s, e) = env.cutAround(isl.lowerBound, isl.upperBound)
                cuts.append(EditCut(kind: .cough, start: s, end: e, label: "cough"))
            }
        }

        var i = 0, lastCough = -1000
        while i < db.count {
            guard db[i] > loud else { i += 1; continue }
            var j = i
            while j + 1 < db.count, db[j + 1] > loud { j += 1 }
            defer { i = j + 1 }
            // The tail of a cough decays slowly: it ends where the level has settled (≤ 300 ms on).
            var end = j
            while end + 1 < db.count, db[end + 1] > settled, end - j < 30 { end += 1 }
            let before = i > 0 ? db[i - 1] : raw.floor
            let onset = (db[i...min(j, i + 3)].max() ?? -100) - before
            let peak = db[i...j].max() ?? -100
            let s = raw.time(i), e = raw.time(end + 1)
            // No word's core (its anchor and the half-estimate before it) may fall in the burst.
            let hasWords = words?.contains { w in
                !w.isAnnotation && w.anchor - (w.anchor - w.start) / 2 < e + 0.1 && w.anchor > s - 0.05
            } ?? false
            let noisy = noisiness(mono, from: i * block, to: (j + 1) * block)
            if debug {
                print(String(format: "  burst %.2f–%.2f peak %.0f (speech %.0f) onset %.0f calm %d/%d noisy %.2f words %@", s, e, peak, raw.speech, onset,
                             calm(i - 1, -1), calm(end + 1, 1), noisy, hasWords ? "yes" : "no"))
            }
            guard j - i + 1 >= 8, end - i + 1 <= 100 else { continue }                          // 80 ms – 1 s
            // A pause on each side, except that the second cough of a fit follows straight on from the first.
            guard calm(i - 1, -1) >= 5 || i - lastCough < 30, calm(end + 1, 1) >= 5 else { continue }
            guard peak >= raw.speech - 6, onset >= 15, !hasWords else { continue }             // loud, explosive, wordless
            // Partly unpitched. Without a transcript to rule out words, require mostly unpitched.
            guard noisy >= (words == nil ? 0.4 : 0.1) else { continue }
            lastCough = end
            let (cs, ce) = env.cutAround(i, end)
            cuts.append(EditCut(kind: .cough, start: cs, end: ce, label: "cough"))
        }
        // An annotated cough may also have been found acoustically.
        return cuts.sorted { $0.start < $1.start }.reduce(into: []) { out, c in
            if let last = out.last, c.start < last.end { out[out.count - 1].end = max(last.end, c.end) } else { out.append(c) }
        }
    }

    /// Fraction of 21 ms frames without a clear pitch (normalized autocorrelation over 80–400 Hz below 0.45).
    static func noisiness(_ mono: PlanarBuffer, from: Int, to: Int) -> Double {
        let n = 1024
        let x = mono.channel(0)
        var unvoiced = 0, frames = 0
        var pos = from
        while pos + n <= min(to, mono.frames) {
            defer { pos += n / 2 }
            let frame = x + pos
            var r0: Float = 0
            vDSP_dotpr(frame, 1, frame, 1, &r0, vDSP_Length(n))
            guard r0 > 1e-9 else { continue }
            var best: Float = 0
            for lag in stride(from: 120, through: 600, by: 2) {
                var r: Float = 0, e: Float = 0, e0: Float = 0
                vDSP_dotpr(frame, 1, frame + lag, 1, &r, vDSP_Length(n - lag))
                vDSP_dotpr(frame + lag, 1, frame + lag, 1, &e, vDSP_Length(n - lag))
                vDSP_dotpr(frame, 1, frame, 1, &e0, vDSP_Length(n - lag))
                best = max(best, r / max(sqrt(e * e0), 1e-12))
            }
            if best < 0.45 { unvoiced += 1 }
            frames += 1
        }
        return frames > 0 ? Double(unvoiced) / Double(frames) : 0
    }

    // MARK: Pauses

    /// Pauses longer than `maxPause` lose their middle, keeping half the allowed pause on each side.
    static func silenceCuts(vad: [Float], maxPause: Double) -> [EditCut] {
        let keepBlocks = max(4, Int(maxPause / blockSeconds))
        var cuts: [EditCut] = []
        var i = 0
        while i < vad.count {
            guard vad[i] < 0.3 else { i += 1; continue }
            var j = i
            while j < vad.count, vad[j] < 0.3 { j += 1 }
            if j - i > keepBlocks, i > 0, j < vad.count {
                let s = Double(i + keepBlocks / 2) * blockSeconds, e = Double(j - keepBlocks / 2) * blockSeconds
                cuts.append(EditCut(kind: .silence, start: s, end: e, label: String(format: "pause %.1f s", Double(j - i) * blockSeconds)))
            }
            i = j
        }
        return cuts
    }

    // MARK: Detection and editing

    public struct Options {
        public var fillers = true
        public var coughs = true
        public var silence = false
        public var maxPause = 0.8
        public init() {}
    }

    /// All candidate cuts for `audio` (the processed programme before cutting).
    /// `original` is the same programme before noise reduction, on the same timeline.
    static func detect(_ audio: PlanarBuffer, original: PlanarBuffer, vad: [Float], words: [Transcript.Word]?, options: Options) -> [EditCut] {
        let env = Envelope(audio, vad: vad)
        var cuts: [EditCut] = []
        if options.fillers, let words { cuts += fillerCuts(words: words, env: env) }
        if options.coughs { cuts += coughCuts(Mastering.mixToMono(original), vad: vad, words: words, env: env) }
        if options.silence {
            // Pauses that already contain a filler or cough cut are measured without it.
            let others = cuts
            cuts += silenceCuts(vad: vad, maxPause: options.maxPause).filter { p in !others.contains { $0.start < p.end && $0.end > p.start } }
        }
        let duration = Double(audio.frames) / rate
        return cuts.map { var c = $0; c.start = max(0, c.start); c.end = min(duration, c.end); return c }
            .filter { $0.duration >= 0.03 }
            .sorted { $0.start < $1.start }
    }

    /// Removes the accepted cuts, with a short equal-power crossfade at each joint.
    public static func apply(_ a: PlanarBuffer, map: TimeMap) -> PlanarBuffer {
        guard !map.ranges.isEmpty else { return a }
        var segments: [Range<Int>] = []
        var keepStart = 0
        for r in map.ranges {
            let from = min(a.frames, Int(r.lowerBound * rate)), to = min(a.frames, Int(r.upperBound * rate))
            if from > keepStart { segments.append(keepStart..<from) }
            keepStart = max(keepStart, to)
        }
        if keepStart < a.frames { segments.append(keepStart..<a.frames) }

        let fade = Int(TimeMap.fade * rate)
        let total = max(0, segments.reduce(0) { $0 + $1.count } - fade * (segments.count - 1))
        let out = PlanarBuffer(channels: a.channels, frames: total)
        for c in 0..<a.channels {
            let src = a.channel(c), dst = out.channel(c)
            var w = 0
            for (s, seg) in segments.enumerated() {
                for (k, idx) in seg.enumerated() {
                    if s > 0 && k < fade && w - fade + k >= 0 {
                        let t = Float(k) / Float(fade)
                        dst[w - fade + k] = dst[w - fade + k] * cos(t * .pi / 2) + src[idx] * sin(t * .pi / 2)
                    } else if w < total {
                        dst[w] = src[idx]
                        w += 1
                    }
                }
            }
        }
        return out
    }

    /// The cuts as an Audacity label track (File → Import → Labels).
    public static func audacityLabels(_ cuts: [EditCut]) -> String {
        cuts.map { String(format: "%.6f\t%.6f\t%@%@", $0.start, $0.end, $0.label, $0.accepted ? "" : " (kept)") }
            .joined(separator: "\n") + "\n"
    }
}
