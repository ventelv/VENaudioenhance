import Accelerate
import Foundation
import VENDSP

/// Settings for the offline, Auphonic-style mastering pass.
public struct MasteringSettings: Codable, Equatable {
    public enum Channels: String, Codable, CaseIterable, Identifiable {
        case auto, mono, stereo
        public var id: String { rawValue }
        public var label: String { self == .auto ? "Auto" : rawValue.capitalized }
    }

    public var highPass = true
    public var humMode: VoiceSettings.HumMode = .auto
    public var noiseReduction = true
    public var noiseStrength: Float = 0.9
    public var noiseEngine: NoiseEngine = .standard
    public var autoEQ = true
    public var deEsser = true
    public var deEsserAmount: Float = 0.5
    public var leveler = true
    public var levelerStrength: Float = 0.8
    public var compressorAmount: Float = 0.3
    public var breathReduction = true
    public var breathReductionDB: Float = 12
    public var cutSilence = false
    public var maxPauseSeconds = 0.8
    public var cutFillers = false
    public var cutCoughs = false
    /// In the app: stop before export so cuts can be checked one by one.
    public var reviewCuts = true
    public var transcriptFormats: [Transcript.Format] = []
    public var language = "auto"
    /// nil = the best installed model.
    public var speechModelPath: String?
    /// Music or a jingle played before and after the programme; speech may start over the end of the intro.
    public var introPath: String?
    public var outroPath: String?
    public var introOverlap = 0.0
    public var outroOverlap = 0.0
    /// How far music is turned down under speech (intro/outro overlaps and multitrack music).
    public var duckingDB: Float = 15
    /// For a video input: write a copy of the video with the processed audio.
    public var exportVideo = true
    public var loudnessTarget = -16.0
    public var truePeakLimit = -1.0
    public var channels: Channels = .auto
    public var format: ExportFormat = .wav24
    public var outputRate = 48000.0

    public enum NoiseEngine: String, Codable, CaseIterable, Identifiable {
        /// RNNoise: fast, good on steady noise.
        case standard
        /// DeepFilterNet 3: better on changing noise (keyboards, traffic, rooms), slower.
        case studio
        public var id: String { rawValue }
        public var label: String { self == .standard ? "Standard (RNNoise)" : "Studio (DeepFilterNet)" }
    }

    public init() {}

    /// Decodes saved settings, keeping defaults for anything saved by an older version.
    public static func decode(_ data: Data) -> MasteringSettings? {
        guard let defaults = try? JSONSerialization.jsonObject(with: JSONEncoder().encode(MasteringSettings())) as? [String: Any],
              let saved = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let merged = try? JSONSerialization.data(withJSONObject: defaults.merging(saved) { _, new in new })
        else { return nil }
        return try? JSONDecoder().decode(MasteringSettings.self, from: merged)
    }

    public var needsTranscript: Bool { cutFillers || !transcriptFormats.isEmpty }
    public var cutsAnything: Bool { cutFillers || cutCoughs || cutSilence }

    public static let loudnessTargets: [(value: Double, label: String)] = [
        (-14, "-14 LUFS · YouTube, Spotify"),
        (-16, "-16 LUFS · Podcasts, Apple"),
        (-19, "-19 LUFS · Mono podcast"),
        (-23, "-23 LUFS · EBU R128 broadcast"),
        (-24, "-24 LUFS · ATSC A/85 (US TV)"),
    ]
}

public struct MasteringReport {
    public var input: ven_loudness_result
    public var output: ven_loudness_result
    public var humHz: Int
    public var autoEQ: [(hz: Float, db: Float)]
    public var breathsReduced: Int
    public var cutCounts: [EditCut.Kind: Int]
    public var secondsCut: Double
    public var transcriptFiles: [URL]
    public var videoOutput: URL?
    public var chapterCount: Int
    public var durationIn: Double
    public var durationOut: Double
    public var outputURL: URL
}

/// The programme after processing, before cutting and loudness normalization: lets cuts be reviewed before export.
public final class MasteringAnalysis {
    public let input: URL
    public let settings: MasteringSettings
    let audio: PlanarBuffer
    public let inLoudness: ven_loudness_result
    public let humHz: Int
    public let autoEQ: [(hz: Float, db: Float)]
    public let breathsReduced: Int
    public let durationIn: Double
    public let transcript: Transcript?
    public var cuts: [EditCut]
    /// Chapter marks on the input's timeline (from "name.chapters.txt" next to it, or set by the caller).
    public var chapters: [Chapter] = []
    public lazy var isVideo = VideoRemux.hasVideo(input)

