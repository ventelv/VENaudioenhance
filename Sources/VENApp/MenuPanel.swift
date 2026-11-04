import SwiftUI
import VENCore

struct MenuPanel: View {
    @EnvironmentObject var live: LiveController
    @EnvironmentObject var system: SystemSupport
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("VEN Audio Enhance").font(.headline)
                Spacer()
                StatusPill(status: live.status, muted: live.settings.mute)
            }

            if live.status == .driverMissing {
                DriverMissingCard()
            } else {
                MicPicker()
                Picker("Run", selection: $live.mode) {
                    ForEach(LiveController.Mode.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()

                PresetChips()

                Toggle(isOn: Binding(get: { !live.settings.bypass }, set: { live.settings.bypass = !$0 })) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Enhance").font(.body.weight(.medium))
                        Text(live.settings.bypass ? "Bypassed: you're hearing the raw mic" : "Noise, hum and level cleanup on")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                .toggleStyle(.switch)

                if VoiceIsolation.isAvailable {
                    Toggle(isOn: $live.settings.voiceIsolation) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Voice isolation").font(.body.weight(.medium))
                            Text("Removes kids, TV and other voices around you").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .toggleStyle(.switch)
                    .disabled(live.settings.bypass)
                }

                LiveMeters(compact: true)

                HStack(spacing: 8) {
                    HoldToMuteButton()
                    Button {
                        live.toggleRecording()
                    } label: {
                        Label(live.recordingSince == nil ? "Record" : "Stop", systemImage: live.recordingSince == nil ? "record.circle" : "stop.circle.fill")
                            .frame(maxWidth: .infinity)
                    }
                    .tint(live.recordingSince == nil ? nil : .red)
                    Toggle(isOn: $live.monitor) { Image(systemName: "headphones") }
                        .toggleStyle(.button)
                        .help("Listen to the enhanced mic (use headphones)")
                }
                .controlSize(.large)

                if let since = live.recordingSince {
                    TimelineView(.periodic(from: .now, by: 1)) { ctx in
                        Text("Recording raw + enhanced · \(Duration.seconds(ctx.date.timeIntervalSince(since)).formatted(.time(pattern: .minuteSecond)))")
                            .font(.caption).foregroundStyle(.red)
                    }
                } else if let last = live.lastRecording {
                    Button("Show last recording in Finder") { NSWorkspace.shared.activateFileViewerSelecting([last.enhanced, last.raw]) }
                        .buttonStyle(.link).font(.caption)
                }
            }

            Divider()
            HStack {
                Button("Mastering & Settings…") {
                    openWindow(id: "main")
                    NSApp.activate(ignoringOtherApps: true)
                }
                Spacer()
                Button("Quit") { NSApp.terminate(nil) }
            }
            .buttonStyle(.borderless)
        }
        .padding(14)
        .frame(width: 340)
    }
}

struct StatusPill: View {
    let status: LiveController.Status
    let muted: Bool

    var body: some View {
        let (text, color): (String, Color) = {
            if muted { return ("Muted", .orange) }
            switch status {
            case .running: return ("Live", .green)
            case .waiting: return ("Standby", .secondary)
            case .off: return ("Off", .secondary)
            case .driverMissing: return ("Not installed", .orange)
            case .noMicrophone: return ("No mic", .orange)
            case .failed: return ("Error", .red)
            }
        }()
        Text(text)
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(Capsule().fill(color.opacity(0.18)))
            .foregroundStyle(color)
    }
}

struct DriverMissingCard: View {
    @EnvironmentObject var system: SystemSupport

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Install the virtual microphone").font(.subheadline.weight(.semibold))
            Text("VEN adds an input called “VEN Enhanced Mic” that any app can record from. Installing it needs your admin password once, and your Mac's audio pauses for a second.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Button("Install VEN Enhanced Mic") { system.installDriver() }
                .buttonStyle(.borderedProminent)
            if let msg = system.installMessage { Text(msg).font(.caption).foregroundStyle(.secondary) }
        }
    }
}

struct MicPicker: View {
    @EnvironmentObject var live: LiveController

