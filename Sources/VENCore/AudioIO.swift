import AVFoundation
import Foundation

public struct AudioIOError: LocalizedError {
    public let message: String
    public var errorDescription: String? { message }
}

public enum ExportFormat: String, Codable, CaseIterable, Identifiable {
    case wav24, wav16, aiff24, flac, alac, aac256, aac128, mp3
    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .wav24: return "WAV 24-bit"
        case .wav16: return "WAV 16-bit"
        case .aiff24: return "AIFF 24-bit"
        case .flac: return "FLAC (lossless)"
        case .alac: return "Apple Lossless (M4A)"
        case .aac256: return "AAC 256 kbps (M4A)"
        case .aac128: return "AAC 128 kbps (M4A)"
        case .mp3: return "MP3 192 kbps"
        }
    }

    public var fileExtension: String {
        switch self {
        case .wav24, .wav16: return "wav"
        case .aiff24: return "aiff"
        case .flac: return "flac"
        case .alac, .aac256, .aac128: return "m4a"
        case .mp3: return "mp3"
        }
    }

    /// MP3 encoding uses the `lame` command from Homebrew.
    public static var lamePath: String? {
        ["/opt/homebrew/bin/lame", "/usr/local/bin/lame"].first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    public var isAvailable: Bool { self != .mp3 || Self.lamePath != nil }
}

public enum AudioIO {
    public static let readableExtensions = ["wav", "aif", "aiff", "caf", "m4a", "mp3", "flac", "aac", "mp4", "mov", "m4v"]

    /// Decodes a file to planar float at `rate` Hz, keeping up to two channels (more are folded to stereo).
    public static func read(_ url: URL, rate: Double = 48000) throws -> PlanarBuffer {
        let file: AVAudioFile
        do {
            file = try AVAudioFile(forReading: url)
        } catch {
            throw AudioIOError(message: "Can't open \(url.lastPathComponent): \(error.localizedDescription)")
        }
        let inFormat = file.processingFormat
        let inChannels = Int(inFormat.channelCount)
        let outChannels = min(inChannels, 2)
        let total = Int(file.length)
        guard total > 0 else { throw AudioIOError(message: "\(url.lastPathComponent) has no audio") }

        // Read everything at the source rate, folding extra channels down.
        let source = PlanarBuffer(channels: outChannels, frames: total)
        let chunk = AVAudioPCMBuffer(pcmFormat: inFormat, frameCapacity: 65536)!
        var pos = 0
        while pos < total {
            try file.read(into: chunk)
            let n = Int(chunk.frameLength)
            if n == 0 { break }
            let data = chunk.floatChannelData!
            for c in 0..<inChannels {
                let dst = source.channel(c % outChannels) + pos
                if c < outChannels {
                    dst.update(from: data[c], count: n)
                } else {
                    for i in 0..<n { dst[i] += data[c][i] }
                }
            }
            pos += n
        }
        if inChannels > 2 {
            let scale = Float(outChannels) / Float(inChannels)
            for c in 0..<outChannels { for i in 0..<total { source.channel(c)[i] *= scale } }
        }
        if inFormat.sampleRate == rate { return source }
        return try resample(source, from: inFormat.sampleRate, to: rate)
    }

