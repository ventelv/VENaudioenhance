import AVFoundation
import Combine
import CoreAudio
import Foundation
import VENDSP

/// App-level state for the live mic: which mic, when to run, settings, meters and recording.
@MainActor
public final class LiveController: ObservableObject {
    public enum Mode: String, Codable, CaseIterable, Identifiable {
        case onDemand, alwaysOn, off
        public var id: String { rawValue }
        public var label: String {
            switch self {
            case .onDemand: return "When an app uses it"
            case .alwaysOn: return "Always on"
            case .off: return "Off"
            }
        }
    }

    public enum Status: Equatable {
        case driverMissing
        case noMicrophone
        case off
        case waiting            // on demand, nobody recording from VEN
        case running(String)    // mic name
        case failed(String)
    }

    public static let automaticInputUID = "automatic"

    @Published public var mode: Mode { didSet { save(); reconcile() } }
    @Published public var inputUID: String { didSet { save(); restart() } }
    @Published public var inputChannel: Int { didSet { save(); restart() } }   // -1 = mix all
    @Published public var settings: VoiceSettings {
        didSet {
            engine?.apply(settings)
            if settings.mute == oldValue.mute { save() }
            // Switching noise engines swaps how the audio is processed, so the engine is rebuilt.
            if settings.studioNoise != oldValue.studioNoise { restart() }
        }
    }
    @Published public var presetID: String? { didSet { save() } }
    @Published public var monitor = false { didSet { try? engine?.setMonitor(monitor) } }

    @Published public private(set) var status: Status = .off
    @Published public private(set) var devices: [AudioDevice] = []
    @Published public private(set) var meters = ven_meters()
    @Published public private(set) var latencyMs: Double = 0
    @Published public private(set) var appsUsingMic = 0
    @Published public private(set) var recordingSince: Date?
    @Published public private(set) var lastRecording: (raw: URL, enhanced: URL)?

    public var recordingsFolder: URL {
        let url = FileManager.default.urls(for: .musicDirectory, in: .userDomainMask)[0].appendingPathComponent("VEN Recordings")
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private var engine: LiveEngine?
    private var venDevice: AudioDevice?
    private var listeners: [AudioDevices.ListenerToken] = []
    private var venListener: AudioDevices.ListenerToken?
    private var meterTimer: Timer?
    private var stopWork: DispatchWorkItem?
    private var restartWork: DispatchWorkItem?
    private let defaults = UserDefaults.standard

    public init() {
        mode = Mode(rawValue: defaults.string(forKey: "live.mode") ?? "") ?? .onDemand
        inputUID = defaults.string(forKey: "live.input") ?? Self.automaticInputUID
        inputChannel = defaults.object(forKey: "live.channel") as? Int ?? -1
        presetID = defaults.string(forKey: "live.preset") ?? VoicePreset.podcast.id
        if let data = defaults.data(forKey: "live.settings"), let s = decodeKeepingDefaults(data, defaults: VoiceSettings()) {
            settings = s
        } else {
            settings = VoicePreset.podcast.settings
        }
        settings.mute = false
        settings.bypass = false

        let system = AudioObjectID(kAudioObjectSystemObject)
        listeners.append(AudioDevices.addListener(system, kAudioHardwarePropertyDevices) { [weak self] in
            Task { @MainActor in self?.devicesChanged() }
        })
        devicesChanged()
        AVCaptureDevice.requestAccess(for: .audio) { _ in }
    }

    // MARK: Public actions

    public func applyPreset(_ preset: VoicePreset) {
        var s = preset.settings
        s.bypass = settings.bypass
        s.mute = settings.mute
        settings = s
        presetID = preset.id
    }

    public func toggleRecording() {
        if recordingSince != nil {
            lastRecording = engine?.stopRecording()
            recordingSince = nil
            reconcile()
            return
        }
        if engine == nil { start() }   // recording works even with no app on the virtual mic
        guard let engine else { return }
        let stamp = DateFormatter.localizedString(from: Date(), dateStyle: .short, timeStyle: .short)
            .replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: ".")
        do {
            try engine.startRecording(folder: recordingsFolder, baseName: "VEN \(stamp)")
            recordingSince = Date()
        } catch {
            status = .failed(error.localizedDescription)
        }
    }

