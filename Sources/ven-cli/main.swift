import Foundation
import VENCore
import VENDSP

let args = Array(CommandLine.arguments.dropFirst())

func usage() -> Never {
    print("""
    ven-cli — VEN Audio Enhance tools

      selftest                                  run the DSP checks
      devices                                   list audio devices
      live [--input NAME] [--seconds N] [--preset ID] [--bypass]
                                                feed the enhanced mic into VEN Enhanced Mic
      record --device NAME --seconds N OUT.wav  record any input (e.g. "VEN Enhanced Mic")
      loudness FILE...                          measure loudness (EBU R128)
      process IN [-o OUT] [--target LUFS] [--format wav24|flac|aac256|mp3|...]
              [--cut-fillers] [--cut-coughs] [--cut-silence] [--transcript srt,vtt,txt,json]
              [--labels] [--model PATH] [--language en|auto] [--no-autoeq] [--no-leveler] [--mono]
              [--studio] [--intro FILE] [--outro FILE] [--intro-overlap S] [--outro-overlap S]
              [--chapters FILE] [--no-video]
                                                Auphonic-style mastering of a file
      multitrack TRACK... [--names Host,Guest] [--music FILE]... [-o OUT] [process options]
                                                mix a session recorded with one mic per person
      transcribe IN [--formats srt,vtt,txt,json] [--model PATH] [--language en|auto]
                                                transcript only, written next to IN
      models                                    list speech models (and how to get one)
      denoise IN OUT.wav [--studio]             noise reduction only (compare the two engines)
      demo SPEECH OUT.wav                       degrade a clean speech file for testing
    """)
    exit(2)
}

func option(_ name: String) -> String? {
    guard let i = args.firstIndex(of: name), i + 1 < args.count else { return nil }
    return args[i + 1]
}

func fail(_ message: String) -> Never {
    FileHandle.standardError.write((message + "\n").data(using: .utf8)!)
    exit(1)
}

func findDevice(_ name: String, input: Bool = true) -> AudioDevice {
    let all = AudioDevices.all().filter { !input || $0.inputChannels > 0 }
    if let d = all.first(where: { $0.name == name }) ?? all.first(where: { $0.name.localizedCaseInsensitiveContains(name) }) {
        return d
    }
    fail("No input device matching \"\(name)\". Try `ven-cli devices`.")
}

func runFor(_ seconds: Double, every: Double = 1, tick: () -> Void) {
    let end = Date().addingTimeInterval(seconds)
    while Date() < end {
        RunLoop.current.run(until: min(end, Date().addingTimeInterval(every)))
        tick()
    }
}

func describe(_ r: ven_loudness_result) -> String {
    String(format: "%.1f LUFS  LRA %.1f LU  true peak %.1f dBTP  max short-term %.1f LUFS",
           r.integrated_lufs, r.loudness_range_lu, r.true_peak_dbtp, r.max_short_term_lufs)
}

func transcriptFormats(_ list: String?) -> [Transcript.Format] {
    guard let list else { return [] }
    return list.split(separator: ",").map { name in
        guard let f = Transcript.Format(rawValue: String(name)) else { fail("Unknown transcript format \(name). Options: srt, vtt, txt, json") }
        return f
    }
}

extension Array {
    var nonEmpty: Self? { isEmpty ? nil : self }
}

