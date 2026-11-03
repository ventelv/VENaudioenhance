import Foundation

/// Words with timings, from whisper.cpp, in the timeline of the audio that was transcribed.
public struct Transcript: Codable {
    public struct Word: Codable, Hashable {
        public var text: String
        public var start: Double
        public var end: Double
        /// A point whisper's alignment puts inside the word (more reliable than start/end).
        public var anchor: Double
        public var probability: Float

        public var normalized: String { text.lowercased().filter { $0.isLetter || $0 == "'" } }
        public var isFiller: Bool { Transcript.fillers.contains(normalized) }
        /// Non-speech annotations such as "[coughs]" or "(laughing)".
        public var isAnnotation: Bool { text.first.map { "[(*♪".contains($0) } ?? false }
    }

    public var language: String
    public var words: [Word]

    public static let fillers: Set<String> = ["um", "umm", "uhm", "uh", "uhh", "er", "erm", "ah", "ahh", "eh", "hmm", "hm", "mm", "mhm"]

    public init(language: String, words: [Word]) {
        self.language = language
        self.words = words
    }

    /// Parses `whisper-cli -ojf -ml 1 -sow` output: one segment per word, tokens carrying DTW times.
    public init(whisperJSON data: Data) throws {
        // whisper can split a multi-byte character across tokens, which leaves invalid UTF-8 in the file.
        let clean = Data(String(decoding: data, as: UTF8.self).utf8)
        guard let root = try JSONSerialization.jsonObject(with: clean) as? [String: Any],
              let segments = root["transcription"] as? [[String: Any]]
        else { throw AudioIOError(message: "Unexpected whisper output") }
        language = ((root["result"] as? [String: Any])?["language"] as? String) ?? "en"

        var raw: [(text: String, anchor: Double, p: Float)] = []
        for seg in segments {
            let text = (seg["text"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            let tokens = (seg["tokens"] as? [[String: Any]] ?? []).filter { !(($0["text"] as? String) ?? "").hasPrefix("[_") }
            let wordTokens = tokens.filter { (($0["text"] as? String) ?? "").contains { $0.isLetter || $0.isNumber } }
            let timed = wordTokens.isEmpty ? tokens : wordTokens
            let dtw = timed.compactMap { ($0["t_dtw"] as? NSNumber)?.doubleValue }.filter { $0 >= 0 }.max()
            let offsets = seg["offsets"] as? [String: Any]
            let segEnd = ((offsets?["to"] as? NSNumber)?.doubleValue ?? 0) / 1000
            let anchor = dtw.map { $0 / 100 } ?? max(0, segEnd - 0.05)
            let p = timed.compactMap { ($0["p"] as? NSNumber)?.floatValue }.min() ?? 1
            raw.append((text, anchor, p))
        }
        raw.sort { $0.anchor < $1.anchor }

        // Each word ends a little after its anchor and starts no earlier than the previous word's anchor.
        var words: [Word] = []
        for (i, r) in raw.enumerated() {
            let letters = Double(r.text.filter(\.isLetter).count)
            let estimate = min(0.8, 0.1 + 0.055 * letters)
            let prev = i > 0 ? raw[i - 1].anchor + 0.02 : 0
            words.append(Word(text: r.text, start: max(prev, r.anchor - estimate), end: r.anchor + 0.08, anchor: r.anchor, probability: r.p))
        }
        for i in words.indices.dropLast() where words[i].end > words[i + 1].start {
            words[i].end = max(words[i].anchor, words[i + 1].start)
        }
        self.words = words
    }

    // MARK: Export

    public enum Format: String, CaseIterable, Codable, Identifiable {
        case srt, vtt, txt, json
        public var id: String { rawValue }
        public var label: String { rawValue.uppercased() }
    }

    public struct Cue {
        public var start: Double
        public var end: Double
        public var text: String
    }

    /// Spoken words in the edited timeline: anything removed by a cut (fillers, coughs) is left out.
    public func edited(by map: TimeMap) -> [Word] {
        var out: [Word] = []
        var capitalizeNext = false
        for w in words where !w.isAnnotation {
            guard let anchor = map.map(w.anchor) else {
                // "today. Um, it sounds" → "today. It sounds"
                if w.text.first?.isUppercase == true { capitalizeNext = true }
                continue
            }
            var kept = w
            kept.anchor = anchor
            kept.start = map.map(w.start) ?? anchor
            kept.end = map.map(w.end) ?? anchor
            if capitalizeNext, let first = kept.text.first, first.isLowercase {
                kept.text = first.uppercased() + kept.text.dropFirst()
            }
            capitalizeNext = false
            out.append(kept)
        }
        return out
    }

    /// Subtitle cues: at most two lines of ~42 characters and 6 seconds, broken at sentences and pauses.
    public static func cues(_ words: [Word]) -> [Cue] {
        var cues: [Cue] = []
        var current: [Word] = []
        func flush() {
            guard let first = current.first, let last = current.last else { return }
            cues.append(Cue(start: first.start, end: max(last.end, first.start + 0.8), text: current.map(\.text).joined(separator: " ")))
            current = []
        }
        for w in words {
            if let last = current.last {
                let length = current.map(\.text.count).reduce(0, +) + current.count + w.text.count
                let sentenceEnd = last.text.last.map { ".?!".contains($0) } ?? false
                let commaBreak = (last.text.last == ",") && length > 50
                if length > 84 || w.end - current[0].start > 6 || w.start - last.end > 0.8 || sentenceEnd || commaBreak { flush() }
            }
            current.append(w)
        }
        flush()
        for i in cues.indices.dropLast() where cues[i].end > cues[i + 1].start { cues[i].end = cues[i + 1].start }
        return cues
    }

    static func wrap(_ text: String, width: Int = 42) -> String {
        guard text.count > width else { return text }
        // Break at the space nearest the middle.
        let chars = Array(text)
        let mid = chars.count / 2
        let spaces = chars.indices.filter { chars[$0] == " " }
        guard let split = spaces.min(by: { abs($0 - mid) < abs($1 - mid) }) else { return text }
        return String(chars[..<split]) + "\n" + String(chars[(split + 1)...])
    }

    static func timestamp(_ t: Double, separator: Character) -> String {
        let ms = Int((max(0, t) * 1000).rounded())
        return String(format: "%02d:%02d:%02d%@%03d", ms / 3_600_000, (ms / 60000) % 60, (ms / 1000) % 60, String(separator), ms % 1000)
    }

    public func export(_ format: Format, map: TimeMap = TimeMap(cuts: [])) -> String {
        let words = edited(by: map)
        switch format {
        case .srt:
            return Self.cues(words).enumerated().map { i, c in
                "\(i + 1)\n\(Self.timestamp(c.start, separator: ",")) --> \(Self.timestamp(c.end, separator: ","))\n\(Self.wrap(c.text))\n"
            }.joined(separator: "\n")
        case .vtt:
            return "WEBVTT\n\n" + Self.cues(words).map { c in
                "\(Self.timestamp(c.start, separator: ".")) --> \(Self.timestamp(c.end, separator: "."))\n\(Self.wrap(c.text))\n"
            }.joined(separator: "\n")
        case .txt:
            // A new paragraph after a sentence that ends in a pause of 1.5 s or more.
            var text = ""
            for (i, w) in words.enumerated() {
                if i > 0 {
                    let pause = w.start - words[i - 1].end
                    let sentenceEnd = words[i - 1].text.last.map { ".?!".contains($0) } ?? false
                    text += sentenceEnd && pause > 1.5 ? "\n\n" : " "
                }
                text += w.text
            }
            return text + "\n"
        case .json:
            struct Out: Encodable {
                struct W: Encodable { let text: String; let start: Double; let end: Double; let confidence: Float }
                struct C: Encodable { let start: Double; let end: Double; let text: String }
                let language: String
                let words: [W]
                let cues: [C]
            }
            func r(_ t: Double) -> Double { (t * 1000).rounded() / 1000 }
            let out = Out(language: language,
                          words: words.map { .init(text: $0.text, start: r($0.start), end: r($0.end), confidence: $0.probability) },
                          cues: Self.cues(words).map { .init(start: r($0.start), end: r($0.end), text: $0.text) })
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .withoutEscapingSlashes]
            return String(decoding: (try? encoder.encode(out)) ?? Data(), as: UTF8.self)
        }
    }

    /// Writes the chosen formats next to `audio`, e.g. "talk (VEN).srt". Returns the files written.
    @discardableResult
    public func write(_ formats: [Format], besides audio: URL, map: TimeMap = TimeMap(cuts: [])) throws -> [URL] {
        try formats.map { format in
            let url = audio.deletingPathExtension().appendingPathExtension(format.rawValue)
            try export(format, map: map).write(to: url, atomically: true, encoding: .utf8)
            return url
        }
    }
}