    init(input: URL, settings: MasteringSettings, audio: PlanarBuffer, inLoudness: ven_loudness_result, humHz: Int,
         autoEQ: [(hz: Float, db: Float)], breathsReduced: Int, durationIn: Double, transcript: Transcript?, cuts: [EditCut]) {
        self.input = input
        self.settings = settings
        self.audio = audio
        self.inLoudness = inLoudness
        self.humHz = humHz
        self.autoEQ = autoEQ
        self.breathsReduced = breathsReduced
        self.durationIn = durationIn
        self.transcript = transcript
        self.cuts = cuts
        if let sidecar = Chapters.sidecar(for: input), let text = try? String(contentsOf: sidecar) {
            chapters = Chapters.parse(text)
        }
    }

    public var duration: Double { Double(audio.frames) / Mastering.rate }
    public var sampleRate: Double { Mastering.rate }

    /// Peak level per column, for drawing the waveform.
    public func overview(columns: Int) -> [Float] {
        let mono = audio.channel(0)
        let per = max(1, audio.frames / max(columns, 1))
        return (0..<columns).map { c in
            let start = c * per
            guard start < audio.frames else { return 0 }
            var peak: Float = 0
            vDSP_maxmgv(mono + start, 1, &peak, vDSP_Length(min(per, audio.frames - start)))
            return peak
        }
    }

    /// Mono samples of [from, to) seconds, optionally with the given cuts applied, for previewing.
    public func preview(from: Double, to: Double, cuts: [EditCut] = []) -> [Float] {
        let s = max(0, Int(from * Mastering.rate)), e = min(audio.frames, Int(to * Mastering.rate))
        guard e > s else { return [] }
        let clip = Mastering.mixToMono(audio.slice(s, e - s))
        let shifted = cuts.map { c -> EditCut in var c = c; c.start -= from; c.end -= from; c.accepted = true; return c }
        let edited = Cutting.apply(clip, map: TimeMap(cuts: shifted))
        // Same loudness as the export will have, roughly: bring speech peaks near -3 dBFS.
        var peak: Float = 0
        vDSP_maxmgv(edited.channel(0), 1, &peak, vDSP_Length(edited.frames))
        let gain = peak > 1e-4 ? min(10, 0.7 / peak) : 1
        return edited.array(0).map { $0 * gain }
    }
}

public enum Mastering {
    static let rate = 48000.0
    static let block = Int(VEN_BLOCK)

    public static func outputURL(for input: URL, in folder: URL? = nil, format: ExportFormat) -> URL {
        let dir = folder ?? input.deletingLastPathComponent()
        let base = input.deletingPathExtension().lastPathComponent
        return dir.appendingPathComponent("\(base) (VEN).\(format.fileExtension)")
    }

    public static func process(input: URL, output: URL, settings s: MasteringSettings,
                               progress: (Double, String) -> Void = { _, _ in }) throws -> MasteringReport {
        let analysis = try analyze(input: input, settings: s, progress: progress)
        return try finish(analysis, output: output, progress: progress)
    }

    /// Everything up to the edit: cleanup, EQ, leveling, dynamics, transcript and candidate cuts.
    /// One track after cleanup, EQ, leveling and dynamics, with what was found along the way.
    struct PreparedTrack {
        let audio: PlanarBuffer
        /// The track before noise reduction (same timeline), where coughs are easiest to hear.
        let original: PlanarBuffer
        let vad: [Float]
        let humHz: Int
        let eqBands: [(hz: Float, db: Float)]
        let breaths: Int
        let inLoudness: ven_loudness_result
    }

