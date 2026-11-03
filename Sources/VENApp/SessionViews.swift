import AppKit
import SwiftUI
import UniformTypeIdentifiers
import VENCore

/// Picks one audio file (an intro or outro), shown by name.
struct FileRow: View {
    let title: String
    @Binding var path: String?

    var body: some View {
        HStack {
            Text(title)
            Spacer()
            Text(path.map { URL(fileURLWithPath: $0).lastPathComponent } ?? "None").foregroundStyle(.secondary).lineLimit(1)
            Button("Choose…") {
                let panel = NSOpenPanel()
                panel.allowedContentTypes = [.audio]
                if panel.runModal() == .OK { path = panel.url?.path }
            }
            if path != nil { Button { path = nil } label: { Image(systemName: "xmark.circle.fill") }.buttonStyle(.borderless) }
        }
    }
}

/// Sets up a multitrack session: one recording per person, plus optional music tracks.
struct MultitrackSheet: View {
    let start: ([SessionTrack], String) -> Void
    let cancel: () -> Void

    @State private var tracks: [SessionTrack] = []
    @State private var name = "Episode"
    @State private var dropTargeted = false

    private var speakers: Int { tracks.filter { !$0.isMusic }.count }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Multitrack session").font(.title2.weight(.semibold))
            Text("Add one recording per person (all started at the same moment), plus any music. Each voice is cleaned and leveled on its own, and turned down while someone else talks so their voice doesn't echo through another mic.")
                .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)

            TextField("Session name", text: $name).textFieldStyle(.roundedBorder).frame(maxWidth: 300)

            List {
                ForEach($tracks) { $track in
                    HStack {
                        Image(systemName: track.isMusic ? "music.note" : "person.wave.2").frame(width: 20)
                        TextField("Name", text: $track.name).textFieldStyle(.roundedBorder).frame(width: 140)
                        Text(track.url.lastPathComponent).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                        Spacer()
                        Picker("", selection: $track.isMusic) {
                            Text("Voice").tag(false)
                            Text("Music").tag(true)
                        }
                        .pickerStyle(.segmented).labelsHidden().frame(width: 130)
                        Button { tracks.removeAll { $0.id == track.id } } label: { Image(systemName: "minus.circle") }
                            .buttonStyle(.borderless)
                    }
                }
            }
            .listStyle(.inset(alternatesRowBackgrounds: true))
            .overlay {
                if tracks.isEmpty {
                    Text("Drop the recordings here, or click Add Tracks").foregroundStyle(.secondary)
                }
            }
            .background(RoundedRectangle(cornerRadius: 8).strokeBorder(dropTargeted ? Color.accentColor : .clear, lineWidth: 2))
            .onDrop(of: [.fileURL], isTargeted: $dropTargeted) { providers in
                for p in providers {
                    _ = p.loadObject(ofClass: URL.self) { url, _ in
                        if let url { Task { @MainActor in add([url]) } }
                    }
                }
                return true
            }

            HStack {
                Button("Add Tracks…") {
                    let panel = NSOpenPanel()
                    panel.allowsMultipleSelection = true
                    panel.allowedContentTypes = [.audio]
                    if panel.runModal() == .OK { add(panel.urls) }
                }
                Spacer()
                Button("Cancel", action: cancel).keyboardShortcut(.cancelAction)
                Button("Process \(speakers) Voice\(speakers == 1 ? "" : "s")") { start(tracks, name.isEmpty ? "Session" : name) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(speakers == 0)
            }
        }
        .padding(20)
        .frame(minWidth: 680, minHeight: 440)
    }

    private func add(_ urls: [URL]) {
        for url in urls where !tracks.contains(where: { $0.url == url }) {
            // A name with "music", "intro" or "bed" in it is probably music.
            let lower = url.lastPathComponent.lowercased()
            let music = ["music", "bed", "intro", "outro", "jingle"].contains { lower.contains($0) }
            tracks.append(SessionTrack(url: url, isMusic: music))
        }
    }
}
