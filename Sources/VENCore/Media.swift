import AVFoundation
import Foundation

/// Runs async AVFoundation calls from the (synchronous) mastering pipeline, which always runs off the main thread.
private final class ResultBox<T>: @unchecked Sendable { var result: Result<T, Error>? }

func blocking<T>(_ body: @escaping () async throws -> T) throws -> T {
    let box = ResultBox<T>()
    let done = DispatchSemaphore(value: 0)
    Task.detached {
        do { box.result = .success(try await body()) } catch { box.result = .failure(error) }
        done.signal()
    }
    done.wait()
    return try box.result!.get()
}

// MARK: - Chapters

public struct Chapter: Codable, Hashable {
    public var start: Double
    public var title: String

    public init(start: Double, title: String) {
        self.start = start
        self.title = title
    }
}

public enum Chapters {
    /// "talk.chapters.txt" next to "talk.wav".
    public static func sidecar(for input: URL) -> URL? {
        let url = input.deletingPathExtension().appendingPathExtension("chapters.txt")
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    /// Reads "0:00 Intro" / "01:02:03.5 Title" lines, or an Audacity label track ("12.5<tab>12.5<tab>Title").
    public static func parse(_ text: String) -> [Chapter] {
        var chapters: [Chapter] = []
        for raw in text.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("#") else { continue }
            let tabbed = line.split(separator: "\t", omittingEmptySubsequences: false)
            if tabbed.count >= 2, let start = Double(tabbed[0]) {
                chapters.append(Chapter(start: start, title: String(tabbed.last!).trimmingCharacters(in: .whitespaces)))
                continue
            }
            let parts = line.split(separator: " ", maxSplits: 1)
            guard parts.count == 2, let t = clockSeconds(String(parts[0])) else { continue }
            chapters.append(Chapter(start: t, title: String(parts[1]).trimmingCharacters(in: CharacterSet(charactersIn: " -–—").union(.whitespaces))))
        }
        return chapters.sorted { $0.start < $1.start }
    }

    static func clockSeconds(_ s: String) -> Double? {
        let fields = s.split(separator: ":").map { Double($0) }
        guard (2...3).contains(fields.count), fields.allSatisfy({ $0 != nil }) else { return nil }
        return fields.reduce(0) { $0 * 60 + $1! }
    }

    static func clock(_ t: Double) -> String {
        let ms = Int((t * 1000).rounded())
        return String(format: "%02d:%02d:%02d.%03d", ms / 3_600_000, (ms / 60000) % 60, (ms / 1000) % 60, ms % 1000)
    }

    /// Chapters moved onto the output timeline (after cuts and intro).
    static func remap(_ chapters: [Chapter], _ map: TimeMap) -> [Chapter] {
        var out = chapters.map { Chapter(start: map.mapClamped($0.start), title: $0.title) }
        if !out.isEmpty, map.offset > 0, out[0].start <= map.offset + 0.001, chapters[0].start == 0 { out[0].start = 0 }
        return out
    }