    /// Steps 1–4 of the pass. Progress runs from 0 to 1.
    static func prepare(_ input: PlanarBuffer, settings s: MasteringSettings, progress: (Double, String) -> Void) throws -> PreparedTrack {
        var audio = input
        let inLoudness = Loudness.measure(audio)

        // 1. Cleanup: high-pass, hum, noise reduction. Also yields the speech map (VAD per 10 ms).
        var hum = 0
        switch s.humMode {
        case .auto: hum = Int(ven_detect_hum(mixToMono(audio).channel(0), Int64(audio.frames)))
        case .hz50: hum = 50
        case .hz60: hum = 60
        case .off: hum = 0
        }
        let studio = s.noiseReduction && s.noiseEngine == .studio
        let cleanupStage = (hum > 0 ? "Removing noise and \(hum) Hz hum" : "Removing noise") + (studio ? " (Studio)" : "")
        progress(0, cleanupStage)
        var cleanup = VoiceSettings()
        cleanup.highPassEnabled = s.highPass
        cleanup.humMode = hum == 50 ? .hz50 : (hum == 60 ? .hz60 : .off)
        // With the Studio engine, RNNoise still runs for its speech detection but leaves the audio alone.
        cleanup.noiseReductionEnabled = s.noiseReduction && !studio
        cleanup.noiseReductionStrength = s.noiseStrength
        cleanup.voiceEQEnabled = false
        cleanup.deEsserEnabled = false
        cleanup.levelerEnabled = false
        cleanup.compressorEnabled = false
        cleanup.limiterEnabled = false
        let original = audio
        var (clean, vad) = runChain(audio, settings: cleanup, useNR: true) { progress((studio ? 0.2 : 0.7) * $0, cleanupStage) }
        if studio {
            clean = try StudioDenoiser.process(clean, strength: s.noiseStrength) { progress(0.2 + 0.5 * $0, cleanupStage) }
        }
        audio = clean

        // 2. AutoEQ toward a speech target curve.
        var eqBands: [(hz: Float, db: Float)] = []
        if s.autoEQ {
            progress(0.75, "AutoEQ")
            eqBands = autoEQBands(audio, vad: vad)
            applyEQ(audio, bands: eqBands)
        }

        // 3. Leveler and breath reduction as one smooth gain curve.
        progress(0.85, "Leveling")
        var gains = [Float](repeating: 0, count: vad.count)
        if s.leveler { gains = levelerCurve(audio, vad: vad, strength: s.levelerStrength) }
        var breaths = 0
        if s.breathReduction { breaths = reduceBreaths(audio, vad: vad, gains: &gains, depth: s.breathReductionDB) }
        applyGainCurve(audio, gainsDB: gains)

        // 4. De-esser and compressor.
        progress(0.93, "Compressing")
        var dyn = SelfTest.allOff()
        dyn.deEsserEnabled = s.deEsser
        dyn.deEsserAmount = s.deEsserAmount
        dyn.compressorEnabled = s.compressorAmount > 0
        dyn.compressorAmount = s.compressorAmount
        (clean, _) = runChain(audio, settings: dyn, useNR: false) { _ in }
        return PreparedTrack(audio: clean, original: original, vad: vad, humHz: hum, eqBands: eqBands, breaths: breaths, inLoudness: inLoudness)
    }

    public static func analyze(input: URL, settings s: MasteringSettings,
                               progress: (Double, String) -> Void = { _, _ in }) throws -> MasteringAnalysis {
        progress(0.02, "Reading")
        var input48 = try AudioIO.read(input, rate: rate)
        let durationIn = Double(input48.frames) / rate
        if input48.channels == 2, s.channels == .mono || (s.channels == .auto && isDualMono(input48)) {
            input48 = mixToMono(input48)
        }
        let span = s.needsTranscript ? 0.6 : 0.9   // share of the progress bar before transcription
        let p = try prepare(input48, settings: s) { progress(0.04 + (span - 0.04) * $0, $1) }
        let audio = p.audio, original = p.original, vad = p.vad
        let hum = p.humHz, eqBands = p.eqBands, breaths = p.breaths, inLoudness = p.inLoudness

        // 5. Transcript with word timings (whisper.cpp).
        var transcript: Transcript?
        if s.needsTranscript {
            progress(span, "Transcribing")
            transcript = try Speech.transcribe(audio, model: try speechModel(s), language: s.language) { progress(span + 0.33 * $0, "Transcribing") }
        }

        // 6. Candidate cuts.
        var cuts: [EditCut] = []
        if s.cutsAnything {
            progress(0.94, "Finding cuts")
            var options = Cutting.Options()
            options.fillers = s.cutFillers
            options.coughs = s.cutCoughs
            options.silence = s.cutSilence
            options.maxPause = s.maxPauseSeconds
            cuts = Cutting.detect(audio, original: original, vad: vad, words: transcript?.words, options: options)
        }

        return MasteringAnalysis(input: input, settings: s, audio: audio, inLoudness: inLoudness, humHz: hum, autoEQ: eqBands,
                                 breathsReduced: breaths, durationIn: durationIn, transcript: transcript, cuts: cuts)
    }

