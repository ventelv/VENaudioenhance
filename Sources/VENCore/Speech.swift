import Combine
import Foundation

/// A whisper.cpp model that VEN knows how to download and how to get word timings from.
public struct WhisperModel: Identifiable, Hashable {
    public let id: String          // ggml-<id>.bin on Hugging Face
    public let name: String
    public let sizeMB: Int
    public let dtwPreset: String   // whisper.cpp alignment-heads preset for accurate word timing
    public let englishOnly: Bool

    public var fileName: String { "ggml-\(id).bin" }
    public var downloadURL: URL { URL(string: "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/\(fileName)")! }

    public static let catalog: [WhisperModel] = [
        WhisperModel(id: "large-v3-turbo-q5_0", name: "Large v3 Turbo (compact)", sizeMB: 547, dtwPreset: "large.v3.turbo", englishOnly: false),
        WhisperModel(id: "large-v3-turbo", name: "Large v3 Turbo", sizeMB: 1624, dtwPreset: "large.v3.turbo", englishOnly: false),
        WhisperModel(id: "small.en", name: "Small (English)", sizeMB: 466, dtwPreset: "small.en", englishOnly: true),
        WhisperModel(id: "base.en", name: "Base (English, fastest)", sizeMB: 142, dtwPreset: "base.en", englishOnly: true),
    ]

    /// Guesses the alignment preset from a model file name, for model files VEN didn't download.
    static func dtwPreset(forFile name: String) -> String? {
        let base = name.lowercased().replacingOccurrences(of: "ggml-", with: "").replacingOccurrences(of: ".bin", with: "")
        if let known = catalog.first(where: { $0.id == base }) { return known.dtwPreset }
        let presets = ["large.v3.turbo", "large.v3", "large.v2", "large.v1", "medium.en", "medium", "small.en", "small",
                       "base.en", "base", "tiny.en", "tiny"]
        let dotted = base.replacingOccurrences(of: "-", with: ".")
        return presets.first { dotted.hasPrefix($0) }
    }
}

/// Finds whisper.cpp and installed models, and downloads new ones.
@MainActor
public final class SpeechModels: ObservableObject {
    public struct Installed: Identifiable, Hashable {
        public var id: String { url.path }
        public let url: URL
        public let name: String
        public let sizeMB: Int
    }

    @Published public private(set) var installed: [Installed] = []
    @Published public private(set) var downloading: [String: Double] = [:]   // model id → fraction
    @Published public var downloadError: String?
    /// The most recent finished download, so the UI can switch to it.
    @Published public private(set) var lastDownloaded: URL?

    private var tasks: [String: URLSessionDownloadTask] = [:]
    private var observations: [String: NSKeyValueObservation] = [:]

    public init() {
        refresh()
    }

    public func refresh() {
        installed = Speech.findModels().map {
            let size = (try? $0.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            return Installed(url: $0, name: $0.lastPathComponent, sizeMB: size / 1_000_000)
        }
    }

    public func download(_ model: WhisperModel) {
        guard tasks[model.id] == nil else { return }
        downloadError = nil
        let dest = Speech.modelsFolder.appendingPathComponent(model.fileName)
        let task = URLSession.shared.downloadTask(with: model.downloadURL) { [weak self] temp, response, error in
            var failure = error?.localizedDescription
            if failure == nil, let http = response as? HTTPURLResponse, http.statusCode != 200 { failure = "Server returned \(http.statusCode)" }
            if failure == nil, let temp {
                do {
                    try FileManager.default.createDirectory(at: Speech.modelsFolder, withIntermediateDirectories: true)
                    try? FileManager.default.removeItem(at: dest)
                    try FileManager.default.moveItem(at: temp, to: dest)
                } catch {
                    failure = error.localizedDescription
                }
            }
            let error = failure
            Task { @MainActor [weak self] in
                guard let self else { return }
                let failure = error
                self.tasks[model.id] = nil
                self.observations[model.id] = nil
                self.downloading[model.id] = nil
                if let failure, failure != "cancelled" { self.downloadError = "\(model.name): \(failure)" }
                self.refresh()
                if failure == nil { self.lastDownloaded = dest }
            }
        }
        observations[model.id] = task.progress.observe(\.fractionCompleted) { [weak self] progress, _ in
            let fraction = progress.fractionCompleted
            Task { @MainActor [weak self] in self?.downloading[model.id] = fraction }
        }
        tasks[model.id] = task
        downloading[model.id] = 0
        task.resume()
    }

    public func cancelDownload(_ model: WhisperModel) {
        tasks[model.id]?.cancel()
    }
}

public enum Speech {
    public static var modelsFolder: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("VEN Audio Enhance/Models")
    }