    public static func resample(_ input: PlanarBuffer, from: Double, to: Double) throws -> PlanarBuffer {
        guard let inFmt = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: from, channels: AVAudioChannelCount(input.channels), interleaved: false),
              let outFmt = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: to, channels: AVAudioChannelCount(input.channels), interleaved: false),
              let converter = AVAudioConverter(from: inFmt, to: outFmt)
        else { throw AudioIOError(message: "Can't convert \(from) Hz to \(to) Hz") }
        converter.sampleRateConverterQuality = AVAudioQuality.max.rawValue
        converter.sampleRateConverterAlgorithm = AVSampleRateConverterAlgorithm_Mastering

        let expected = Int((Double(input.frames) * to / from).rounded(.up)) + 1024
        let output = PlanarBuffer(channels: input.channels, frames: expected)
        let inChunk = AVAudioPCMBuffer(pcmFormat: inFmt, frameCapacity: 32768)!
        let outChunk = AVAudioPCMBuffer(pcmFormat: outFmt, frameCapacity: 32768)!
        var readPos = 0, writePos = 0
        var finished = false
        while !finished {
            outChunk.frameLength = 0
            var error: NSError?
            let status = converter.convert(to: outChunk, error: &error) { _, outStatus in
                if readPos >= input.frames {
                    outStatus.pointee = .endOfStream
                    return nil
                }
                let n = min(Int(inChunk.frameCapacity), input.frames - readPos)
                for c in 0..<input.channels { inChunk.floatChannelData![c].update(from: input.channel(c) + readPos, count: n) }
                inChunk.frameLength = AVAudioFrameCount(n)
                readPos += n
                outStatus.pointee = .haveData
                return inChunk
            }
            if let error { throw error }
            let n = min(Int(outChunk.frameLength), expected - writePos)
            for c in 0..<input.channels { (output.channel(c) + writePos).update(from: outChunk.floatChannelData![c], count: n) }
            writePos += n
            finished = status == .endOfStream || status == .error || (n == 0 && readPos >= input.frames)
        }
        let exact = Int((Double(input.frames) * to / from).rounded())
        return output.slice(0, min(exact, writePos))
    }

    public static func write(_ buffer: PlanarBuffer, rate: Double = 48000, to url: URL, format: ExportFormat) throws {
        try? FileManager.default.removeItem(at: url)
        if format == .mp3 { return try writeMP3(buffer, rate: rate, to: url) }

        var settings: [String: Any] = [AVSampleRateKey: rate, AVNumberOfChannelsKey: buffer.channels]
        switch format {
        case .wav24, .wav16, .aiff24:
            settings[AVFormatIDKey] = kAudioFormatLinearPCM
            settings[AVLinearPCMBitDepthKey] = format == .wav16 ? 16 : 24
            settings[AVLinearPCMIsFloatKey] = false
            settings[AVLinearPCMIsBigEndianKey] = format == .aiff24
        case .flac:
            settings[AVFormatIDKey] = kAudioFormatFLAC
            settings[AVLinearPCMBitDepthKey] = 24
        case .alac:
            settings[AVFormatIDKey] = kAudioFormatAppleLossless
            settings[AVEncoderBitDepthHintKey] = 24
        case .aac256, .aac128:
            settings[AVFormatIDKey] = kAudioFormatMPEG4AAC
            settings[AVEncoderBitRateKey] = (format == .aac256 ? 256_000 : 128_000) / (buffer.channels == 1 ? 2 : 1)
        case .mp3:
            break
        }
        let file: AVAudioFile
        do {
            file = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        } catch {
            throw AudioIOError(message: "Can't create \(format.label) file: \(error.localizedDescription)")
        }
        let chunk = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 65536)!
        var pos = 0
        while pos < buffer.frames {
            let n = min(Int(chunk.frameCapacity), buffer.frames - pos)
            for c in 0..<buffer.channels { chunk.floatChannelData![c].update(from: buffer.channel(c) + pos, count: n) }
            chunk.frameLength = AVAudioFrameCount(n)
            try file.write(from: chunk)
            pos += n
        }
    }

    static func writeMP3(_ buffer: PlanarBuffer, rate: Double, to url: URL) throws {
        guard let lame = ExportFormat.lamePath else {
            throw AudioIOError(message: "MP3 export needs LAME. Install it with: brew install lame")
        }
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".wav")
        defer { try? FileManager.default.removeItem(at: temp) }
        try write(buffer, rate: rate, to: temp, format: .wav24)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: lame)
        process.arguments = ["--quiet", "-b", "192", "-q", "2", temp.path, url.path]
        try process.run()
        process.waitUntilExit()
        if process.terminationStatus != 0 { throw AudioIOError(message: "lame failed with status \(process.terminationStatus)") }
    }
}