    var body: some View {
        let inputs = live.devices.filter { $0.inputChannels > 0 && !$0.isVEN }
        let auto = AudioDevices.automaticInput()?.name ?? "none"
        Picker(selection: $live.inputUID) {
            Text("Automatic (\(auto))").tag(LiveController.automaticInputUID)
            Divider()
            ForEach(inputs) { Text($0.name).tag($0.uid) }
        } label: {
            Image(systemName: "mic")
        }
    }
}

struct PresetChips: View {
    @EnvironmentObject var live: LiveController

    var body: some View {
        HStack(spacing: 6) {
            ForEach(VoicePreset.all) { preset in
                let selected = live.presetID == preset.id
                Button(preset.name) { live.applyPreset(preset) }
                    .buttonStyle(.plain)
                    .font(.caption.weight(selected ? .semibold : .regular))
                    .padding(.horizontal, 8).padding(.vertical, 4)
                    .background(Capsule().fill(selected ? Color.accentColor.opacity(0.25) : Color.secondary.opacity(0.12)))
                    .help(preset.summary)
            }
        }
    }
}

struct HoldToMuteButton: View {
    @EnvironmentObject var live: LiveController
    @State private var holding = false

    var body: some View {
        Label(live.settings.mute ? "Muted" : "Cough", systemImage: live.settings.mute ? "mic.slash.fill" : "mic.fill")
            .frame(maxWidth: .infinity)
            .padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: 6).fill(live.settings.mute ? Color.orange.opacity(0.35) : Color.secondary.opacity(0.15)))
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { _ in if !holding { holding = true; live.settings.mute = true } }
                .onEnded { _ in holding = false; live.settings.mute = false })
            .help("Hold to mute — or hold ⌃⌥C from any app")
    }
}

struct LiveMeters: View {
    @EnvironmentObject var live: LiveController
    var compact = false

    var body: some View {
        let m = live.meters
        VStack(alignment: .leading, spacing: 6) {
            MeterRow(label: "Mic", rms: m.in_rms_db, peak: m.in_peak_db)
            MeterRow(label: "Out", rms: m.out_rms_db, peak: m.out_peak_db)
            HStack(spacing: 10) {
                Circle().fill(m.vad > 0.5 ? Color.green : Color.secondary.opacity(0.3)).frame(width: 7, height: 7)
                Text(m.vad > 0.5 ? "Speech" : "Quiet")
                Text(String(format: "Leveler %+.0f dB", m.leveler_gain_db))
                if m.limiter_gr_db > 0.5 { Text(String(format: "Limit −%.0f", m.limiter_gr_db)) }
                if m.hum_hz > 0 { Text("Hum \(Int(m.hum_hz)) Hz") }
                Spacer()
                if case .running = live.status {
                    Text(String(format: "%.0f ms", live.latencyMs)).help("Processing delay")
                }
            }
            .font(.caption2.monospacedDigit())
            .foregroundStyle(.secondary)
            if !compact || live.appsUsingMic > 0 {
                Text(live.appsUsingMic == 1 ? "1 app is recording from VEN Enhanced Mic" : "\(live.appsUsingMic) apps are recording from VEN Enhanced Mic")
                    .font(.caption2).foregroundStyle(.secondary)
            }
        }
    }
}

struct MeterRow: View {
    let label: String
    let rms: Float
    let peak: Float

    var body: some View {
        HStack(spacing: 8) {
            Text(label).font(.caption2).foregroundStyle(.secondary).frame(width: 26, alignment: .leading)
            GeometryReader { geo in
                let w = geo.size.width
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 3).fill(Color.secondary.opacity(0.15))
                    RoundedRectangle(cornerRadius: 3)
                        .fill(LinearGradient(colors: [.green, .green, .yellow, .red], startPoint: .leading, endPoint: .trailing))
                        .frame(width: w * fraction(rms))
                        .animation(.linear(duration: 0.05), value: rms)
                    Rectangle().fill(Color.primary.opacity(0.7)).frame(width: 2).offset(x: max(0, w * fraction(peak) - 2))
                }
            }
            .frame(height: 8)
        }
    }

    private func fraction(_ db: Float) -> CGFloat {
        CGFloat(min(max((db + 60) / 60, 0), 1))
    }
}
