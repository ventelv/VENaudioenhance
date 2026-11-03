import AudioToolbox
import AVFoundation
import CoreAudio
import Foundation
import VENDSP

/// Records the first channel of any input device to a WAV file. Used by ven-cli to check
/// what recording apps actually receive from VEN Enhanced Mic.
public final class DeviceRecorder {
    private let unit: AudioUnit
    private let ring: OpaquePointer
    private let abl: UnsafeMutableAudioBufferListPointer
    private let channels: Int
    private let file: AVAudioFile
    private let buffer: AVAudioPCMBuffer
    public let sampleRate: Double

    public init(device: AudioDevice, url: URL) throws {
        unit = try LiveEngine.makeHAL()
        var one: UInt32 = 1, zero: UInt32 = 0
        try LiveEngine.check(AudioUnitSetProperty(unit, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Input, 1, &one, 4), "Enable input")
        try LiveEngine.check(AudioUnitSetProperty(unit, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Output, 0, &zero, 4), "Disable output")
        var dev = device.id
        try LiveEngine.check(AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &dev, 4), "Select device")
        var hw = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        try LiveEngine.check(AudioUnitGetProperty(unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, 1, &hw, &size), "Read format")
        sampleRate = hw.mSampleRate
        channels = Int(hw.mChannelsPerFrame)
        var client = LiveEngine.floatFormat(rate: sampleRate, channels: UInt32(channels))
        try LiveEngine.check(AudioUnitSetProperty(unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output, 1, &client, size), "Set format")

        ring = ven_ring_create(Int32(sampleRate * 4))
        abl = AudioBufferList.allocate(maximumBuffers: channels)
        for i in 0..<channels {
            abl[i] = AudioBuffer(mNumberChannels: 1, mDataByteSize: 0, mData: UnsafeMutableRawPointer.allocate(byteCount: 8192 * 4, alignment: 16))
        }
        let settings: [String: Any] = [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: sampleRate, AVNumberOfChannelsKey: 1,
                                       AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true]
        file = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 16384)!

        var cb = AURenderCallbackStruct(inputProc: { refCon, flags, ts, bus, frames, _ in
            let me = Unmanaged<DeviceRecorder>.fromOpaque(refCon).takeUnretainedValue()
            guard frames <= 8192 else { return noErr }
            for i in 0..<me.channels { me.abl[i].mDataByteSize = frames * 4 }
            let err = AudioUnitRender(me.unit, flags, ts, bus, frames, me.abl.unsafeMutablePointer)
            if err == noErr {
                ven_ring_write(me.ring, me.abl[0].mData!.assumingMemoryBound(to: Float.self), Int32(frames))
            }
            return err
        }, inputProcRefCon: Unmanaged.passUnretained(self).toOpaque())
        try LiveEngine.check(AudioUnitSetProperty(unit, kAudioOutputUnitProperty_SetInputCallback, kAudioUnitScope_Global, 0, &cb,
                                                  UInt32(MemoryLayout<AURenderCallbackStruct>.size)), "Install callback")
        try LiveEngine.check(AudioUnitInitialize(unit), "Initialize")
    }

    deinit {
        AudioOutputUnitStop(unit)
        AudioUnitUninitialize(unit)
        AudioComponentInstanceDispose(unit)
        for b in abl { b.mData?.deallocate() }
        free(abl.unsafeMutablePointer)
        ven_ring_destroy(ring)
    }

    public func start() throws { try LiveEngine.check(AudioOutputUnitStart(unit), "Start") }

    /// Writes whatever has been captured so far.
    public func drain() {
        while ven_ring_available(ring) > 0 {
            let n = ven_ring_read(ring, buffer.floatChannelData![0], Int32(buffer.frameCapacity))
            buffer.frameLength = AVAudioFrameCount(n)
            try? file.write(from: buffer)
        }
    }

    public func stop() {
        AudioOutputUnitStop(unit)
        drain()
    }
}
