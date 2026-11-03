import AudioToolbox
import AVFoundation
import CoreAudio
import Foundation
import VENDSP

public struct LiveEngineError: LocalizedError {
    public let message: String
    public var errorDescription: String? { message }
    init(_ message: String, _ status: OSStatus = noErr) {
        self.message = status == noErr ? message : "\(message) (error \(status))"
    }
}

/// Owns the AUHAL units around the C live core: mic in, VEN Enhanced Mic out, optional headphone monitor.
public final class LiveEngine {
    public let input: AudioDevice
    public let output: AudioDeviceID
    public let inputRate: Double
    public let inputChannels: Int

    private let core: OpaquePointer
    private var inputUnit: AudioUnit?
    private var outputUnit: AudioUnit?
    private var monitorUnit: AudioUnit?
    private var recorder: TapRecorder?
    /// DeepFilterNet for the Studio engine; freed after the core (and its worker thread) is gone.
    private var studio: StudioDenoiser.LiveState?
    public var usesStudio: Bool { studio != nil }

    public init(input: AudioDevice, output: AudioDeviceID, channel: Int? = nil, settings: VoiceSettings) throws {
        self.input = input
        self.output = output

        let unit = try Self.makeHAL()
        inputUnit = unit
        var one: UInt32 = 1, zero: UInt32 = 0
        try Self.check(AudioUnitSetProperty(unit, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Input, 1, &one, 4), "Enable mic input")
        try Self.check(AudioUnitSetProperty(unit, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Output, 0, &zero, 4), "Disable mic output")
        var dev = input.id
        try Self.check(AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &dev,
                                            UInt32(MemoryLayout<AudioDeviceID>.size)), "Select \(input.name)")
        var hw = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        try Self.check(AudioUnitGetProperty(unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, 1, &hw, &size), "Read mic format")
        guard hw.mSampleRate > 0, hw.mChannelsPerFrame > 0 else { throw LiveEngineError("\(input.name) reported no usable input format") }
        inputRate = hw.mSampleRate
        inputChannels = Int(hw.mChannelsPerFrame)

        var client = Self.floatFormat(rate: inputRate, channels: UInt32(inputChannels))
        try Self.check(AudioUnitSetProperty(unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output, 1, &client, size), "Set mic format")
        var maxFrames: UInt32 = 4096
        AudioUnitSetProperty(unit, kAudioUnitProperty_MaximumFramesPerSlice, kAudioUnitScope_Global, 0, &maxFrames, 4)

        core = ven_live_create(inputRate, Int32(inputChannels), Int32(channel ?? -1))
        ven_live_set_input_unit(core, unit)
        if settings.studioNoise, let st = StudioDenoiser.LiveState() {
            studio = st
            ven_live_start_worker(core, st.process, st.setAtten, st.state, Int32(st.delay))
        }
        apply(settings)

        var inputCallback = AURenderCallbackStruct(inputProc: ven_live_input_proc, inputProcRefCon: UnsafeMutableRawPointer(core))
        try Self.check(AudioUnitSetProperty(unit, kAudioOutputUnitProperty_SetInputCallback, kAudioUnitScope_Global, 0, &inputCallback,
                                            UInt32(MemoryLayout<AURenderCallbackStruct>.size)), "Install mic callback")

