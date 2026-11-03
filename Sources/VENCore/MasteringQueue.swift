import Combine
import Foundation

/// Files waiting for, or done with, the mastering pass, plus an optional watch folder.
@MainActor
public final class MasteringQueue: ObservableObject {
    public struct Job: Identifiable {
        public enum State: Equatable {
            case queued
            case running(Double, String)
            case needsReview(Int)   // number of suggested cuts
            case done(String)       // one-line summary
            case failed(String)
        }
        public let id = UUID()
        public let input: URL
        public var output: URL?
        public var state: State = .queued
    }

    @Published public private(set) var jobs: [Job] = []
    @Published public var settings: MasteringSettings { didSet { save() } }
    @Published public var outputFolder: URL? { didSet { save() } }   // nil = next to the original
    @Published public var watchFolder: URL? { didSet { save(); restartWatching() } }

    /// Processed files waiting for their cuts to be reviewed.
    public private(set) var analyses: [UUID: MasteringAnalysis] = [:]

    private var running = false
    private var watchTimer: Timer?
    private var seenSizes: [URL: Int] = [:]
    private var handled: Set<String>
    private let defaults = UserDefaults.standard

    public init() {
        if let data = defaults.data(forKey: "master.settings"), let s = MasteringSettings.decode(data) {
            settings = s
        } else {
            settings = MasteringSettings()
        }
        outputFolder = defaults.url(forKey: "master.output")
        watchFolder = defaults.url(forKey: "master.watch")
        handled = Set(defaults.stringArray(forKey: "master.handled") ?? [])
        restartWatching()
    }

    public func add(_ urls: [URL]) {
        for url in urls where AudioIO.readableExtensions.contains(url.pathExtension.lowercased()) {
            guard !jobs.contains(where: { $0.input == url && $0.state == .queued }) else { continue }
            jobs.append(Job(input: url))
        }
        runNext()
    }

    public func clearFinished() {
        jobs.removeAll {
            if case .done = $0.state { return true }
            if case .failed = $0.state { return true }
            return false
        }
    }

    private func runNext() {
        guard !running, let index = jobs.firstIndex(where: { $0.state == .queued }) else { return }
        running = true
        let job = jobs[index]
        let settings = settings
        let output = Mastering.outputURL(for: job.input, in: outputFolder, format: settings.format)
        jobs[index].output = output
        jobs[index].state = .running(0, "Starting")
        let id = job.id

        Task.detached(priority: .userInitiated) {
            let report = Self.throttled { fraction, stage in Task { @MainActor in self.update(id, .running(fraction, stage)) } }
            let result: Result<MasteringAnalysis, Error> = Result {
                try Mastering.analyze(input: job.input, settings: settings, progress: report)
            }
            await MainActor.run {
                switch result {
                case .success(let analysis) where settings.reviewCuts && !analysis.cuts.isEmpty:
                    self.analyses[id] = analysis
                    self.update(id, .needsReview(analysis.cuts.count))
                case .success(let analysis):
                    self.export(id, analysis)
                case .failure(let e):
                    self.update(id, .failed(e.localizedDescription))
                }
                self.running = false
                self.runNext()
            }
        }
    }

    /// Exports a reviewed job with the cuts as the user left them.
    public func finishReview(_ id: UUID, cuts: [EditCut]) {
        guard let analysis = analyses.removeValue(forKey: id) else { return }
        analysis.cuts = cuts
        export(id, analysis)
    }

    public func discardReview(_ id: UUID) {
        analyses[id] = nil
        update(id, .failed("Not exported"))
    }

    private func export(_ id: UUID, _ analysis: MasteringAnalysis) {
        guard let output = jobs.first(where: { $0.id == id })?.output else { return }
        update(id, .running(0.95, "Exporting"))
        Task.detached(priority: .userInitiated) {
            let report = Self.throttled { fraction, stage in Task { @MainActor in self.update(id, .running(fraction, stage)) } }
            let result = Result { try Mastering.finish(analysis, output: output, progress: report) }
            await MainActor.run {
                switch result {
                case .success(let r): self.update(id, .done(Self.summary(r)))
                case .failure(let e): self.update(id, .failed(e.localizedDescription))
                }
            }
        }
    }

    /// Passes progress on at most 10 times a second.
    nonisolated static func throttled(_ body: @escaping (Double, String) -> Void) -> (Double, String) -> Void {
        var last = Date.distantPast
        return { fraction, stage in
            guard Date().timeIntervalSince(last) > 0.1 || fraction >= 1 else { return }
            last = Date()
            body(fraction, stage)
        }
    }

    public nonisolated static func summary(_ r: MasteringReport) -> String {
        var parts = [String(format: "%.1f → %.1f LUFS, peak %.1f dBTP", r.input.integrated_lufs, r.output.integrated_lufs, r.output.true_peak_dbtp)]
        if r.humHz > 0 { parts.append("\(r.humHz) Hz hum removed") }
        let cuts = EditCut.Kind.allCases.compactMap { k -> String? in
            guard let n = r.cutCounts[k], n > 0 else { return nil }
            return "\(n) \(k.label.lowercased())\(n == 1 ? "" : "s")"
        }
        if !cuts.isEmpty { parts.append(String(format: "cut %@ (%.1f s)", cuts.joined(separator: ", "), r.secondsCut)) }
        if !r.transcriptFiles.isEmpty { parts.append("transcript " + r.transcriptFiles.map { $0.pathExtension.uppercased() }.joined(separator: "/")) }
        return parts.joined(separator: ", ")
    }

    private func update(_ id: UUID, _ state: Job.State) {
        guard let i = jobs.firstIndex(where: { $0.id == id }) else { return }
        jobs[i].state = state
    }

    // MARK: Watch folder

    private func restartWatching() {
        watchTimer?.invalidate()
        watchTimer = nil
        seenSizes = [:]
        guard watchFolder != nil else { return }
        watchTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in self.scanWatchFolder() }
        }
        // Files already there when watching starts are left alone.
        scanWatchFolder(markExisting: true)
    }

    private func scanWatchFolder(markExisting: Bool = false) {
        guard let folder = watchFolder else { return }
        let keys: [URLResourceKey] = [.fileSizeKey, .contentModificationDateKey]
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: keys)) ?? []
        for url in files where AudioIO.readableExtensions.contains(url.pathExtension.lowercased()) {
            let name = url.lastPathComponent
            // Skip our own output and anything already handled.
            if name.contains("(VEN)") || handled.contains(url.path) { continue }
            if markExisting {
                handled.insert(url.path)
                continue
            }
            let values = try? url.resourceValues(forKeys: Set(keys))
            let size = values?.fileSize ?? 0
            // Wait until the recording app has stopped writing: same size on two scans.
            if size > 0, seenSizes[url] == size {
                handled.insert(url.path)
                seenSizes[url] = nil
                add([url])
            } else {
                seenSizes[url] = size
            }
        }
        save()
    }

    private func save() {
        if let data = try? JSONEncoder().encode(settings) { defaults.set(data, forKey: "master.settings") }
        defaults.set(outputFolder, forKey: "master.output")
        defaults.set(watchFolder, forKey: "master.watch")
        defaults.set(Array(handled.suffix(2000)), forKey: "master.handled")
    }
}
