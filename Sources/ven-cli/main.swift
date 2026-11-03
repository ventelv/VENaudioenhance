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
              [--cut-silence] [--no-autoeq] [--no-leveler] [--mono]
                                                Auphonic-style mastering of a file
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

case "process":
    guard args.count >= 2 else { usage() }
    let input = URL(fileURLWithPath: args[1])
    var s = MasteringSettings()
    if let t = option("--target").flatMap(Double.init) { s.loudnessTarget = t }
    if let f = option("--format") {
        guard let format = ExportFormat(rawValue: f) else { fail("Unknown format \(f). Options: \(ExportFormat.allCases.map(\.rawValue))") }
        s.format = format
    }
    s.cutSilence = args.contains("--cut-silence")
    s.autoEQ = !args.contains("--no-autoeq")
    s.leveler = !args.contains("--no-leveler")
    if args.contains("--mono") { s.channels = .mono }
    let output = option("-o").map { URL(fileURLWithPath: $0) } ?? Mastering.outputURL(for: input, format: s.format)
    do {
        let start = Date()
        var lastStage = ""
        let r = try Mastering.process(input: input, output: output, settings: s) { _, stage in
            if stage != lastStage { print("  \(stage)…"); lastStage = stage }
        }
        print("Input:  \(describe(r.input))")
        print("Output: \(describe(r.output))")
        print("Hum: \(r.humHz == 0 ? "none" : "\(r.humHz) Hz")  AutoEQ: \(r.autoEQ.map { String(format: "%.0fHz %+.1f", $0.hz, $0.db) }.joined(separator: ", "))")
        print("Breaths reduced: \(r.breathsReduced)  Pauses cut: \(r.pausesCut) (\(String(format: "%.1f", r.secondsCut)) s)")
        print(String(format: "Processed %.1f s of audio in %.1f s → %@", r.durationIn, Date().timeIntervalSince(start), r.outputURL.path))
    } catch {
        fail(error.localizedDescription)
    }

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