switch args.first {
case "selftest":
    var failed = 0
    for r in SelfTest.run() {
        print("\(r.passed ? "PASS" : "FAIL")  \(r.name) — \(r.detail)")
        if !r.passed { failed += 1 }
    }
    exit(failed == 0 ? 0 : 1)

case "devices":
    for d in AudioDevices.all() {
        print(String(format: "%5d  in:%2d out:%2d  %6.0f Hz  %@%@%@", d.id, d.inputChannels, d.outputChannels, d.sampleRate,
                     d.name, d.isVEN ? "  ← VEN" : "", AudioDevices.isRunningSomewhere(d.id) ? "  [in use]" : ""))
    }
    if let auto = AudioDevices.automaticInput() { print("Automatic mic choice: \(auto.name)") }

case "live":
    guard let ven = AudioDevices.venDevice() else { fail("VEN Enhanced Mic isn't installed. Run scripts/install-driver.sh") }
    let mic = option("--input").map { findDevice($0) } ?? AudioDevices.automaticInput()
    guard let mic else { fail("No microphone found") }
    var settings = VoicePreset.all.first { $0.id == option("--preset") }?.settings ?? VoiceSettings()
    settings.bypass = args.contains("--bypass")
    let seconds = Double(option("--seconds") ?? "") ?? 30
    do {
        let engine = try LiveEngine(input: mic, output: ven.id, settings: settings)
        try engine.start()
        print("Live: \(mic.name) (\(Int(engine.inputRate)) Hz, \(engine.inputChannels) ch) → VEN Enhanced Mic for \(Int(seconds)) s")
        runFor(seconds) {
            let m = engine.meters(), s = engine.stats()
            print(String(format: "in %6.1f dB  out %6.1f dB  vad %.2f  lev %+5.1f dB  comp -%4.1f  lim -%4.1f  hum %2.0f Hz  backlog %4.1f ms  drift %+.4f%%  xruns %llu/%llu  apps %d",
                         m.in_rms_db, m.out_rms_db, m.vad, m.leveler_gain_db, m.comp_gr_db, m.limiter_gr_db, m.hum_hz,
                         s.ring_fill_ms, (s.ratio_adjust - 1) * 100, s.underruns, s.overruns, AudioDevices.venClientCount(ven.id)))
        }
        engine.stop()
    } catch {
        fail(error.localizedDescription)
    }

case "record":
    guard let name = option("--device"), let out = args.last, out.hasSuffix(".wav") else { usage() }
    let seconds = Double(option("--seconds") ?? "") ?? 10
    do {
        let rec = try DeviceRecorder(device: findDevice(name), url: URL(fileURLWithPath: out))
        try rec.start()
        print("Recording \(name) for \(Int(seconds)) s → \(out)")
        runFor(seconds, every: 0.2) { rec.drain() }
        rec.stop()
    } catch {
        fail(error.localizedDescription)
    }

case "loudness":
    for path in args.dropFirst() {
        do {
            let url = URL(fileURLWithPath: path)
            let audio = try AudioIO.read(url)
            print("\(url.lastPathComponent): \(describe(Loudness.measure(audio)))")
        } catch {
            print("\(path): \(error.localizedDescription)")
        }
    }

case "process", "multitrack":
    let multitrack = args[0] == "multitrack"
    // Positional arguments: the input file, or for a session every speech track.
    let valued: Set<String> = ["-o", "--target", "--format", "--transcript", "--model", "--language", "--intro", "--outro",
                               "--intro-overlap", "--outro-overlap", "--chapters", "--music", "--names"]
    var positional: [String] = []
    var i = 1
    while i < args.count {
        if valued.contains(args[i]) { i += 2; continue }
        if !args[i].hasPrefix("-") { positional.append(args[i]) }
        i += 1
    }
    guard let firstInput = positional.first else { usage() }
    let input = URL(fileURLWithPath: firstInput)
    var s = MasteringSettings()
    if let t = option("--target").flatMap(Double.init) { s.loudnessTarget = t }
    if let f = option("--format") {
        guard let format = ExportFormat(rawValue: f) else { fail("Unknown format \(f). Options: \(ExportFormat.allCases.map(\.rawValue))") }
        s.format = format
    }
    s.cutSilence = args.contains("--cut-silence")
    s.cutFillers = args.contains("--cut-fillers")
    s.cutCoughs = args.contains("--cut-coughs")
    s.transcriptFormats = transcriptFormats(option("--transcript"))
    s.speechModelPath = option("--model")
    if let lang = option("--language") { s.language = lang }
    if args.contains("--studio") { s.noiseEngine = .studio }
    s.introPath = option("--intro")
    s.outroPath = option("--outro")
    if let v = option("--intro-overlap").flatMap(Double.init) { s.introOverlap = v }
    if let v = option("--outro-overlap").flatMap(Double.init) { s.outroOverlap = v }
    if args.contains("--no-video") { s.exportVideo = false }
    s.autoEQ = !args.contains("--no-autoeq")
    s.leveler = !args.contains("--no-leveler")
    if args.contains("--mono") { s.channels = .mono }
    let output = option("-o").map { URL(fileURLWithPath: $0) } ?? Mastering.outputURL(for: input, format: s.format)
    do {
        let start = Date()
        var lastStage = ""
        let progress: (Double, String) -> Void = { _, stage in
            if stage != lastStage { print("  \(stage)…"); lastStage = stage }
        }
        let analysis: MasteringAnalysis
        if multitrack {
            let names = option("--names")?.split(separator: ",").map(String.init) ?? []
            var tracks = positional.enumerated().map { i, path in
                SessionTrack(url: URL(fileURLWithPath: path), name: i < names.count ? names[i] : nil)
            }
            // Every --music FILE adds a music track.
            for (k, a) in args.enumerated() where a == "--music" && k + 1 < args.count {
                tracks.append(SessionTrack(url: URL(fileURLWithPath: args[k + 1]), isMusic: true))
            }
            analysis = try Mastering.analyzeMultitrack(tracks, settings: s, progress: progress)
        } else {
            analysis = try Mastering.analyze(input: input, settings: s, progress: progress)
        }
        if let path = option("--chapters") { analysis.chapters = Chapters.parse(try String(contentsOfFile: path)) }
        for c in analysis.cuts {
            print(String(format: "  cut %@ %8.3f–%8.3f  %@", c.kind.label.padding(toLength: 7, withPad: " ", startingAt: 0), c.start, c.end, c.label))
        }
        if args.contains("--labels") {
            let labels = output.deletingPathExtension().appendingPathExtension("cuts.txt")
            try Cutting.audacityLabels(analysis.cuts).write(to: labels, atomically: true, encoding: .utf8)
            print("Cut labels (Audacity): \(labels.path)")
        }
        let r = try Mastering.finish(analysis, output: output, progress: progress)
        print("Input:  \(describe(r.input))")
        print("Output: \(describe(r.output))")
        print("Hum: \(r.humHz == 0 ? "none" : "\(r.humHz) Hz")  AutoEQ: \(r.autoEQ.map { String(format: "%.0fHz %+.1f", $0.hz, $0.db) }.joined(separator: ", "))")
        print("Breaths reduced: \(r.breathsReduced)  \(MasteringQueue.summary(r))")
        if let v = r.videoOutput { print("Video: \(v.path)") }
        print(String(format: "Processed %.1f s of audio in %.1f s → %@", r.durationIn, Date().timeIntervalSince(start), r.outputURL.path))
    } catch {
        fail(error.localizedDescription)
    }

case "denoise":
    guard args.count >= 3 else { usage() }
    do {
        try Mastering.denoise(input: URL(fileURLWithPath: args[1]), output: URL(fileURLWithPath: args[2]),
                              engine: args.contains("--studio") ? .studio : .standard)
    } catch {
        fail(error.localizedDescription)
    }

case "transcribe":
    guard args.count >= 2 else { usage() }
    let input = URL(fileURLWithPath: args[1])
    guard let model = option("--model").map({ URL(fileURLWithPath: $0) }) ?? Speech.defaultModel() else {
        fail("No speech model found. Run `ven-cli models`.")
    }
    do {
        let audio = try AudioIO.read(input)
        let start = Date()
        let t = try Speech.transcribe(audio, model: model, language: option("--language") ?? "auto")
        let files = try t.write(transcriptFormats(option("--formats")) .nonEmpty ?? [.srt, .txt], besides: input)
        print(String(format: "%d words (%@) in %.1f s with %@", t.words.count, t.language, Date().timeIntervalSince(start), model.lastPathComponent))
        files.forEach { print("  \($0.path)") }
    } catch {
        fail(error.localizedDescription)
    }

case "models":
    print("whisper.cpp: \(Speech.whisperPath ?? "not installed — brew install whisper-cpp")")
    let found = Speech.findModels()
    print(found.isEmpty ? "No speech models installed." : "Installed models:")
    for m in found { print("  \(m.path)\(m == Speech.defaultModel() ? "  (default)" : "")") }
    print("Downloadable (in the app: Settings → Setup, or save to \(Speech.modelsFolder.path)):")
    for m in WhisperModel.catalog { print("  \(m.name.padding(toLength: 26, withPad: " ", startingAt: 0)) \(m.sizeMB) MB  \(m.downloadURL.absoluteString)") }

case "demo":
    guard args.count == 3 else { usage() }
    do {
        try SelfTest.makeDegradedDemo(speech: URL(fileURLWithPath: args[1]), output: URL(fileURLWithPath: args[2]))
    } catch {
        fail(error.localizedDescription)
    }

default:
    usage()
}
