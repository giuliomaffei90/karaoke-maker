import Testing
import Foundation
import CoreGraphics
@testable import KaraokeMaker

private func line(_ words: (String, Double, Double)...) -> Line {
    Line(words: words.map { Word(text: $0.0, start: $0.1, end: $0.2) })
}

@Test func editingTextKeepsOrSpreadsTimes() {
    var doc = KaraokeDocument()
    doc.lines = [line(("helo", 1, 2), ("world", 2, 3))]
    doc.setText("hello world", ofLine: 0)
    #expect(doc.lines[0].words.map(\.start) == [1, 2])
    #expect(doc.lines[0].text == "hello world")

    doc.setText("hello big world", ofLine: 0)
    #expect(doc.lines[0].words.count == 3)
    #expect(doc.lines[0].start == 1 && abs(doc.lines[0].end - 3) < 1e-9)

    doc.setText("  ", ofLine: 0)
    #expect(doc.lines.isEmpty)
}

@Test func splitMergeDelete() {
    var doc = KaraokeDocument()
    doc.lines = [line(("a", 0, 1), ("b", 1, 2), ("c", 2, 3))]
    doc.splitLine(atWord: doc.lines[0].words[2].id)
    #expect(doc.lines.map(\.text) == ["a b", "c"])
    doc.moveToPreviousLine(atWord: doc.lines[1].words[0].id)
    #expect(doc.lines.map(\.text) == ["a b c"])
    doc.splitLine(atWord: doc.lines[0].words[1].id)
    doc.moveToPreviousLine(atWord: doc.lines[1].words[0].id)
    #expect(doc.lines.map(\.text) == ["a b", "c"])
    doc.mergeWithNext(0)
    #expect(doc.lines.map(\.text) == ["a b c"])
    for w in doc.lines[0].words { doc.deleteWord(w.id) }
    #expect(doc.lines.isEmpty)
}

@Test func linesAppearAndLeaveInTurns() {
    let lines = [line(("one", 10, 12)), line(("two", 12, 14)), line(("three", 14, 16))]
    // First line: lead-in before it, until the third line (same row) takes over after it ends.
    #expect(lines.visibility(of: 0, slots: 2, leadIn: 3) == 7...12.3)
    // Third line waits for the first to finish even if the lead-in would show it earlier.
    #expect(lines.visibility(of: 2, slots: 2, leadIn: 3) == 12.3...17)
    // One row: each line hands over to the next.
    #expect(lines.visibility(of: 1, slots: 1, leadIn: 3) == 12...14)
}

@Test func recognisedWordsBecomeLines() {
    let words = [Word(text: "a", start: 0, end: 0.5), Word(text: "b", start: 0.5, end: 1),
                 Word(text: "c", start: 3, end: 3.5)]
    #expect(Transcription.lines(from: words).map(\.text) == ["a b", "c"])
    let sentence = ["How", "I", "wonder", "what", "you", "are,", "up", "above"].enumerated().map {
        Word(text: $1, start: Double($0) * 0.3, end: Double($0) * 0.3 + 0.25)
    }
    #expect(Transcription.lines(from: sentence).map(\.text) == ["How I wonder what you are,", "up above"])
}

/// Recognises and renders a real file: `KARAOKE_MEDIA=/path/song.mp4 swift test`. Writes the exports next to it.
@Test(.enabled(if: ProcessInfo.processInfo.environment["KARAOKE_MEDIA"] != nil))
func transcribesAndExports() async throws {
    let media = URL(fileURLWithPath: ProcessInfo.processInfo.environment["KARAOKE_MEDIA"]!)
    let lines = try await Transcription.run(media: media, locale: Locale(identifier: "en_US"), isolateVocals: false, precise: false) { s, _ in print(s) }
    for l in lines { print(l.start.timecode, l.text) }
    #expect(lines.map(\.text).joined(separator: " ").lowercased().contains("little star"))
    for kind in ExportKind.allCases {
        let out = media.deletingLastPathComponent().appending(path: "out-\(kind.rawValue).\(kind == .overlay ? "mov" : "mp4")")
        try await Exporter.export(media: media, lines: lines, style: KaraokeStyle.presets[0].style, kind: kind,
                                  height: 720, to: out) { _ in }
        #expect(FileManager.default.fileExists(atPath: out.path))
    }
}

