import Accelerate
import Foundation

/// One file of a multitrack session: a speaker's own mic, or a music/sound track.
public struct SessionTrack: Codable, Hashable, Identifiable {
    public var id = UUID()
    public var url: URL
    public var name: String
    public var isMusic: Bool

    public init(url: URL, name: String? = nil, isMusic: Bool = false) {
        self.url = url
        self.name = name ?? url.deletingPathExtension().lastPathComponent
        self.isMusic = isMusic
    }
}

extension Mastering {
    /// Turns a track down by this much while someone else is talking (removes their voice bleeding into it).
    static let crossgateDB: Float = 18

    /// A multitrack session: every speech track is cleaned and leveled on its own and crossgated against the
    /// others, music tracks are ducked under speech, and the mix then goes through the same edit and export as
    /// a single file. All tracks are assumed to start together.
    public static func analyzeMultitrack(_ tracks: [SessionTrack], settings s: MasteringSettings,
                                         progress: (Double, String) -> Void = { _, _ in }) throws -> MasteringAnalysis {
        let speech = tracks.filter { !$0.isMusic }, music = tracks.filter(\.isMusic)
        guard let first = speech.first else { throw AudioIOError(message: "A session needs at least one speech track") }

        progress(0.02, "Reading")
        let speechAudio = try speech.map { Mastering.mixToMono(try AudioIO.read($0.url, rate: rate)) }
        let musicAudio = try music.map { try AudioIO.read($0.url, rate: rate) }
        let frames = (speechAudio + musicAudio).map(\.frames).max() ?? 0
        let durationIn = Double(frames) / rate

        // 1. Each speaker's track on its own, brought to a common loudness.
        let span = s.needsTranscript ? 0.5 : 0.8
        var prepared: [PreparedTrack] = []
        for (i, audio) in speechAudio.enumerated() {
            let share = span / Double(speech.count)
            let p = try prepare(audio.slice(0, frames), settings: s) { f, stage in
                progress(0.04 + share * (Double(i) + f), "\(speech[i].name): \(stage)")
            }
            Production.scale(p.audio, dB: Production.gainToLoudness(p.audio, -23))
            prepared.append(p)
        }

        // 2. Crossgate: a track that isn't the one speaking is turned down.
        progress(0.04 + span, "Crossgating")
        let gates = prepared.count > 1 ? crossgate(prepared) : [[Float](repeating: 0, count: prepared[0].vad.count)]
        if prepared.count > 1 {
            for (p, g) in zip(prepared, gates) { applyGainCurve(p.audio, gainsDB: g) }
        }
        // Whether track `t` is the one speaking at `time` (its gate is open). Each mic also hears the others,
        // which its own speech detection and whisper would otherwise take for its speaker.
        func speaking(_ t: Int, _ time: Double) -> Bool {
            let b = Int(time * rate) / block
            return b >= 0 && b < gates[t].count && gates[t][b] > -6
        }

        // 3. Mix: speech in the middle, music (stereo if any music is) ducked under it.
        let channels = musicAudio.contains { $0.channels == 2 } ? 2 : 1
        let mix = PlanarBuffer(channels: channels, frames: frames)
        let original = PlanarBuffer(channels: 1, frames: frames)
        for p in prepared {
            Production.mix(p.audio, into: mix, at: 0)
            Production.mix(p.original, into: original, at: 0)
        }
        let vad = (0..<prepared[0].vad.count).map { b in prepared.map { $0.vad[min(b, $0.vad.count - 1)] }.max() ?? 0 }
        if !musicAudio.isEmpty {
            let speechLoudness = Loudness.measure(mix).integrated_lufs
            let ducking = Production.duckingCurve(vad.map { $0 > 0.5 }, depth: s.duckingDB)
            for m in musicAudio {
                let track = Production.matchChannels(m, channels)
                Production.scale(track, dB: Production.gainToLoudness(track, speechLoudness))
                Production.mix(track, into: mix, at: 0, gainsDB: ducking)
            }
        }

        // 4. Transcript, one speaker at a time.
        var transcript: Transcript?
        var perSpeaker: [[Transcript.Word]] = []
        if s.needsTranscript {
            let model = try speechModel(s)
            var language = s.language
            for (i, p) in prepared.enumerated() {
                let base = 0.04 + span + 0.35 * Double(i) / Double(prepared.count)
                progress(base, "Transcribing \(speech[i].name)")
                var t = try Speech.transcribe(p.audio, model: model, language: language) { f in
                    progress(base + 0.35 * f / Double(prepared.count), "Transcribing \(speech[i].name)")
                }
                language = t.language   // later speakers use the language found for the first
                t.words = t.words.filter { speaking(i, $0.anchor) }
                for w in t.words.indices { t.words[w].speaker = speech[i].name }
                perSpeaker.append(t.words)
            }
            transcript = Transcript(language: language, words: perSpeaker.flatMap { $0 }.sorted { $0.anchor < $1.anchor })
        }

        // 5. Cuts. Fillers and coughs are found per speaker but dropped where anyone else is talking.
        var cuts: [EditCut] = []
        if s.cutsAnything {
            progress(0.94, "Finding cuts")
            var options = Cutting.Options()
            options.fillers = s.cutFillers
            options.coughs = s.cutCoughs
            options.silence = false
            for (i, p) in prepared.enumerated() {
                let words = perSpeaker.isEmpty ? nil : perSpeaker[i]
                let found = Cutting.detect(p.audio, original: p.original, vad: p.vad, words: words, options: options)
                let others = prepared.indices.filter { $0 != i }
                cuts += found.filter { c in
                    !others.contains { o in stride(from: c.start, to: c.end, by: 0.01).contains { speaking(o, $0) } }
                }.map { var c = $0; c.label = "\(speech[i].name): \(c.label)"; return c }
            }
            if s.cutSilence {
                let existing = cuts
                cuts += Cutting.silenceCuts(vad: vad, maxPause: s.maxPauseSeconds).filter { p in !existing.contains { $0.start < p.end && $0.end > p.start } }
            }
            cuts.sort { $0.start < $1.start }
        }

        return MasteringAnalysis(input: first.url, settings: s, audio: mix, inLoudness: Loudness.measure(original), humHz: prepared[0].humHz,
                                 autoEQ: [], breathsReduced: prepared.map(\.breaths).reduce(0, +), durationIn: durationIn,
                                 transcript: transcript, cuts: cuts)
    }

