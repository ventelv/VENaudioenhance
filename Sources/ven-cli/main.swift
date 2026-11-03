import Foundation
import VENCore

let args = Array(CommandLine.arguments.dropFirst())

func usage() -> Never {
    print("""
    ven-cli — VEN Audio Enhance tools

      selftest                       run DSP checks
      devices                        list audio devices
    """)
    exit(2)
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
        print(String(format: "%5d  in:%2d out:%2d  %6.0f Hz  %@%@", d.id, d.inputChannels, d.outputChannels, d.sampleRate,
                     d.name, d.isVEN ? "  ← VEN" : ""))
    }
default:
    usage()
}