    /// Writes "name.chapters.json" (Podcasting 2.0) and "name.chapters.txt" next to `output`.
    static func writeSidecars(_ chapters: [Chapter], besides output: URL) throws -> [URL] {
        struct JSONChapters: Encodable {
            struct C: Encodable { let startTime: Double; let title: String }
            let version = "1.2.0"
            let chapters: [C]
        }
        let base = output.deletingPathExtension()
        let json = base.appendingPathExtension("chapters.json")
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .withoutEscapingSlashes]
        let data = try encoder.encode(JSONChapters(chapters: chapters.map { .init(startTime: ($0.start * 1000).rounded() / 1000, title: $0.title) }))
        try data.write(to: json)
        let txt = base.appendingPathExtension("chapters.txt")
        try (chapters.map { "\(clock($0.start)) \($0.title)" }.joined(separator: "\n") + "\n").write(to: txt, atomically: true, encoding: .utf8)
        return [json, txt]
    }

    /// Adds a QuickTime chapter track to an .m4a/.mp4/.mov file (shown by Apple Podcasts, QuickTime, VLC...).
    static func embed(_ chapters: [Chapter], in file: URL) throws {
        guard !chapters.isEmpty else { return }
        let asset = AVURLAsset(url: file)
        let tracks = try blocking { try await asset.load(.tracks) }
        let duration = try blocking { try await asset.load(.duration) }
        let type: AVFileType = file.pathExtension.lowercased() == "mov" ? .mov : (file.pathExtension.lowercased() == "m4a" ? .m4a : .mp4)
        let temp = file.deletingLastPathComponent().appendingPathComponent(".ven-\(UUID().uuidString).\(file.pathExtension)")
        defer { try? FileManager.default.removeItem(at: temp) }

        let reader = try AVAssetReader(asset: asset)
        let writer = try AVAssetWriter(outputURL: temp, fileType: type)
        var pairs: [(AVAssetReaderTrackOutput, AVAssetWriterInput)] = []
        for track in tracks where track.mediaType == .audio || track.mediaType == .video {
            let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
            reader.add(output)
            let hint = try blocking { try await track.load(.formatDescriptions) }.first
            let input = AVAssetWriterInput(mediaType: track.mediaType, outputSettings: nil, sourceFormatHint: hint)
            input.expectsMediaDataInRealTime = false
            if track.mediaType == .video { input.transform = try blocking { try await track.load(.preferredTransform) } }
            writer.add(input)
            pairs.append((output, input))
        }

        // A QuickTime 'text' sample description (60 bytes, big-endian), as chapter tracks in .m4b audiobooks use.
        var description: [UInt8] = [0, 0, 0, 60, 0x74, 0x65, 0x78, 0x74]   // size, 'text'
        description += [0, 0, 0, 0, 0, 0, 0, 1]                              // reserved, data reference index 1
        description += [0, 0, 0, 1, 0, 0, 0, 1]                              // display flags, justification
        description += [UInt8](repeating: 0, count: 6 + 8 + 8)                // background colour, text box, reserved
        description += [0, 1, 0, 0, 0, 0, 0]                                 // font number 1, face, reserved
        description += [UInt8](repeating: 0, count: 6) + [0]                  // foreground colour, empty name
        var textFormat: CMFormatDescription?
        CMTextFormatDescriptionCreateFromBigEndianTextDescriptionData(allocator: kCFAllocatorDefault, bigEndianTextDescriptionData: description,
                                                                      size: description.count, flavor: nil, mediaType: kCMMediaType_Text,
                                                                      formatDescriptionOut: &textFormat)
        guard let textFormat else { throw AudioIOError(message: "Can't create chapter track") }
        let chapterInput = AVAssetWriterInput(mediaType: .text, outputSettings: nil, sourceFormatHint: textFormat)
        chapterInput.expectsMediaDataInRealTime = false
        guard writer.canAdd(chapterInput) else { throw AudioIOError(message: "This file type can't hold chapters") }
        writer.add(chapterInput)
        for (_, input) in pairs where input.mediaType == .audio || input.mediaType == .video {
            input.addTrackAssociation(withTrackOf: chapterInput, type: AVAssetTrack.AssociationType.chapterList.rawValue)
        }

        guard reader.startReading(), writer.startWriting() else {
            throw AudioIOError(message: "Can't add chapters: \(writer.error?.localizedDescription ?? reader.error?.localizedDescription ?? "unknown error")")
        }
        writer.startSession(atSourceTime: .zero)

        // Chapter samples: big-endian length + UTF-8 text, each lasting until the next chapter.
        let end = duration.seconds
        var samples: [CMSampleBuffer] = []
        for (i, c) in chapters.enumerated() {
            let start = min(max(0, c.start), end)
            let stop = i + 1 < chapters.count ? min(chapters[i + 1].start, end) : end
            guard stop > start else { continue }
            let utf8 = Array(c.title.utf8)
            var bytes = [UInt8(utf8.count >> 8), UInt8(utf8.count & 0xff)] + utf8
            // 'encd' atom: the text is UTF-8.
            bytes += [0, 0, 0, 12, 0x65, 0x6e, 0x63, 0x64, 0, 0, 1, 0]
            var block: CMBlockBuffer?
            CMBlockBufferCreateWithMemoryBlock(allocator: kCFAllocatorDefault, memoryBlock: nil, blockLength: bytes.count,
                                               blockAllocator: kCFAllocatorDefault, customBlockSource: nil, offsetToData: 0,
                                               dataLength: bytes.count, flags: 0, blockBufferOut: &block)
            guard let block else { continue }
            CMBlockBufferReplaceDataBytes(with: bytes, blockBuffer: block, offsetIntoDestination: 0, dataLength: bytes.count)
            var timing = CMSampleTimingInfo(duration: CMTime(seconds: stop - start, preferredTimescale: 1000),
                                            presentationTimeStamp: CMTime(seconds: start, preferredTimescale: 1000), decodeTimeStamp: .invalid)
            var size = bytes.count
            var sample: CMSampleBuffer?
            CMSampleBufferCreate(allocator: kCFAllocatorDefault, dataBuffer: block, dataReady: true, makeDataReadyCallback: nil,
                                 refcon: nil, formatDescription: textFormat, sampleCount: 1, sampleTimingEntryCount: 1,
                                 sampleTimingArray: &timing, sampleSizeEntryCount: 1, sampleSizeArray: &size, sampleBufferOut: &sample)
            if let sample { samples.append(sample) }
        }

        // The writer interleaves its tracks, so each input is fed on its own queue as it asks for data.
        let group = DispatchGroup()
        let queue = DispatchQueue(label: "ven.chapters", attributes: .concurrent)
        group.enter()
        var nextChapter = 0
        chapterInput.requestMediaDataWhenReady(on: DispatchQueue(label: "ven.chapters.text")) {
            while chapterInput.isReadyForMoreMediaData {
                guard nextChapter < samples.count else {
                    chapterInput.markAsFinished()
                    group.leave()
                    return
                }
                chapterInput.append(samples[nextChapter])
                nextChapter += 1
            }
        }
        for (output, input) in pairs {
            group.enter()
            input.requestMediaDataWhenReady(on: DispatchQueue(label: "ven.chapters.media", target: queue)) {
                while input.isReadyForMoreMediaData {
                    guard let sample = output.copyNextSampleBuffer(), input.append(sample) else {
                        input.markAsFinished()
                        group.leave()
                        return
                    }
                }
            }
        }
        group.wait()
        let finished = DispatchSemaphore(value: 0)
        writer.finishWriting { finished.signal() }
        finished.wait()
        guard writer.status == .completed else {
            throw AudioIOError(message: "Can't add chapters: \(writer.error.map { "\($0)" } ?? "unknown error")")
        }
        _ = try FileManager.default.replaceItemAt(file, withItemAt: temp)
    }
}

