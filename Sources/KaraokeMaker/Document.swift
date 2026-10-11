import SwiftUI
import UniformTypeIdentifiers

struct Word: Codable, Identifiable, Hashable {
    var id = UUID()
    var text: String
    var start: Double
    var end: Double
}

struct Line: Codable, Identifiable, Hashable {
    var id = UUID()
    var words: [Word]

    var start: Double { words.first?.start ?? 0 }
    var end: Double { words.last?.end ?? 0 }
    var text: String { words.map(\.text).joined(separator: " ") }
}

extension UTType {
    // A new identifier: Spotlight keeps the conformance it first saw for an identifier (the old .project one
    // was declared as JSON, so the Finder previewed the files as text).
    static let karaokeProject = UTType(exportedAs: "com.giuliomaffei.KaraokeMaker.song")
}

/// A `.kr` file: a binary property list with the media path, the timed lyrics and the style. Binary, so nothing
/// previews it as text; older projects saved as JSON still open.
struct KaraokeDocument: FileDocument, Codable {
    static var readableContentTypes: [UTType] { [.karaokeProject] }

    var mediaPath: String?
    var language: String?
    /// The lyrics pasted for the last transcription, offered again next time.
    var lyrics: String?
    var lines: [Line] = []
    var style = KaraokeStyle.presets[0].style

    init() {}

    init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents else { throw CocoaError(.fileReadCorruptFile) }
        self = try (try? PropertyListDecoder().decode(Self.self, from: data)) ?? JSONDecoder().decode(Self.self, from: data)
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        return FileWrapper(regularFileWithContents: try encoder.encode(self))
    }

    var mediaURL: URL? { mediaPath.map { URL(fileURLWithPath: $0) } }
}

// MARK: - Editing

extension KaraokeDocument {
    func lineIndex(_ id: Line.ID?) -> Int? { lines.firstIndex { $0.id == id } }

    /// Line and word index of a word.
    func wordIndex(_ id: Word.ID?) -> (line: Int, word: Int)? {
        for (l, line) in lines.enumerated() {
            if let w = line.words.firstIndex(where: { $0.id == id }) { return (l, w) }
        }
        return nil
    }

    /// The line being sung at `time`, or the last one that started before it.
    func lineIndex(at time: Double) -> Int? {
        lines.lastIndex { $0.start <= time } ?? (lines.isEmpty ? nil : 0)
    }

    /// Replaces a line's text. Same word count: words keep their times. Otherwise the new words share the
    /// line's time span in proportion to their length. Empty text deletes the line.
    mutating func setText(_ text: String, ofLine l: Int) {
        let tokens = text.split(whereSeparator: \.isWhitespace).map(String.init)
        guard !tokens.isEmpty else { lines.remove(at: l); return }
        let old = lines[l]
        if tokens.count == old.words.count {
            for i in tokens.indices { lines[l].words[i].text = tokens[i] }
            return
        }
        lines[l].words = Self.spread(tokens, from: old.start, to: max(old.end, old.start + 0.3 * Double(tokens.count)))
    }

    static func spread(_ tokens: [String], from start: Double, to end: Double) -> [Word] {
        let weights = tokens.map { Double($0.count + 1) }
        let total = weights.reduce(0, +)
        var t = start
        return zip(tokens, weights).map { token, weight in
            let length = (end - start) * weight / total
            defer { t += length }
            return Word(text: token, start: t, end: t + length)
        }
    }

    /// Moves the word and everything after it to a new line right below.
    mutating func splitLine(atWord id: Word.ID) {
        guard let (l, w) = wordIndex(id), w > 0 else { return }
        let tail = Array(lines[l].words[w...])
        lines[l].words.removeSubrange(w...)
        lines.insert(Line(words: tail), at: l + 1)
    }

    /// Moves the word and everything before it to the end of the previous line.
    mutating func moveToPreviousLine(atWord id: Word.ID) {
        guard let (l, w) = wordIndex(id), l > 0 else { return }
        lines[l - 1].words += lines[l].words[...w]
        lines[l].words.removeSubrange(...w)
        if lines[l].words.isEmpty { lines.remove(at: l) }
    }

    /// A new word right after this one, in the gap before the next word or, without room, in the second half of
    /// this one. Returns its id.
    @discardableResult
    mutating func insertWord(after id: Word.ID, text: String) -> Word.ID? {
        guard let (l, w) = wordIndex(id) else { return nil }
        let word = lines[l].words[w]
        let next = w + 1 < lines[l].words.count ? lines[l].words[w + 1].start : word.end + 0.5
        var new = Word(text: text, start: word.end, end: min(next, word.end + 0.4))
        if new.end - new.start < 0.1 {
            let middle = (word.start + word.end) / 2
            lines[l].words[w].end = middle
            new = Word(text: text, start: middle, end: word.end)
        }
        lines[l].words.insert(new, at: w + 1)
        return new.id
    }

    /// Joins the word with the next one on its line: one word spanning both.
    mutating func mergeWithNextWord(_ id: Word.ID) {
        guard let (l, w) = wordIndex(id), w + 1 < lines[l].words.count else { return }
        let next = lines[l].words.remove(at: w + 1)
        lines[l].words[w].text += " " + next.text
        lines[l].words[w].end = next.end
    }

    /// Moves the word in time, without crossing the words around it.
    mutating func nudgeWord(_ id: Word.ID, by seconds: Double) {
        guard let (l, w) = wordIndex(id) else { return }
        let all = lines.flatMap(\.words), i = all.firstIndex { $0.id == id }!
        let word = lines[l].words[w]
        let lo = i > 0 ? all[i - 1].end : 0, hi = i + 1 < all.count ? all[i + 1].start : .infinity
        let d = min(max(seconds, lo - word.start), hi - word.end)
        lines[l].words[w].start += d
        lines[l].words[w].end += d
    }

    mutating func mergeWithNext(_ l: Int) {
        guard l + 1 < lines.count else { return }
        lines[l].words += lines.remove(at: l + 1).words
    }

    mutating func deleteWord(_ id: Word.ID) {
        guard let (l, w) = wordIndex(id) else { return }
        lines[l].words.remove(at: w)
        if lines[l].words.isEmpty { lines.remove(at: l) }
    }

    /// A new two-second line at `time`, kept in time order. Returns its id.
    mutating func insertLine(at time: Double, text: String) -> Line.ID {
        let line = Line(words: Self.spread(text.split(separator: " ").map(String.init), from: time, to: time + 2))
        lines.insert(line, at: lines.firstIndex { $0.start > time } ?? lines.count)
        return line.id
    }
}

// MARK: - Display timing

extension Array where Element == Line {
    /// When line `i` is on screen: lines take turns in `slots` rows, a line appears `leadIn` seconds before it
    /// is sung (but not before the line it replaces in its row has been finished for 0.3 s, or this one starts) and stays until it is replaced
    /// or one second after it ends.
    func visibility(of i: Int, slots: Int, leadIn: Double) -> ClosedRange<Double> {
        func appear(_ i: Int) -> Double {
            Swift.max(i >= slots ? Swift.min(self[i - slots].end + 0.3, self[i].start) : -.infinity, self[i].start - leadIn)
        }
        let leave = Swift.min(self[i].end + 1, i + slots < count ? appear(i + slots) : .infinity)
        return appear(i)...Swift.max(appear(i), leave)
    }
}
