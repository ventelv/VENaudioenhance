import Accelerate
import Foundation

/// Intro/outro music and ducking music under speech.
public enum Production {
    static let rate = Mastering.rate
    static let block = Mastering.block

    /// Per-block flags: is there speech in `a`? (Level within 25 dB of its loud passages.)
    static func speechBlocks(_ a: PlanarBuffer) -> [Bool] {
        let db = Mastering.blockPowers(a).map { 10 * log10($0 + 1e-12) }
        let sorted = db.sorted()
        guard let loud = sorted.dropFirst(sorted.count * 9 / 10).first else { return db.map { _ in false } }
        return db.map { $0 > max(loud - 25, -60) }
    }

    /// Gain in dB per block that turns music down by `depth` while `speech` is active: it starts going down
    /// 300 ms before speech and comes back up over about a second once speech stops.
    static func duckingCurve(_ speech: [Bool], depth: Float) -> [Float] {
        let ahead = 30, hold = 40
        var target = [Float](repeating: 0, count: speech.count)
        var nextSpeech = Int.max
        var lastSpeech = -10_000
        for i in speech.indices.reversed() {
            if speech[i] { nextSpeech = i }
            if nextSpeech - i <= ahead { target[i] = -depth }
        }
        for i in speech.indices {
            if speech[i] { lastSpeech = i }
            if i - lastSpeech <= hold { target[i] = -depth }
        }
        // Faster down than up.
        let down = Float(exp(-Double(block) / rate / 0.08)), up = Float(exp(-Double(block) / rate / 0.6))
        var g: Float = 0
        return target.map { t in
            let a = t < g ? down : up
            g = a * g + (1 - a) * t
            return g
        }
    }

    /// `track` brought to `channels` channels (mono is copied to both sides; stereo is mixed down).
    static func matchChannels(_ track: PlanarBuffer, _ channels: Int) -> PlanarBuffer {
        if track.channels == channels { return track }
        if channels == 1 { return Mastering.mixToMono(track) }
        let out = PlanarBuffer(channels: channels, frames: track.frames)
        for c in 0..<channels { out.channel(c).update(from: track.channel(0), count: track.frames) }
        return out
    }

    /// Gain that brings `a` to `lufs` integrated loudness (0 dB if it's silent).
    static func gainToLoudness(_ a: PlanarBuffer, _ lufs: Double) -> Float {
        let measured = Loudness.measure(a).integrated_lufs
        guard measured.isFinite, lufs.isFinite else { return 0 }
        return Float(min(max(lufs - measured, -30), 30))
    }

    static func scale(_ a: PlanarBuffer, dB: Float) {
        var g = powf(10, dB / 20)
        for c in 0..<a.channels { vDSP_vsmul(a.channel(c), 1, &g, a.channel(c), 1, vDSP_Length(a.frames)) }
    }

    /// Mixes `src` into `dst` starting at frame `at`, with an optional per-block gain curve (dB) for `src`.
    static func mix(_ src: PlanarBuffer, into dst: PlanarBuffer, at: Int, gainsDB: [Float]? = nil) {
        let lin = gainsDB?.map { powf(10, $0 / 20) }
        for c in 0..<dst.channels {
            let s = src.channel(min(c, src.channels - 1)), d = dst.channel(c)
            for i in 0..<src.frames {
                let j = at + i
                guard j >= 0, j < dst.frames else { continue }
                let g = lin.map { $0[min(i / block, $0.count - 1)] } ?? 1
                d[j] += s[i] * g
            }
        }
    }

    /// Adds the intro and outro around `program`, loudness-matched to it. Where they overlap the programme
    /// they're ducked under speech. Returns the result and where the programme now starts, in seconds.
    static func addIntroOutro(_ program: PlanarBuffer, settings s: MasteringSettings) throws -> (PlanarBuffer, Double) {
        func load(_ path: String?) throws -> PlanarBuffer? {
            guard let path, !path.isEmpty else { return nil }
            let track = matchChannels(try AudioIO.read(URL(fileURLWithPath: path), rate: rate), program.channels)
            scale(track, dB: gainToLoudness(track, Loudness.measure(program).integrated_lufs))
            return track
        }
        let intro = try load(s.introPath), outro = try load(s.outroPath)
        guard intro != nil || outro != nil else { return (program, 0) }

        let introFrames = intro?.frames ?? 0
        let overlapIn = min(introFrames, Int(max(0, s.introOverlap) * rate))
        let start = introFrames - overlapIn
        let overlapOut = min(outro?.frames ?? 0, program.frames, Int(max(0, s.outroOverlap) * rate))
        let outroStart = start + program.frames - overlapOut
        let total = max(start + program.frames, outroStart + (outro?.frames ?? 0))
        let out = PlanarBuffer(channels: program.channels, frames: total)
        mix(program, into: out, at: start)

        // Speech on the output timeline, for ducking the music where they overlap.
        let speechInProgram = speechBlocks(program)
        func speechAt(_ outBlock: Int) -> Bool {
            let b = outBlock - start / block
            return b >= 0 && b < speechInProgram.count && speechInProgram[b]
        }
        if let intro {
            let speech = (0..<(intro.frames / block + 1)).map { speechAt($0) }
            mix(intro, into: out, at: 0, gainsDB: duckingCurve(speech, depth: s.duckingDB))
        }
        if let outro {
            let first = outroStart / block
            let speech = (0..<(outro.frames / block + 1)).map { speechAt(first + $0) }
            mix(outro, into: out, at: outroStart, gainsDB: duckingCurve(speech, depth: s.duckingDB))
        }
        return (out, Double(start) / rate)
    }
}
