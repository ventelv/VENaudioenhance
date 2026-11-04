import AppKit
import SwiftUI
import UniformTypeIdentifiers
import VENCore

struct MainWindow: View {
    @State private var tab = "master"

    var body: some View {
        TabView(selection: $tab) {
            MasteringTab().tabItem { Label("File Mastering", systemImage: "waveform.badge.magnifyingglass") }.tag("master")
            LiveTab().tabItem { Label("Live Mic", systemImage: "mic") }.tag("live")
            SetupTab().tabItem { Label("Setup", systemImage: "gearshape") }.tag("setup")
        }
        .padding()
    }
}

// MARK: - Live

struct LiveTab: View {
    @EnvironmentObject var live: LiveController

    var body: some View {
        HSplitView {
            Form {
                Section {
                    MicPicker()
                    if let mic = live.selectedInput, mic.inputChannels > 1 {
                        Picker("Channel", selection: $live.inputChannel) {
                            Text("Mix all channels").tag(-1)
                            ForEach(0..<mic.inputChannels, id: \.self) { Text("Channel \($0 + 1)").tag($0) }
                        }
                    }
                    Picker("Run", selection: $live.mode) {
                        ForEach(LiveController.Mode.allCases) { Text($0.label).tag($0) }
                    }
                    PresetChips()
                }
                Section("Cleanup") {
                    if VoiceIsolation.isAvailable {
                        StageToggle("Voice isolation", isOn: $live.settings.voiceIsolation) {
                            SliderRow(value: $live.settings.voiceIsolationStrength, range: 0...1, format: "%.0f%%", scale: 100)
                            Text("Keeps only the voice close to the mic: kids, TV and people in the background are removed. Adds about 55 ms of delay.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    StageToggle("Rumble filter", isOn: $live.settings.highPassEnabled) {
                        SliderRow(value: $live.settings.highPassHz, range: 40...200, format: "%.0f Hz")
                    }
                    Picker("Hum removal", selection: $live.settings.humMode) {
                        ForEach(VoiceSettings.HumMode.allCases) { Text($0.label).tag($0) }
                    }
                    StageToggle("Noise reduction", isOn: $live.settings.noiseReductionEnabled) {
                        SliderRow(value: $live.settings.noiseReductionStrength, range: 0...1, format: "%.0f%%", scale: 100)
                        Picker("Engine", selection: $live.settings.studioNoise) {
                            Text(StudioDenoiser.isAvailable ? "Studio (DeepFilterNet)" : "Studio — not installed").tag(true)
                            Text("Standard (RNNoise)").tag(false)
                        }
                        Text(live.settings.studioNoise && StudioDenoiser.isAvailable
                             ? "Best on changing noise (voices, traffic, clatter). Adds about 50 ms of delay."
                             : "Lightest on CPU and lowest delay; best on steady noise like fans.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    StageToggle("Pause gate", isOn: $live.settings.pauseGateEnabled) {
                        SliderRow(value: $live.settings.pauseGateDepthDB, range: 3...30, format: "−%.0f dB")
                    }
                }
                Section("Tone") {
                    StageToggle("Voice EQ", isOn: $live.settings.voiceEQEnabled) {
                        SliderRow(value: $live.settings.voiceEQAmount, range: 0...1, format: "%.0f%%", scale: 100)
                    }
                    StageToggle("De-esser", isOn: $live.settings.deEsserEnabled) {
                        SliderRow(value: $live.settings.deEsserAmount, range: 0...1, format: "%.0f%%", scale: 100)
                    }
                }
                Section("Level") {
                    StageToggle("Leveler", isOn: $live.settings.levelerEnabled) {
                        SliderRow(value: $live.settings.levelerTargetDB, range: -30 ... -12, format: "%.0f dBFS")
                        SliderRow(value: $live.settings.levelerMaxGainDB, range: 0...24, format: "max +%.0f dB")
                    }
                    StageToggle("Compressor", isOn: $live.settings.compressorEnabled) {
                        SliderRow(value: $live.settings.compressorAmount, range: 0...1, format: "%.0f%%", scale: 100)
                    }
                    StageToggle("Limiter", isOn: $live.settings.limiterEnabled) {
                        SliderRow(value: $live.settings.limiterCeilingDB, range: -6...0, format: "%.1f dBTP")
                    }
                    SliderRow(label: "Output gain", value: $live.settings.outputGainDB, range: -12...12, format: "%+.1f dB")
                }
            }
            .formStyle(.grouped)
            .frame(minWidth: 420)
            .onChange(of: live.settings) { _ in
                if let preset = VoicePreset.all.first(where: { $0.id == live.presetID }), !sameIgnoringToggles(preset.settings, live.settings) {
                    live.presetID = nil
                }
            }

            VStack(alignment: .leading, spacing: 14) {
                StatusPill(status: live.status, muted: live.settings.mute)
                statusText
                LiveMeters()
                Toggle("Enhance (turn off to compare with the raw mic)",
                       isOn: Binding(get: { !live.settings.bypass }, set: { live.settings.bypass = !$0 }))
                HStack {
                    HoldToMuteButton()
                    Button(live.recordingSince == nil ? "Record raw + enhanced" : "Stop recording") { live.toggleRecording() }
                }
                Text("Pick **VEN Enhanced Mic** as the microphone in Zoom, QuickTime, OBS, GarageBand or any other app. With “When an app uses it”, VEN only opens your real mic while something is recording.")
                    .font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer()
            }
            .padding()
            .frame(minWidth: 280)
        }
    }

    @ViewBuilder private var statusText: some View {
        switch live.status {
        case .running(let mic): Text("Enhancing \(mic)")
        case .waiting: Text("Waiting for an app to use VEN Enhanced Mic")
        case .off: Text("Live enhancement is off")
        case .driverMissing: Text("VEN Enhanced Mic isn't installed — see Setup")
        case .noMicrophone: Text("No microphone found")
        case .failed(let msg): Text(msg).foregroundStyle(.red)
        }
    }

    private func sameIgnoringToggles(_ a: VoiceSettings, _ b: VoiceSettings) -> Bool {
        var a = a, b = b
        a.bypass = false; b.bypass = false
        a.mute = false; b.mute = false
        return a == b
    }
}

struct StageToggle<Content: View>: View {
    let title: String
    @Binding var isOn: Bool
    @ViewBuilder let content: Content

    init(_ title: String, isOn: Binding<Bool>, @ViewBuilder content: () -> Content) {
        self.title = title
        _isOn = isOn
        self.content = content()
    }

    var body: some View {
        Toggle(title, isOn: $isOn)
        if isOn { content }
    }
}

struct SliderRow: View {
    var label: String? = nil
    @Binding var value: Float
    let range: ClosedRange<Float>
    let format: String
    var scale: Float = 1

    var body: some View {
        HStack {
            if let label { Text(label) }
            Slider(value: $value, in: range)
            Text(String(format: format, value * scale)).monospacedDigit().foregroundStyle(.secondary).frame(width: 82, alignment: .trailing)
        }
    }
}

// MARK: - Mastering

struct MasteringTab: View {
    @EnvironmentObject var queue: MasteringQueue
    @State private var dropTargeted = false
    @State private var reviewing: ReviewTarget?
    @State private var postponed: Set<UUID> = []   // reviews the user put off with "Later"
    @State private var showingSession = false

    struct ReviewTarget: Identifiable { let id: UUID }

    var body: some View {
        HSplitView {
            VStack(spacing: 12) {
                dropZone
                jobList
            }
            .padding(.trailing, 8)
            .frame(minWidth: 380)

            MasteringSettingsForm()
                .frame(minWidth: 320, idealWidth: 340)
        }
        .sheet(item: $reviewing) { target in
            if let analysis = queue.analyses[target.id], let job = queue.jobs.first(where: { $0.id == target.id }) {
                CutReviewView(analysis: analysis, title: job.title,
                              export: { cuts in queue.finishReview(target.id, cuts: cuts); reviewing = nil },
                              discard: { queue.discardReview(target.id); reviewing = nil },
                              close: { postponed.insert(target.id); reviewing = nil })
            }
        }
        .sheet(isPresented: $showingSession) {
            MultitrackSheet { tracks, name in
                queue.addSession(tracks, name: name)
                showingSession = false
            } cancel: {
                showingSession = false
            }
        }
        // When a file is ready for review, open it (one at a time; "Later" leaves it in the queue).
        .onReceive(queue.$jobs) { jobs in
            guard reviewing == nil else { return }
            if let next = jobs.first(where: { if case .needsReview = $0.state { return !postponed.contains($0.id) }; return false }) {
                reviewing = ReviewTarget(id: next.id)
            }
        }
    }

    private var dropZone: some View {
        VStack(spacing: 8) {
            Image(systemName: "square.and.arrow.down.on.square").font(.system(size: 30)).foregroundStyle(.secondary)
            Text("Drop recordings here").font(.headline)
            Text("Noise & hum removal, AutoEQ, leveling, loudness to \(String(format: "%.0f", queue.settings.loudnessTarget)) LUFS")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Button("Choose Files…") { chooseFiles() }
                Button("Multitrack Session…") { showingSession = true }
                    .help("One recording per person (plus music): each is cleaned up, then mixed")
            }
        }
        .frame(maxWidth: .infinity, minHeight: 150)
        .background(RoundedRectangle(cornerRadius: 12)
            .strokeBorder(style: StrokeStyle(lineWidth: 2, dash: [6]))
            .foregroundStyle(dropTargeted ? Color.accentColor : Color.secondary.opacity(0.4)))
        .onDrop(of: [.fileURL], isTargeted: $dropTargeted) { providers in
            for p in providers {
                _ = p.loadObject(ofClass: URL.self) { url, _ in
                    if let url { Task { @MainActor in queue.add([url]) } }
                }
            }
            return true
        }
    }

    private var jobList: some View {
        VStack(alignment: .leading) {
            HStack {
                Text("Queue").font(.headline)
                Spacer()
                if !queue.jobs.isEmpty { Button("Clear finished") { queue.clearFinished() }.buttonStyle(.link) }
            }
            if queue.jobs.isEmpty {
                Text("Nothing processed yet.").foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(queue.jobs.reversed()) { job in JobRow(job: job) { postponed.remove(job.id); reviewing = ReviewTarget(id: job.id) } }
                    .listStyle(.inset(alternatesRowBackgrounds: true))
            }
        }
    }

    private func chooseFiles() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = [.audio, .movie]
        if panel.runModal() == .OK { queue.add(panel.urls) }
    }
}

struct JobRow: View {
    let job: MasteringQueue.Job
    let review: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                if let tracks = job.tracks {
                    Image(systemName: "person.2.wave.2").foregroundStyle(.secondary).help("\(tracks.count) tracks")
                }
                Text(job.title).lineLimit(1).truncationMode(.middle)
                Spacer()
                if case .done = job.state, let out = job.output {
                    Button { NSWorkspace.shared.activateFileViewerSelecting([out]) } label: { Image(systemName: "magnifyingglass") }
                        .buttonStyle(.borderless).help("Show in Finder")
                }
            }
            switch job.state {
            case .queued: Text("Waiting").font(.caption).foregroundStyle(.secondary)
            case .running(let f, let stage):
                ProgressView(value: f) { Text(stage).font(.caption) }
            case .needsReview(let n):
                HStack {
                    Label("\(n) suggested cut\(n == 1 ? "" : "s") to check", systemImage: "scissors").font(.caption)
                    Spacer()
                    Button("Review…", action: review).controlSize(.small).buttonStyle(.borderedProminent)
                }
            case .done(let summary):
                Label(summary, systemImage: "checkmark.circle.fill").font(.caption).foregroundStyle(.green)
            case .failed(let msg):
                Label(msg, systemImage: "xmark.octagon.fill").font(.caption).foregroundStyle(.red)
            }
        }
        .padding(.vertical, 2)
    }
}

