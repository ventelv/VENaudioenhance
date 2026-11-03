import AVFoundation
import AppKit
import SwiftUI
import VENCore

enum SpeechLanguage {
    static let all: [(code: String, name: String)] = [
        ("auto", "Detect automatically"), ("en", "English"), ("es", "Spanish"), ("fr", "French"), ("de", "German"),
        ("it", "Italian"), ("pt", "Portuguese"), ("nl", "Dutch"), ("af", "Afrikaans"), ("ja", "Japanese"), ("zh", "Chinese"),
    ]
}

/// One line under the transcript settings saying whether transcription can run.
struct SpeechStatus: View {
    @EnvironmentObject var queue: MasteringQueue
    @EnvironmentObject var speech: SpeechModels

    var body: some View {
        if Speech.whisperPath == nil {
            Label("Needs whisper.cpp. In Terminal: brew install whisper-cpp", systemImage: "exclamationmark.triangle")
                .font(.caption).foregroundStyle(.orange)
        } else if speech.installed.isEmpty {
            Label("Needs a speech model: download one in Setup", systemImage: "exclamationmark.triangle")
                .font(.caption).foregroundStyle(.orange)
        } else {
            let path = queue.settings.speechModelPath ?? Speech.defaultModel()?.path ?? ""
            Text("Filler cutting and transcripts use \(URL(fileURLWithPath: path).lastPathComponent) (change in Setup)")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}

/// Setup tab: whisper.cpp status, the model in use, and downloads.
struct SpeechModelsSection: View {
    @EnvironmentObject var queue: MasteringQueue
    @EnvironmentObject var speech: SpeechModels

    var body: some View {
        Section("Speech recognition (transcripts and filler cutting)") {
            LabeledContent("whisper.cpp") {
                if Speech.whisperPath != nil {
                    Label("Installed", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                } else {
                    Text("Not installed. In Terminal: brew install whisper-cpp").foregroundStyle(.orange)
                }
            }
            if !speech.installed.isEmpty {
                Picker("Model", selection: $queue.settings.speechModelPath) {
                    Text("Best installed (\(Speech.defaultModel()?.lastPathComponent ?? "none"))").tag(String?.none)
                    ForEach(speech.installed) { m in Text("\(m.name) · \(m.sizeMB) MB").tag(String?.some(m.url.path)) }
                }
            }
            ForEach(WhisperModel.catalog) { model in
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(model.name)
                        Text("\(model.sizeMB) MB · \(model.englishOnly ? "English only" : "99 languages")")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if speech.installed.contains(where: { $0.name == model.fileName }) {
                        Label("Installed", systemImage: "checkmark").foregroundStyle(.secondary)
                    } else if let fraction = speech.downloading[model.id] {
                        ProgressView(value: fraction).frame(width: 100)
                        Button { speech.cancelDownload(model) } label: { Image(systemName: "xmark.circle.fill") }
                            .buttonStyle(.borderless)
                    } else {
                        Button("Download") { speech.download(model) }
                    }
                }
            }
            if let error = speech.downloadError { Text(error).font(.caption).foregroundStyle(.red) }
            HStack {
                Text("Models come from huggingface.co/ggerganov/whisper.cpp and run entirely on this Mac.")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Show folder") {
                    try? FileManager.default.createDirectory(at: Speech.modelsFolder, withIntermediateDirectories: true)
                    NSWorkspace.shared.open(Speech.modelsFolder)
                }
            }
        }
        .onChange(of: speech.lastDownloaded) { url in
            if let url { queue.settings.speechModelPath = url.path }
        }
        .onAppear { speech.refresh() }
    }
}

// MARK: - Cut review

/// Plays short previews of the programme, with or without a cut.
@MainActor
final class PreviewPlayer: ObservableObject {
    @Published private(set) var playing: String?
    private let engine = AVAudioEngine()
    private let node = AVAudioPlayerNode()
    private let format = AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 1)!

    init() {
        engine.attach(node)
        engine.connect(node, to: engine.mainMixerNode, format: format)
    }