    /// The chosen speech model; one that has since been deleted falls back to the best installed one.
    static func speechModel(_ s: MasteringSettings) throws -> URL {
        let chosen = s.speechModelPath.flatMap { FileManager.default.fileExists(atPath: $0) ? URL(fileURLWithPath: $0) : nil }
        guard let model = chosen ?? Speech.defaultModel() else {
            throw AudioIOError(message: "Transcripts and filler cutting need a speech model. Download one in Settings → Setup.")
        }
        return model
    }

    /// Applies the accepted cuts, normalizes loudness and writes the audio and transcripts.
    public static func finish(_ a: MasteringAnalysis, output: URL,
                              progress: (Double, String) -> Void = { _, _ in }) throws -> MasteringReport {
        let s = a.settings
        var map = TimeMap(cuts: a.cuts)
        var audio = a.audio
        if !map.ranges.isEmpty {
            progress(0.95, "Cutting")
            audio = Cutting.apply(audio, map: map)
        }
        let programFrames = audio.frames
        if !a.isVideo, (s.introPath ?? "").isEmpty == false || (s.outroPath ?? "").isEmpty == false {
            progress(0.955, "Adding intro and outro")
            (audio, map.offset) = try Production.addIntroOutro(audio, settings: s)
        }

        // Loudness normalization with a true-peak limiter; a second pass corrects what the limiter took away.
        progress(0.96, "Normalizing loudness")
        audio = normalize(audio, target: s.loudnessTarget, ceiling: s.truePeakLimit)

        progress(0.98, "Writing \(s.format.label)")
        var final = audio
        if s.outputRate != rate { final = try AudioIO.resample(audio, from: rate, to: s.outputRate) }
        try AudioIO.write(final, rate: s.outputRate, to: output, format: s.format)
        let files = try a.transcript?.write(s.transcriptFormats, besides: output, map: map) ?? []

        let chapters = Chapters.remap(a.chapters, map)
        if !chapters.isEmpty {
            _ = try Chapters.writeSidecars(chapters, besides: output)
            if ["m4a", "mp4", "mov"].contains(output.pathExtension.lowercased()) { try Chapters.embed(chapters, in: output) }
        }

        var videoOutput: URL?
        if a.isVideo && s.exportVideo {
            progress(0.99, "Writing video")
            // The soundtrack goes in as AAC; reuse the export if it already is.
            var soundtrack = output
            let temp = FileManager.default.temporaryDirectory.appendingPathComponent("ven-\(UUID().uuidString).m4a")
            defer { try? FileManager.default.removeItem(at: temp) }
            if s.format != .aac256 && s.format != .aac128 {
                try AudioIO.write(final, rate: s.outputRate, to: temp, format: .aac256)
                soundtrack = temp
            }
            let url = VideoRemux.outputURL(for: a.input, besides: output)
            do {
                try VideoRemux.remux(video: a.input, audio: soundtrack, map: map, output: url)
            } catch {
                throw AudioIOError(message: "Couldn't write the video: \(error)")
            }
            if !chapters.isEmpty { try Chapters.embed(chapters, in: url) }
            videoOutput = url
        }
        progress(1, "Done")

        let accepted = a.cuts.filter(\.accepted)
        return MasteringReport(input: a.inLoudness, output: Loudness.measure(audio), humHz: a.humHz, autoEQ: a.autoEQ,
                               breathsReduced: a.breathsReduced,
                               cutCounts: Dictionary(grouping: accepted, by: \.kind).mapValues(\.count),
                               secondsCut: a.durationIn - Double(programFrames) / rate, transcriptFiles: files,
                               videoOutput: videoOutput, chapterCount: chapters.count,
                               durationIn: a.durationIn, durationOut: Double(audio.frames) / rate, outputURL: output)
    }