// MARK: - Video

public enum VideoRemux {
    public static let extensions = ["mp4", "mov", "m4v"]

    public static func hasVideo(_ url: URL) -> Bool {
        guard extensions.contains(url.pathExtension.lowercased()) else { return false }
        let tracks = (try? blocking { try await AVURLAsset(url: url).loadTracks(withMediaType: .video) }) ?? []
        return !tracks.isEmpty
    }

    public static func outputURL(for input: URL, besides audioOutput: URL) -> URL {
        let ext = input.pathExtension.lowercased() == "mov" ? "mov" : "mp4"
        return audioOutput.deletingPathExtension().appendingPathExtension(ext)
    }

    /// Writes `output`: the video of `video` with `audio` as its soundtrack and the cuts in `map` removed from the
    /// picture too. The video itself is copied, not re-encoded.
    static func remux(video: URL, audio: URL, map: TimeMap, output: URL) throws {
        // Tracks only keep a weak reference to their asset, so both assets are held here.
        let source = AVURLAsset(url: video), soundtrack = AVURLAsset(url: audio)
        guard let videoTrack = try blocking({ try await source.loadTracks(withMediaType: .video) }).first,
              let audioTrack = try blocking({ try await soundtrack.loadTracks(withMediaType: .audio) }).first
        else { throw AudioIOError(message: "No video track in \(video.lastPathComponent)") }
        let videoRange = try blocking { try await videoTrack.load(.timeRange) }
        let audioRange = try blocking { try await audioTrack.load(.timeRange) }

        let composition = AVMutableComposition()
        guard let v = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) else {
            throw AudioIOError(message: "Can't build the video")
        }
        try v.insertTimeRange(videoRange, of: videoTrack, at: .zero)
        v.preferredTransform = try blocking { try await videoTrack.load(.preferredTransform) }
        // Each joint in the audio is crossfaded, which shortens it by the fade as well.
        for r in map.ranges.reversed() {
            let start = CMTime(seconds: r.lowerBound, preferredTimescale: 600)
            let end = CMTime(seconds: r.upperBound + TimeMap.fade, preferredTimescale: 600)
            composition.removeTimeRange(CMTimeRange(start: start, end: end))
        }
        guard let a = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) else {
            throw AudioIOError(message: "Can't build the video")
        }
        try a.insertTimeRange(audioRange, of: audioTrack, at: .zero)

        try? FileManager.default.removeItem(at: output)
        guard let export = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetPassthrough) else {
            throw AudioIOError(message: "Can't export the video")
        }
        export.outputURL = output
        export.outputFileType = output.pathExtension == "mov" ? .mov : .mp4
        let done = DispatchSemaphore(value: 0)
        export.exportAsynchronously { done.signal() }
        done.wait()
        guard export.status == .completed else {
            let reason = (export.error as NSError?).map { ($0.userInfo[NSUnderlyingErrorKey] as? NSError)?.description ?? $0.localizedDescription }
            throw AudioIOError(message: "Video export failed: \(reason ?? "unknown error")")
        }
    }
}