    func play(_ samples: [Float], key: String) {
        node.stop()
        guard !samples.isEmpty, let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)) else { return }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { buffer.floatChannelData![0].update(from: $0.baseAddress!, count: samples.count) }
        if !engine.isRunning { try? engine.start() }
        playing = key
        node.scheduleBuffer(buffer, at: nil, options: .interrupts) { [weak self] in
            Task { @MainActor in if self?.playing == key { self?.playing = nil } }
        }
        node.play()
    }

    func stop() {
        node.stop()
        playing = nil
    }
}

extension EditCut.Kind {
    var color: Color {
        switch self {
        case .filler: return .orange
        case .cough: return .red
        case .silence: return .blue
        }
    }
}

struct CutReviewView: View {
    let analysis: MasteringAnalysis
    let title: String
    let export: ([EditCut]) -> Void
    let discard: () -> Void
    let close: () -> Void

    @State private var cuts: [EditCut]
    @State private var selection: EditCut.ID?
    @State private var overview: [Float] = []
    @State private var contexts: [EditCut.ID: String] = [:]
    @StateObject private var player = PreviewPlayer()

    init(analysis: MasteringAnalysis, title: String, export: @escaping ([EditCut]) -> Void,
         discard: @escaping () -> Void, close: @escaping () -> Void) {
        self.analysis = analysis
        self.title = title
        self.export = export
        self.discard = discard
        self.close = close
        _cuts = State(initialValue: analysis.cuts)
    }

    private var accepted: [EditCut] { cuts.filter(\.accepted) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Review cuts").font(.title2.weight(.semibold))
                Text("\(title) · \(accepted.count) of \(cuts.count) cuts on · \(String(format: "%.1f", accepted.reduce(0) { $0 + $1.duration })) s removed")
                    .foregroundStyle(.secondary)
            }

            Waveform(peaks: overview, duration: analysis.duration, cuts: cuts, selection: selection) { t in
                if let hit = cuts.min(by: { distance($0, t) < distance($1, t) }), distance(hit, t) < analysis.duration * 0.01 {
                    select(hit)
                }
            }
            .frame(height: 70)

            HStack(spacing: 8) {
                ForEach(EditCut.Kind.allCases) { kind in
                    let ofKind = cuts.filter { $0.kind == kind }
                    if !ofKind.isEmpty {
                        let allOn = ofKind.allSatisfy(\.accepted)
                        Button {
                            for i in cuts.indices where cuts[i].kind == kind { cuts[i].accepted = !allOn }
                        } label: {
                            Label("\(kind.label)s: \(ofKind.filter(\.accepted).count)/\(ofKind.count)", systemImage: allOn ? "checkmark.square.fill" : "square")
                        }
                        .tint(kind.color)
                        .help(allOn ? "Keep all \(kind.label.lowercased())s" : "Cut all \(kind.label.lowercased())s")
                    }
                }
                Spacer()
                Text("Click ▶ to hear the edit, ◉ for the original").font(.caption).foregroundStyle(.secondary)
            }

            ScrollViewReader { proxy in
                List(selection: $selection) {
                    ForEach($cuts) { $cut in
                        row($cut).id(cut.id).tag(cut.id)
                    }
                }
                .listStyle(.inset(alternatesRowBackgrounds: true))
                .onChange(of: selection) { id in
                    if let id { withAnimation { proxy.scrollTo(id, anchor: .center) } }
                }
            }

            HStack {
                Button("Export Labels…") { exportLabels() }
                    .help("Save the cuts as an Audacity label track")
                Spacer()
                Button("Don't Export", role: .destructive) { player.stop(); discard() }
                Button("Later") { player.stop(); close() }
                    .keyboardShortcut(.cancelAction)
                Button("Export with \(accepted.count) Cut\(accepted.count == 1 ? "" : "s")") { player.stop(); export(cuts) }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(minWidth: 820, minHeight: 560)
        .task {
            overview = analysis.overview(columns: 1600)
            contexts = Dictionary(uniqueKeysWithValues: cuts.map { ($0.id, context($0)) })
        }
    }

    private func row(_ cut: Binding<EditCut>) -> some View {
        let c = cut.wrappedValue
        return HStack(spacing: 10) {
            Toggle("", isOn: cut.accepted).labelsHidden().toggleStyle(.checkbox)
            Circle().fill(c.kind.color).frame(width: 8, height: 8)
            Text(Self.clock(c.start)).monospacedDigit().foregroundStyle(.secondary).frame(width: 64, alignment: .leading)
            Text(c.label).fontWeight(.medium).frame(width: 90, alignment: .leading)
            Text(contexts[c.id] ?? "").foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            Spacer()
            Text(String(format: "%.2f s", c.duration)).monospacedDigit().foregroundStyle(.secondary)
            playButton(c, edited: true)
            playButton(c, edited: false)
        }
        .opacity(c.accepted ? 1 : 0.55)
        .contentShape(Rectangle())
    }