    // MARK: Stages

    static func isDualMono(_ a: PlanarBuffer) -> Bool {
        var dot: Float = 0, l2: Float = 0, r2: Float = 0
        vDSP_dotpr(a.channel(0), 1, a.channel(1), 1, &dot, vDSP_Length(a.frames))
        vDSP_svesq(a.channel(0), 1, &l2, vDSP_Length(a.frames))
        vDSP_svesq(a.channel(1), 1, &r2, vDSP_Length(a.frames))
        if l2 < 1e-9 || r2 < 1e-9 { return true }   // one side silent: treat as mono
        return dot / sqrt(l2 * r2) > 0.995
    }

    static func mixToMono(_ a: PlanarBuffer) -> PlanarBuffer {
        guard a.channels == 2 else { return a }
        let out = PlanarBuffer(channels: 1, frames: a.frames)
        var l2: Float = 0, r2: Float = 0
        vDSP_svesq(a.channel(0), 1, &l2, vDSP_Length(a.frames))
        vDSP_svesq(a.channel(1), 1, &r2, vDSP_Length(a.frames))
        // If one side is (nearly) silent, take the other instead of halving the level.
        if l2 < r2 * 1e-3 { out.channel(0).update(from: a.channel(1), count: a.frames); return out }
        if r2 < l2 * 1e-3 { out.channel(0).update(from: a.channel(0), count: a.frames); return out }
        var half: Float = 0.5
        vDSP_vasm(a.channel(0), 1, a.channel(1), 1, &half, out.channel(0), 1, vDSP_Length(a.frames))
        return out
    }

    /// Runs the C chain over the whole buffer, removing its latency. Returns VAD per 10 ms block of the output.
    static func runChain(_ input: PlanarBuffer, settings: VoiceSettings, useNR: Bool,
                         progress: (Double) -> Void) -> (PlanarBuffer, [Float]) {
        let chain = ven_chain_create(Int32(input.channels), useNR ? 1 : 0)!
        defer { ven_chain_destroy(chain) }
        var params = settings.params
        ven_chain_set_params(chain, &params)
        let latency = Int(ven_chain_latency(chain))
        let blocks = (input.frames + latency + block - 1) / block
        let work = input.slice(0, blocks * block)
        var vadPerBlock = [Float](repeating: 0, count: blocks)
        for b in 0..<blocks {
            work.withPointers(offset: b * block) { ven_chain_process_block(chain, $0) }
            vadPerBlock[b] = ven_chain_block_vad(chain)
            if b % 500 == 0 { progress(Double(b) / Double(blocks)) }
        }
        let out = work.slice(latency, input.frames)
        // Re-index VAD to the trimmed output.
        let outBlocks = (input.frames + block - 1) / block
        let vad = (0..<outBlocks).map { k in vadPerBlock[min(blocks - 1, (k * block + latency) / block)] }
        return (out, vad)
    }

    static func blockPowers(_ a: PlanarBuffer) -> [Float] {
        let n = (a.frames + block - 1) / block
        return (0..<n).map { b in
            let start = b * block, len = min(block, a.frames - start)
            var total: Float = 0
            for c in 0..<a.channels {
                var p: Float = 0
                vDSP_measqv(a.channel(c) + start, 1, &p, vDSP_Length(len))
                total += p
            }
            return total / Float(a.channels)
        }
    }

    // Long-term speech spectrum target, dB per octave band relative to the 250–4k average (brightened LTASS).
    static let eqCenters: [Float] = [125, 250, 500, 1000, 2000, 4000, 8000]
    static let eqTarget: [Float] = [-3, 0, 0, -5, -9, -11, -15]