struct MasteringSettingsForm: View {
    @EnvironmentObject var queue: MasteringQueue

    var body: some View {
        Form {
            Section("Output") {
                Picker("Loudness", selection: $queue.settings.loudnessTarget) {
                    ForEach(MasteringSettings.loudnessTargets, id: \.value) { Text($0.label).tag($0.value) }
                }
                Picker("Format", selection: $queue.settings.format) {
                    ForEach(ExportFormat.allCases) { f in
                        Text(f.isAvailable ? f.label : "\(f.label) — brew install lame").tag(f)
                    }
                }
                Picker("Sample rate", selection: $queue.settings.outputRate) {
                    Text("48 kHz").tag(48000.0)
                    Text("44.1 kHz").tag(44100.0)
                }
                Picker("Channels", selection: $queue.settings.channels) {
                    ForEach(MasteringSettings.Channels.allCases) { Text($0.label).tag($0) }
                }
                FolderRow(title: "Save to", url: $queue.outputFolder, placeholder: "Next to the original")
            }
            Section("Cleanup") {
                if VoiceIsolation.isAvailable {
                    Toggle("Voice isolation", isOn: $queue.settings.voiceIsolation)
                    if queue.settings.voiceIsolation {
                        SliderRow(value: $queue.settings.voiceIsolationStrength, range: 0...1, format: "%.0f%%", scale: 100)
                        Text("Keeps only the main voice: kids, TV and people in the background are removed.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                Toggle("Noise reduction", isOn: $queue.settings.noiseReduction)
                if queue.settings.noiseReduction {
                    SliderRow(value: $queue.settings.noiseStrength, range: 0...1, format: "%.0f%%", scale: 100)
                    Picker("Engine", selection: $queue.settings.noiseEngine) {
                        ForEach(MasteringSettings.NoiseEngine.allCases) { e in
                            Text(e == .studio && !StudioDenoiser.isAvailable ? "\(e.label) — not installed" : e.label).tag(e)
                        }
                    }
                    if queue.settings.noiseEngine == .studio && !StudioDenoiser.isAvailable {
                        Text("Build it once with scripts/build-deepfilter.sh, then rebuild the app.")
                            .font(.caption).foregroundStyle(.orange)
                    }
                }
                Picker("Hum removal", selection: $queue.settings.humMode) {
                    ForEach(VoiceSettings.HumMode.allCases) { Text($0.label).tag($0) }
                }
                Toggle("Rumble filter", isOn: $queue.settings.highPass)
                Toggle("Breath reduction", isOn: $queue.settings.breathReduction)
            }
            Section("Tone & level") {
                Toggle("AutoEQ", isOn: $queue.settings.autoEQ)
                Toggle("De-esser", isOn: $queue.settings.deEsser)
                Toggle("Adaptive leveler", isOn: $queue.settings.leveler)
                if queue.settings.leveler {
                    SliderRow(value: $queue.settings.levelerStrength, range: 0...1, format: "%.0f%%", scale: 100)
                }
                SliderRow(label: "Compression", value: $queue.settings.compressorAmount, range: 0...1, format: "%.0f%%", scale: 100)
                Picker("True peak limit", selection: $queue.settings.truePeakLimit) {
                    Text("−1 dBTP").tag(-1.0)
                    Text("−2 dBTP").tag(-2.0)
                    Text("−0.5 dBTP").tag(-0.5)
                }
            }
            Section("Cutting") {
                Toggle("Cut filler words (um, uh, er…)", isOn: $queue.settings.cutFillers)
                Toggle("Cut coughs", isOn: $queue.settings.cutCoughs)
                Toggle("Shorten long pauses", isOn: $queue.settings.cutSilence)
                if queue.settings.cutSilence {
                    Stepper(value: $queue.settings.maxPauseSeconds, in: 0.3...3, step: 0.1) {
                        Text(String(format: "Keep at most %.1f s", queue.settings.maxPauseSeconds))
                    }
                }
                if queue.settings.cutsAnything {
                    Toggle("Let me review cuts before export", isOn: $queue.settings.reviewCuts)
                }
            }
            Section("Transcript") {
                HStack {
                    ForEach(Transcript.Format.allCases) { f in
                        Toggle(f.label, isOn: Binding(
                            get: { queue.settings.transcriptFormats.contains(f) },
                            set: { on in
                                queue.settings.transcriptFormats.removeAll { $0 == f }
                                if on { queue.settings.transcriptFormats.append(f) }
                            }))
                        .toggleStyle(.checkbox)
                    }
                }
                Picker("Language", selection: $queue.settings.language) {
                    ForEach(SpeechLanguage.all, id: \.code) { Text($0.name).tag($0.code) }
                }
                SpeechStatus()
            }
            Section("Intro & outro") {
                FileRow(title: "Intro", path: $queue.settings.introPath)
                if queue.settings.introPath != nil {
                    Stepper(value: $queue.settings.introOverlap, in: 0...20, step: 0.5) {
                        Text(String(format: "Speech starts %.1f s before it ends", queue.settings.introOverlap))
                    }
                }
                FileRow(title: "Outro", path: $queue.settings.outroPath)
                if queue.settings.outroPath != nil {
                    Stepper(value: $queue.settings.outroOverlap, in: 0...20, step: 0.5) {
                        Text(String(format: "Starts %.1f s before speech ends", queue.settings.outroOverlap))
                    }
                }
                SliderRow(label: "Music under speech", value: $queue.settings.duckingDB, range: 6...30, format: "−%.0f dB")
                Text("Matched to your voice's loudness and turned down while you talk. Also used for music tracks in multitrack sessions.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Video & chapters") {
                Toggle("For videos, also write the video with the new audio", isOn: $queue.settings.exportVideo)
                Text("Cuts are made in the picture too. For chapter marks, put a text file named like the recording, ending in .chapters.txt, next to it, with lines such as “0:00 Intro” or “12:30 Interview”. They're embedded in M4A and video files and saved as Podcasting 2.0 JSON.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Watch folder") {
                FolderRow(title: "Auto-process", url: $queue.watchFolder, placeholder: "Off")
                Text("New recordings that appear in this folder are mastered automatically with these settings.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

struct FolderRow: View {
    let title: String
    @Binding var url: URL?
    let placeholder: String

    var body: some View {
        HStack {
            Text(title)
            Spacer()
            Text(url?.lastPathComponent ?? placeholder).foregroundStyle(.secondary).lineLimit(1)
            Button("Choose…") {
                let panel = NSOpenPanel()
                panel.canChooseDirectories = true
                panel.canChooseFiles = false
                panel.canCreateDirectories = true
                if panel.runModal() == .OK { url = panel.url }
            }
            if url != nil { Button { url = nil } label: { Image(systemName: "xmark.circle.fill") }.buttonStyle(.borderless) }
        }
    }
}

// MARK: - Setup

struct SetupTab: View {
    @EnvironmentObject var live: LiveController
    @EnvironmentObject var system: SystemSupport

    var body: some View {
        Form {
            Section("Virtual microphone") {
                HStack {
                    Image(systemName: live.status == .driverMissing ? "xmark.circle.fill" : "checkmark.circle.fill")
                        .foregroundStyle(live.status == .driverMissing ? .orange : .green)
                    Text(live.status == .driverMissing ? "VEN Enhanced Mic is not installed" : "VEN Enhanced Mic is installed")
                    Spacer()
                    Button(live.status == .driverMissing ? "Install…" : "Reinstall…") { system.installDriver() }
                }
                if let msg = system.installMessage { Text(msg).font(.caption).foregroundStyle(.secondary) }
                Text("To remove it later: run scripts/uninstall-driver.sh from the project folder.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("General") {
                Toggle("Open at login", isOn: Binding(get: { system.launchAtLogin }, set: { system.setLaunchAtLogin($0) }))
                LabeledContent("Cough key", value: "Hold ⌃⌥C in any app to mute")
                LabeledContent("Recordings") {
                    Button("Open folder") { NSWorkspace.shared.open(live.recordingsFolder) }
                }
            }
            SpeechModelsSection()
            Section("Command line") {
                Text("ven-cli process FILE --target -16 --format flac masters a file from Terminal; ven-cli selftest checks the DSP.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}