    /// Gain curves (dB per block) for each track: full level while it's the one speaking, `crossgateDB` down
    /// otherwise. Two people talking at once (within 9 dB of each other) both stay up.
    static func crossgate(_ tracks: [PreparedTrack]) -> [[Float]] {
        // Levels of the raw tracks, each brought to the same loudness: the leveler would have lifted the
        // other speakers' bleed in each track, making it look like that track's own speech.
        // Peak over ±40 ms, so the gaps between syllables don't count.
        let levels = tracks.map { t -> [Float] in
            let offset = Production.gainToLoudness(t.original, -23)
            let raw = Mastering.blockPowers(t.original).map { 10 * log10($0 + 1e-12) + offset }
            return raw.indices.map { i in raw[max(0, i - 4)...min(raw.count - 1, i + 4)].max()! }
        }
        let floors = levels.map { l in l.sorted()[l.count / 10] }
        let n = levels.map(\.count).min() ?? 0
        var open = [[Bool]](repeating: [Bool](repeating: false, count: n), count: tracks.count)
        for b in 0..<n {
            let loudest = levels.map { $0[b] }.max() ?? -200
            for t in tracks.indices where tracks[t].vad[min(b, tracks[t].vad.count - 1)] > 0.5
                && levels[t][b] > loudest - 9 && levels[t][b] > floors[t] + 10 {
                open[t][b] = true
            }
        }
        return open.map { gate in
            // Open 50 ms early, hold 300 ms, then close smoothly.
            var target = [Float](repeating: -crossgateDB, count: n)
            var lastOpen = -10_000
            for b in 0..<n {
                if gate[b] { lastOpen = b }
                let soon = (b..<min(n, b + 5)).contains { gate[$0] }
                if soon || b - lastOpen <= 30 { target[b] = 0 }
            }
            let up = Float(exp(-Double(block) / rate / 0.01)), down = Float(exp(-Double(block) / rate / 0.25))
            var g = target.first ?? 0
            return target.map { t in
                let a = t > g ? up : down
                g = a * g + (1 - a) * t
                return g
            }
        }
    }
}