    static func autoEQBands(_ a: PlanarBuffer, vad: [Float]) -> [(hz: Float, db: Float)] {
        let mono = mixToMono(a)
        let n = 4096, log2n = vDSP_Length(12)
        guard let fft = vDSP.FFT(log2n: log2n, radix: .radix2, ofType: DSPSplitComplex.self) else { return [] }
        var window = [Float](repeating: 0, count: n)
        vDSP_hann_window(&window, vDSP_Length(n), Int32(vDSP_HANN_NORM))
        var power = [Float](repeating: 0, count: n / 2)
        var frames = 0
        var real = [Float](repeating: 0, count: n / 2), imag = [Float](repeating: 0, count: n / 2)
        var windowed = [Float](repeating: 0, count: n)
        var start = 0
        while start + n <= mono.frames {
            let b0 = start / block, b1 = min(vad.count - 1, (start + n) / block)
            let speech = b0 <= b1 && vad[b0...b1].allSatisfy { $0 > 0.6 }
            if speech {
                vDSP_vmul(mono.channel(0) + start, 1, window, 1, &windowed, 1, vDSP_Length(n))
                real.withUnsafeMutableBufferPointer { rp in
                    imag.withUnsafeMutableBufferPointer { ip in
                        var split = DSPSplitComplex(realp: rp.baseAddress!, imagp: ip.baseAddress!)
                        windowed.withUnsafeBufferPointer { wp in
                            wp.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: n / 2) {
                                vDSP_ctoz($0, 2, &split, 1, vDSP_Length(n / 2))
                            }
                        }
                        var spectrum = split   // same storage: in-place transform
                        fft.forward(input: split, output: &spectrum)
                        for i in 0..<(n / 2) { power[i] += rp[i] * rp[i] + ip[i] * ip[i] }
                    }
                }
                frames += 1
            }
            start += n / 2
        }
        guard frames >= 20 else { return [] }   // under ~1 s of clear speech: leave the tone alone