    private func playButton(_ c: EditCut, edited: Bool) -> some View {
        let key = "\(c.id)-\(edited)"
        return Button {
            if player.playing == key { player.stop(); return }
            selection = c.id
            let from = max(0, c.start - 2), to = min(analysis.duration, c.end + 2)
            player.play(analysis.preview(from: from, to: to, cuts: edited ? [c] : []), key: key)
        } label: {
            Image(systemName: player.playing == key ? "stop.fill" : (edited ? "play.fill" : "smallcircle.filled.circle"))
                .frame(width: 16)
        }
        .buttonStyle(.borderless)
        .help(edited ? "Hear it with this cut" : "Hear the original")
    }

    private func select(_ c: EditCut) { selection = c.id }

    private func distance(_ c: EditCut, _ t: Double) -> Double {
        t < c.start ? c.start - t : (t > c.end ? t - c.end : 0)
    }

    /// The words around a cut, with what it removes in brackets.
    private func context(_ c: EditCut) -> String {
        guard let words = analysis.transcript?.words else { return "" }
        let before = words.filter { $0.anchor < c.start && $0.anchor > c.start - 4 }.suffix(5).map(\.text)
        let inside = words.filter { $0.anchor >= c.start && $0.anchor <= c.end }.map(\.text)
        let after = words.filter { $0.anchor > c.end && $0.anchor < c.end + 4 }.prefix(5).map(\.text)
        let middle: String
        switch c.kind {
        case .silence: middle = "⏸"
        case .cough: middle = "[cough]"
        case .filler: middle = "[\(inside.joined(separator: " "))]"
        }
        return "…" + (before + [middle] + after).joined(separator: " ") + "…"
    }

    private func exportLabels() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = (title as NSString).deletingPathExtension + " cuts.txt"
        panel.allowedContentTypes = [.plainText]
        if panel.runModal() == .OK, let url = panel.url {
            try? Cutting.audacityLabels(cuts).write(to: url, atomically: true, encoding: .utf8)
        }
    }

    static func clock(_ t: Double) -> String {
        String(format: "%d:%04.1f", Int(t) / 60, t.truncatingRemainder(dividingBy: 60))
    }
}

/// Whole-programme waveform with the cuts marked; click to jump to the nearest cut.
struct Waveform: View {
    let peaks: [Float]
    let duration: Double
    let cuts: [EditCut]
    let selection: EditCut.ID?
    let tapped: (Double) -> Void

    var body: some View {
        GeometryReader { geo in
            Canvas { ctx, size in
                let mid = size.height / 2
                if !peaks.isEmpty {
                    var path = Path()
                    let step = size.width / CGFloat(peaks.count)
                    for (i, p) in peaks.enumerated() {
                        let h = max(0.5, CGFloat(min(p, 1)) * mid)
                        path.addRect(CGRect(x: CGFloat(i) * step, y: mid - h, width: max(step, 0.5), height: 2 * h))
                    }
                    ctx.fill(path, with: .color(.secondary.opacity(0.6)))
                }
                guard duration > 0 else { return }
                for c in cuts {
                    let x = CGFloat(c.start / duration) * size.width
                    let w = max(2, CGFloat(c.duration / duration) * size.width)
                    let rect = CGRect(x: x, y: 0, width: w, height: size.height)
                    ctx.fill(Path(rect), with: .color(c.kind.color.opacity(c.accepted ? 0.45 : 0.12)))
                    if c.id == selection { ctx.stroke(Path(rect.insetBy(dx: -1, dy: 1)), with: .color(.primary), lineWidth: 1.5) }
                }
            }
            .background(RoundedRectangle(cornerRadius: 6).fill(Color.secondary.opacity(0.08)))
            .contentShape(Rectangle())
            .onTapGesture { location in
                tapped(Double(location.x / geo.size.width) * duration)
            }
        }
    }
}