        outputUnit = try Self.makeOutput(device: output, proc: ven_live_output_proc, refCon: UnsafeMutableRawPointer(core))
        AudioDevices.setBufferSize(input.id, frames: 256)
        AudioDevices.setBufferSize(output, frames: 256)
    }

    deinit {
        stop()
        for unit in [inputUnit, outputUnit, monitorUnit].compactMap({ $0 }) {
            AudioUnitUninitialize(unit)
            AudioComponentInstanceDispose(unit)
        }
        ven_live_destroy(core)
    }

    public func start() throws {
        guard let inputUnit, let outputUnit else { return }
        try Self.check(AudioUnitInitialize(inputUnit), "Start \(input.name)")
        try Self.check(AudioOutputUnitStart(outputUnit), "Start VEN Enhanced Mic")
        try Self.check(AudioOutputUnitStart(inputUnit), "Start \(input.name)")
    }

    public func stop() {
        stopRecording()
        if let inputUnit { AudioOutputUnitStop(inputUnit) }
        if let outputUnit { AudioOutputUnitStop(outputUnit) }
        if let monitorUnit { AudioOutputUnitStop(monitorUnit) }
    }

    public func apply(_ settings: VoiceSettings) {
        var params = settings.params
        if studio != nil {
            // DeepFilterNet does the denoising; RNNoise in the chain then only detects speech.
            params.nr_enabled = 0
            let on = settings.noiseReductionEnabled && !settings.bypass
            ven_live_set_denoise(core, on ? 1 : 0, StudioDenoiser.attenuationLimit(settings.noiseReductionStrength))
        }
        ven_chain_set_params(ven_live_chain(core), &params)
    }

    public func meters() -> ven_meters {
        var m = ven_meters()
        ven_chain_get_meters(ven_live_chain(core), &m)
        return m
    }

    public func stats() -> ven_live_stats {
        var s = ven_live_stats()
        ven_live_get_stats(core, &s)
        return s
    }

    /// Processing delay inside the chain, plus the input backlog the drift controller keeps.
    public var latencyMs: Double {
        Double(ven_chain_latency(ven_live_chain(core)) + Int32(studio?.delay ?? 0)) / 48.0 + stats().ring_fill_ms
    }

    // MARK: Headphone monitor

    public func setMonitor(_ enabled: Bool) throws {
        if enabled {
            if monitorUnit == nil {
                monitorUnit = try Self.makeOutput(device: AudioDevices.defaultOutput(), proc: ven_live_monitor_proc,
                                                  refCon: UnsafeMutableRawPointer(core))
            }
            ven_live_set_monitor(core, 1)
            try Self.check(AudioOutputUnitStart(monitorUnit!), "Start monitor")
        } else {
            ven_live_set_monitor(core, 0)
            if let monitorUnit { AudioOutputUnitStop(monitorUnit) }
        }
    }

    // MARK: Recording raw + enhanced

    public var isRecording: Bool { recorder != nil }

    public func startRecording(folder: URL, baseName: String) throws {
        guard recorder == nil else { return }
        let raw = folder.appendingPathComponent("\(baseName) raw.wav")
        let enhanced = folder.appendingPathComponent("\(baseName) enhanced.wav")
        recorder = try TapRecorder(raw: ven_live_raw_tap(core), enhanced: ven_live_enhanced_tap(core), rawURL: raw, enhancedURL: enhanced)
        ven_live_set_record_taps(core, 1)
        recorder?.start()
    }

    @discardableResult
    public func stopRecording() -> (raw: URL, enhanced: URL)? {
        guard let recorder else { return nil }
        ven_live_set_record_taps(core, 0)
        recorder.finish()
        self.recorder = nil
        return (recorder.rawURL, recorder.enhancedURL)
    }

    // MARK: Helpers

    static func check(_ status: OSStatus, _ what: String) throws {
        if status != noErr { throw LiveEngineError("\(what) failed", status) }
    }

    static func floatFormat(rate: Double, channels: UInt32) -> AudioStreamBasicDescription {
        AudioStreamBasicDescription(
            mSampleRate: rate, mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked | kAudioFormatFlagIsNonInterleaved,
            mBytesPerPacket: 4, mFramesPerPacket: 1, mBytesPerFrame: 4, mChannelsPerFrame: channels,
            mBitsPerChannel: 32, mReserved: 0)
    }

    static func makeHAL() throws -> AudioUnit {
        var desc = AudioComponentDescription(componentType: kAudioUnitType_Output, componentSubType: kAudioUnitSubType_HALOutput,
                                             componentManufacturer: kAudioUnitManufacturer_Apple, componentFlags: 0, componentFlagsMask: 0)
        guard let component = AudioComponentFindNext(nil, &desc) else { throw LiveEngineError("AUHAL not available") }
        var unit: AudioUnit?
        try check(AudioComponentInstanceNew(component, &unit), "Create audio unit")
        return unit!
    }

    static func makeOutput(device: AudioDeviceID, proc: AURenderCallback, refCon: UnsafeMutableRawPointer) throws -> AudioUnit {
        let unit = try makeHAL()
        var dev = device
        try check(AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &dev,
                                       UInt32(MemoryLayout<AudioDeviceID>.size)), "Select output device")
        var format = floatFormat(rate: Double(VEN_SAMPLE_RATE), channels: 2)
        try check(AudioUnitSetProperty(unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, 0, &format,
                                       UInt32(MemoryLayout<AudioStreamBasicDescription>.size)), "Set output format")
        var callback = AURenderCallbackStruct(inputProc: proc, inputProcRefCon: refCon)
        try check(AudioUnitSetProperty(unit, kAudioUnitProperty_SetRenderCallback, kAudioUnitScope_Input, 0, &callback,
                                       UInt32(MemoryLayout<AURenderCallbackStruct>.size)), "Install output callback")
        try check(AudioUnitInitialize(unit), "Initialize output")
        return unit
    }
}

/// Drains the raw and enhanced tap rings into two WAV files on a background queue.
final class TapRecorder {
    let rawURL: URL
    let enhancedURL: URL
    private let raw: OpaquePointer
    private let enhanced: OpaquePointer
    private let rawFile: AVAudioFile
    private let enhancedFile: AVAudioFile
    private let buffer: AVAudioPCMBuffer
    private let queue = DispatchQueue(label: "ven.recorder")
    private var timer: DispatchSourceTimer?

    init(raw: OpaquePointer, enhanced: OpaquePointer, rawURL: URL, enhancedURL: URL) throws {
        self.raw = raw
        self.enhanced = enhanced
        self.rawURL = rawURL
        self.enhancedURL = enhancedURL
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 48000, AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 24, AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false,
        ]
        rawFile = try AVAudioFile(forWriting: rawURL, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        enhancedFile = try AVAudioFile(forWriting: enhancedURL, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        buffer = AVAudioPCMBuffer(pcmFormat: rawFile.processingFormat, frameCapacity: 48000)!
    }

    func start() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 0.1, repeating: 0.1)
        timer.setEventHandler { [weak self] in self?.drain() }
        timer.resume()
        self.timer = timer
    }

    func finish() {
        timer?.cancel()
        queue.sync { drain() }
    }

    private func drain() {
        for (ring, file) in [(raw, rawFile), (enhanced, enhancedFile)] {
            while ven_ring_available(ring) > 0 {
                let n = ven_ring_read(ring, buffer.floatChannelData![0], Int32(buffer.frameCapacity))
                buffer.frameLength = AVAudioFrameCount(n)
                try? file.write(from: buffer)
            }
        }
    }
}