        let binHz = Float(rate) / Float(n)
        var measured = eqCenters.map { center -> Float in
            let lo = Int(center / sqrt(2) / binHz), hi = min(n / 2 - 1, Int(center * sqrt(2) / binHz))
            let sum = power[max(lo, 1)...max(hi, 1)].reduce(0, +)
            return 10 * log10(sum + 1e-12)
        }
        let mid = 1...5
        let offset = mid.map { measured[$0] }.reduce(0, +) / Float(mid.count)
        measured = measured.map { $0 - offset }
        let tOffset = mid.map { eqTarget[$0] }.reduce(0, +) / Float(mid.count)
        return eqCenters.indices.compactMap { i in
            var g = (eqTarget[i] - tOffset - measured[i]) * 0.6
            g = min(max(g, -6), i == eqCenters.count - 1 ? 3 : 4)   // boost gently, never lift the top octave much
            return abs(g) >= 0.5 ? (eqCenters[i], g) : nil
        }
    }

    static func applyEQ(_ a: PlanarBuffer, bands: [(hz: Float, db: Float)]) {
        guard !bands.isEmpty else { return }
        let freqs = bands.map(\.hz), gains = bands.map(\.db), qs = [Float](repeating: 1.4, count: bands.count)
        let eq = ven_eq_create(Int32(a.channels), Int32(bands.count), freqs, gains, qs)!
        defer { ven_eq_destroy(eq) }
        a.withPointers { ven_eq_process(eq, $0, Int32(a.frames)) }
    }

    /// Gain (dB per block) that brings each passage's speech level to the programme's median speech level.
    static func levelerCurve(_ a: PlanarBuffer, vad: [Float], strength: Float) -> [Float] {
        let powers = blockPowers(a)
        let n = min(powers.count, vad.count)
        let isSpeech = (0..<n).map { vad[$0] > 0.5 && powers[$0] > 1e-8 }
        let window = 150   // ±1.5 s
        // Prefix sums over speech blocks for fast windowed means.
        var sumP = [Double](repeating: 0, count: n + 1), sumN = [Int](repeating: 0, count: n + 1)
        for i in 0..<n {
            sumP[i + 1] = sumP[i] + (isSpeech[i] ? Double(powers[i]) : 0)
            sumN[i + 1] = sumN[i] + (isSpeech[i] ? 1 : 0)
        }
        var local = [Float?](repeating: nil, count: n)
        for i in 0..<n {
            let lo = max(0, i - window), hi = min(n, i + window + 1)
            let cnt = sumN[hi] - sumN[lo]
            if cnt >= 30 { local[i] = Float(10 * log10((sumP[hi] - sumP[lo]) / Double(cnt))) }
        }
        let levels = local.compactMap { $0 }.sorted()
        guard !levels.isEmpty else { return [Float](repeating: 0, count: vad.count) }
        let median = levels[levels.count / 2]

        var gains = [Float](repeating: 0, count: vad.count)
        var last: Float = 0
        for i in 0..<n {
            if let l = local[i] { last = min(max((median - l) * strength, -12), 15) }
            gains[i] = last
        }
        // Fill leading blocks before the first measured passage.
        if let first = local.firstIndex(where: { $0 != nil }) { for i in 0..<first { gains[i] = gains[first] } }
        return smooth(gains, seconds: 0.4)
    }

    /// Zero-phase one-pole smoothing (forward then backward), so gain moves start before the passage, not after.
    static func smooth(_ x: [Float], seconds: Double) -> [Float] {
        guard !x.isEmpty else { return x }
        let a = Float(exp(-Double(block) / rate / seconds))
        var y = x
        for i in 1..<y.count { y[i] = a * y[i - 1] + (1 - a) * y[i] }
        for i in stride(from: y.count - 2, through: 0, by: -1) { y[i] = a * y[i + 1] + (1 - a) * y[i] }
        return y
    }

    /// Short non-speech bursts between words that stand clearly above the noise floor are breaths (or lip noise).
    static func reduceBreaths(_ a: PlanarBuffer, vad: [Float], gains: inout [Float], depth: Float) -> Int {
        let powers = blockPowers(a)
        let n = min(powers.count, vad.count)
        let sorted = powers.prefix(n).sorted()
        guard !sorted.isEmpty else { return 0 }
        let floorDB = 10 * log10(sorted[sorted.count / 10] + 1e-12)
        var cut = [Float](repeating: 0, count: gains.count)
        var count = 0, i = 0
        while i < n {
            guard vad[i] < 0.3 else { i += 1; continue }
            var j = i
            while j < n, vad[j] < 0.3 { j += 1 }
            let len = j - i
            let bounded = i > 0 && j < n
            if bounded, len >= 8, len <= 80 {
                let peak = powers[i..<j].max() ?? 0
                if 10 * log10(peak + 1e-12) > floorDB + 6 {
                    for k in i..<j { cut[k] = -depth }
                    count += 1
                }
            }
            i = j
        }
        let fades = smooth(cut, seconds: 0.02)
        for k in gains.indices { gains[k] += fades[k] }
        return count
    }

    static func applyGainCurve(_ a: PlanarBuffer, gainsDB: [Float]) {
        guard !gainsDB.isEmpty else { return }
        let lin = gainsDB.map { powf(10, $0 / 20) }
        for c in 0..<a.channels {
            let x = a.channel(c)
            for i in 0..<a.frames {
                // Interpolate between block centres.
                let pos = (Float(i) - Float(block) / 2) / Float(block)
                let b0 = max(0, min(lin.count - 1, Int(floor(pos))))
                let b1 = min(lin.count - 1, b0 + 1)
                let t = min(max(pos - Float(b0), 0), 1)
                x[i] *= lin[b0] + (lin[b1] - lin[b0]) * t
            }
        }
    }

    static func normalize(_ a: PlanarBuffer, target: Double, ceiling: Double) -> PlanarBuffer {
        let measured = Loudness.measure(a).integrated_lufs
        guard measured.isFinite else { return a }
        var gainDB = target - measured
        var result = a
        for _ in 0..<3 {
            result = a.slice(0, a.frames)
            let g = Float(pow(10, gainDB / 20))
            for c in 0..<result.channels { vDSP_vsmul(result.channel(c), 1, [g], result.channel(c), 1, vDSP_Length(result.frames)) }
            result = limit(result, ceiling: ceiling)
            let after = Loudness.measure(result).integrated_lufs
            if !after.isFinite || abs(after - target) < 0.2 { break }
            gainDB += min(target - after, 3)
        }
        return result
    }

    static func limit(_ a: PlanarBuffer, ceiling: Double) -> PlanarBuffer {
        let lim = ven_limiter_create(Int32(a.channels), Float(ceiling), 120)!
        defer { ven_limiter_destroy(lim) }
        let latency = Int(ven_limiter_latency(lim))
        let work = a.slice(0, a.frames + latency)
        work.withPointers { ven_limiter_process(lim, $0, Int32(work.frames)) }
        return work.slice(latency, a.frames)
    }
}