    public var selectedInput: AudioDevice? {
        let inputs = devices.filter { $0.inputChannels > 0 && !$0.isVEN }
        if inputUID != Self.automaticInputUID, let chosen = inputs.first(where: { $0.uid == inputUID }) { return chosen }
        return AudioDevices.automaticInput()
    }

    // MARK: State machine

    private func devicesChanged() {
        devices = AudioDevices.all()
        let ven = devices.first { $0.isVEN }
        if ven?.id != venDevice?.id {
            if let venListener { AudioDevices.removeListener(venListener) }
            venListener = nil
            venDevice = ven
            if let ven {
                venListener = AudioDevices.addListener(ven.id, venClientCountSelector) { [weak self] in
                    Task { @MainActor in self?.reconcile() }
                }
            }
        }
        // The mic we're using vanished or a better automatic choice appeared.
        if let engine, engine.input.id != selectedInput?.id || !devices.contains(where: { $0.id == engine.input.id }) {
            restart()
        } else {
            reconcile()
        }
    }

    private func reconcile() {
        guard let ven = venDevice else {
            stop()
            status = .driverMissing
            return
        }
        appsUsingMic = AudioDevices.venClientCount(ven.id)
        let wanted: Bool
        switch mode {
        case .off: wanted = recordingSince != nil
        case .alwaysOn: wanted = true
        case .onDemand: wanted = appsUsingMic > 0 || recordingSince != nil
        }
        if wanted {
            stopWork?.cancel()
            stopWork = nil
            if engine == nil { start() }
        } else if engine != nil, stopWork == nil {
            // A short grace period avoids flapping when an app reopens the mic.
            let work = DispatchWorkItem { [weak self] in
                Task { @MainActor in
                    self?.stopWork = nil
                    self?.stop()
                    self?.reconcile()
                }
            }
            stopWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 2, execute: work)
        } else if engine == nil {
            status = mode == .off ? .off : .waiting
        }
    }

    private func start() {
        guard let ven = venDevice else { status = .driverMissing; return }
        guard let mic = selectedInput else { status = .noMicrophone; return }
        do {
            let e = try LiveEngine(input: mic, output: ven.id, channel: inputChannel >= 0 ? inputChannel : nil, settings: settings)
            try e.start()
            if monitor { try? e.setMonitor(true) }
            engine = e
            status = .running(mic.name)
            startMeters()
        } catch {
            engine = nil
            status = .failed(error.localizedDescription)
        }
    }

    private func stop() {
        if recordingSince != nil {
            lastRecording = engine?.stopRecording()
            recordingSince = nil
        }
        engine?.stop()
        engine = nil
        meterTimer?.invalidate()
        meterTimer = nil
        meters = ven_meters()
    }

    private func restart() {
        restartWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                let wasRunning = self.engine != nil
                self.stop()
                if wasRunning { self.start() }
                self.reconcile()
            }
        }
        restartWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: work)
    }

    private func startMeters() {
        meterTimer?.invalidate()
        meterTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 20, repeats: true) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in self.updateMeters() }
        }
    }

    private func updateMeters() {
        guard let engine else { return }
        meters = engine.meters()
        latencyMs = engine.latencyMs
    }

    private func save() {
        defaults.set(mode.rawValue, forKey: "live.mode")
        defaults.set(inputUID, forKey: "live.input")
        defaults.set(inputChannel, forKey: "live.channel")
        defaults.set(presetID, forKey: "live.preset")
        var s = settings
        s.mute = false
        s.bypass = false
        if let data = try? JSONEncoder().encode(s) { defaults.set(data, forKey: "live.settings") }
    }
}