@Test func olderProjectsKeepOpening() throws {
    let style = try JSONDecoder().decode(KaraokeStyle.self, from: Data(#"{"fontSize": 40}"#.utf8))
    #expect(style.fontSize == 40 && style.lineCount == KaraokeStyle().lineCount)
}

@Test func everyStringHasAnItalianTranslation() throws {
    let sources = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appending(path: "../../Sources/KaraokeMaker")
    let strings = try FileManager.default.contentsOfDirectory(at: sources, includingPropertiesForKeys: nil)
        .map { try String(contentsOf: $0, encoding: .utf8) }.joined()
    let table = try String(contentsOf: sources.appending(path: "Strings.swift"), encoding: .utf8)
    for match in strings.matches(of: #/tr\("([^"]+)"/#) {
        #expect(table.contains("\"\(match.1)\": "), "missing Italian for \(match.1)")
    }
}

@Test func pastedLyricsTakeTheRecognisedTiming() {
    // Recognised: "twinkle twinkle little car how wonder" — one word misheard, one missing, one extra ("um").
    let heard = [("twinkle", 0.0), ("twinkle", 0.5), ("um", 0.9), ("little", 1.0), ("car", 1.5), ("how", 3.0), ("wonder", 3.8)]
        .map { Word(text: $0.0, start: $0.1, end: $0.1 + 0.4) }
    let lines = Transcription.align(lyrics: "Twinkle, twinkle, little star,\n\nHow I wonder", to: heard)
    #expect(lines.map(\.text) == ["Twinkle, twinkle, little star,", "How I wonder"])
    #expect(lines[0].words.map(\.start) == [0, 0.5, 1.0, 1.5])   // "star," ~ "car"
    let i = lines[1].words[1]                                    // "I" was not heard: between "how" and "wonder"
    #expect(i.start >= 3.4 && i.end <= 3.8)
    #expect(lines[1].words[2].start == 3.8)
}

/// Prints recognised and aligned timings: `KARAOKE_DEBUG=/path/song.mp3 KARAOKE_LYRICS=/path/lyrics.txt swift test --filter debugAlignment`
@Test(.enabled(if: ProcessInfo.processInfo.environment["KARAOKE_DEBUG"] != nil))
func debugAlignment() async throws {
    let env = ProcessInfo.processInfo.environment
    let media = URL(fileURLWithPath: env["KARAOKE_DEBUG"]!)
    let wav = FileManager.default.temporaryDirectory.appending(path: "debug.wav")
    try await Transcription.extractAudio(from: media, to: wav)
    let words = try await Transcription.transcribe(wav, locale: Locale(identifier: env["KARAOKE_LOCALE"] ?? "it_IT")) { _, _ in }
    print("RECOGNISED"); for w in words { print(String(format: "%6.2f %6.2f  %@", w.start, w.end, w.text)) }
    if let path = env["KARAOKE_LYRICS"] {
        let lines = Transcription.align(lyrics: try String(contentsOfFile: path, encoding: .utf8), to: words)
        print("ALIGNED"); for w in lines.flatMap(\.words) { print(String(format: "%6.2f %6.2f  %@", w.start, w.end, w.text)) }
        // With KARAOKE_PYTHON pointing at an environment with Demucs and torchaudio: the precise path, as the app runs it.
        if env["KARAOKE_PYTHON"] != nil {
            let precise = try await Transcription.realign(lines, media: media, vocals: true) { s, _ in print(s) }
            print("PRECISE"); for w in precise.flatMap(\.words) { print(String(format: "%6.2f %6.2f  %@", w.start, w.end, w.text)) }
            let line = try await Transcription.realign([precise[3]], media: media, vocals: true,
                                                       range: (precise[3].start - 2)...(precise[3].end + 2)) { _, _ in }
            print("LINE 4 ALONE"); for w in line[0].words { print(String(format: "%6.2f %6.2f  %@", w.start, w.end, w.text)) }
        }
    }
}

@Test func unheardWordsNeverOverlap() {
    // "ci" was not heard and has no gap before "guiderai": they share guiderai's time.
    let heard = [("con", 21.12, 21.42), ("un", 21.42, 21.66), ("bip", 21.66, 22.02), ("guiderai", 22.02, 23.34)]
        .map { Word(text: $0.0, start: $0.1, end: $0.2) }
    let words = Transcription.align(lyrics: "con un bip ci guiderai", to: heard)[0].words
    for (a, b) in zip(words, words.dropFirst()) { #expect(a.end <= b.start + 1e-9) }
    #expect(abs(words.last!.end - 23.34) < 1e-9)
}

@Test func wordEditing() {
    var doc = KaraokeDocument()
    doc.lines = [line(("vie", 1, 1.5), ("ni", 1.5, 2), ("qua", 3, 3.5))]
    doc.mergeWithNextWord(doc.lines[0].words[0].id)
    #expect(doc.lines[0].words.map(\.text) == ["vie ni", "qua"] && doc.lines[0].words[0].end == 2)
    // Room after "vie ni": the new word goes in the gap. No room after it: it takes half of the word.
    let added = doc.insertWord(after: doc.lines[0].words[0].id, text: "x")!
    #expect(doc.lines[0].words[1].id == added && doc.lines[0].words[1].start == 2)
    doc.insertWord(after: added, text: "y")
    #expect(doc.lines[0].words.map(\.text) == ["vie ni", "x", "y", "qua"])
    #expect(doc.lines[0].words[2].end <= doc.lines[0].words[3].start)
    doc.nudgeWord(doc.lines[0].words[3].id, by: -5)          // stops at the word before
    #expect(doc.lines[0].words[3].start == doc.lines[0].words[2].end)
}

@Test func projectsRoundTripAsBinaryPlist() throws {
    var doc = KaraokeDocument()
    doc.mediaPath = "/tmp/song.mp3"
    doc.lines = [line(("ciao", 1, 2))]
    let encoder = PropertyListEncoder()
    encoder.outputFormat = .binary
    let data = try encoder.encode(doc)
    #expect(data.starts(with: Data("bplist".utf8)))
    let back = try PropertyListDecoder().decode(KaraokeDocument.self, from: data)
    #expect(back.lines == doc.lines && back.mediaPath == doc.mediaPath)
}

/// Every preset draws something, mid-word, with the current word growing and boxed.
@Test func presetsRender() {
    let lines = [line(("sing", 0, 1), ("along", 1, 2), ("now", 2, 3))]
    for preset in KaraokeStyle.presets {
        let ctx = CGContext(data: nil, width: 320, height: 180, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        var style = preset.style
        style.pop = 0.2
        style.highlight = RGBA(1, 0, 0)
        KaraokeRenderer.draw(lines, style: style, at: 1.5, in: ctx, size: CGSize(width: 320, height: 180))
        let pixels = UnsafeBufferPointer(start: ctx.data!.assumingMemoryBound(to: UInt8.self), count: ctx.bytesPerRow * 180)
        #expect(pixels.contains { $0 != 0 }, "\(preset.name) drew nothing")
    }
    #expect(Set(KaraokeStyle.presets.map(\.name)).count == KaraokeStyle.presets.count)
}