    /// Model folders searched besides VEN's own: other whisper.cpp apps on this Mac.
    static var otherModelFolders: [URL] {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return [support.appendingPathComponent("VENWhispr"), URL(fileURLWithPath: "/opt/homebrew/share/whisper.cpp/models")]
    }

    public static func findModels() -> [URL] {
        var found: [URL] = []
        for folder in [modelsFolder] + otherModelFolders {
            let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.fileSizeKey])) ?? []
            for f in files.sorted(by: { $0.lastPathComponent < $1.lastPathComponent })
            where f.lastPathComponent.hasPrefix("ggml-") && f.pathExtension == "bin" && !f.lastPathComponent.contains("for-tests") {
                let size = (try? f.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
                if size > 30_000_000 { found.append(f) }   // skip partial downloads and test stubs
            }
        }
        return found
    }

    /// The best installed model: the most accurate one we know of, else whatever is there.
    public static func defaultModel() -> URL? {
        let models = findModels()
        for id in ["large-v3-turbo", "large-v3-turbo-q5_0", "small.en", "base.en"] {
            if let m = models.first(where: { $0.lastPathComponent == "ggml-\(id).bin" }) { return m }
        }
        return models.first
    }

    public static var whisperPath: String? {
        ["/opt/homebrew/bin/whisper-cli", "/usr/local/bin/whisper-cli"].first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// A prompt in the style of a verbatim transcript. Without it whisper tends to tidy fillers away.
    static let fillerPrompt = "Umm, let me think like, hmm... Okay, here's what I'm, like, thinking. Uh, so, er, yeah."

    /// Transcribes `audio` (48 kHz) with word timings. `language` is a whisper code such as "en", or "auto".
    public static func transcribe(_ audio: PlanarBuffer, model: URL, language: String = "auto",
                                  progress: (Double) -> Void = { _ in }) throws -> Transcript {
        guard let whisper = whisperPath else {
            throw AudioIOError(message: "Transcripts and filler cutting need whisper.cpp. Install it with: brew install whisper-cpp")
        }
        guard FileManager.default.fileExists(atPath: model.path) else {
            throw AudioIOError(message: "Speech model not found at \(model.path)")
        }
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent("ven-whisper-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temp) }

        let wav = temp.appendingPathComponent("speech.wav")
        let mono16k = try AudioIO.resample(Mastering.mixToMono(audio), from: Mastering.rate, to: 16000)
        try AudioIO.write(mono16k, rate: 16000, to: wav, format: .wav16)

        let base = temp.appendingPathComponent("out")
        var args = ["-m", model.path, "-f", wav.path, "-of", base.path, "-ojf", "-ml", "1", "-sow", "-pp",
                    "-l", language, "-t", "\(max(4, ProcessInfo.processInfo.activeProcessorCount))", "--prompt", fillerPrompt]
        // DTW word timing (needs flash attention off) is far more precise than whisper's own timestamps.
        if let preset = WhisperModel.dtwPreset(forFile: model.lastPathComponent) { args += ["-nfa", "--dtw", preset] }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: whisper)
        process.arguments = args
        process.standardOutput = FileHandle.nullDevice
        let errPipe = Pipe()
        process.standardError = errPipe
        let log = LockedLog()
        errPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            log.append(String(decoding: data, as: UTF8.self))
        }
        try process.run()
        var lastProgress = -1
        while process.isRunning {
            Thread.sleep(forTimeInterval: 0.2)
            if let p = log.lastProgress(), p != lastProgress {
                lastProgress = p
                progress(Double(p) / 100)
            }
        }
        errPipe.fileHandleForReading.readabilityHandler = nil
        guard process.terminationStatus == 0 else {
            let tail = log.text.split(separator: "\n").suffix(3).joined(separator: " ")
            throw AudioIOError(message: "whisper-cli failed (\(process.terminationStatus)): \(tail)")
        }
        let data = try Data(contentsOf: base.appendingPathExtension("json"))
        return try Transcript(whisperJSON: data)
    }
}

/// Collects whisper's stderr from the pipe's background queue.
private final class LockedLog: @unchecked Sendable {
    private let lock = NSLock()
    private var buffer = ""

    func append(_ s: String) {
        lock.lock()
        buffer += s
        if buffer.count > 20000 { buffer = String(buffer.suffix(10000)) }
        lock.unlock()
    }

    var text: String {
        lock.lock()
        defer { lock.unlock() }
        return buffer
    }

    /// The last "progress = NN%" whisper printed.
    func lastProgress() -> Int? {
        guard let r = text.range(of: "progress = ", options: .backwards) else { return nil }
        return Int(text[r.upperBound...].prefix { $0.isNumber })
    }
}
