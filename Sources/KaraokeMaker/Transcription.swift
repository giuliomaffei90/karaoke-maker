import AVFoundation
import Speech

/// The lyrics recogniser: media → WAV → (optional) Demucs vocals → SpeechTranscriber words → lines, then
/// (optional) forced alignment for precise word timing.
enum Transcription {
    struct Failure: LocalizedError {
        var errorDescription: String?
    }

    /// With `lyrics`, the recognised timing is mapped onto that text instead of using the recognised words.
    /// `precise` refines every word with the forced aligner.
    static func run(media: URL, locale: Locale, isolateVocals: Bool, precise: Bool, lyrics: String? = nil,
                    status: @escaping @MainActor (String, Double?) -> Void) async throws -> [Line] {
        let folder = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }

        await status(tr("Reading audio…"), nil)
        var audio = folder.appending(path: "audio.wav")
        try await extractAudio(from: media, to: audio)
        if isolateVocals { audio = try await Python.vocals(of: media, audio: audio, status: status) }
        let words = try await transcribe(audio, locale: locale, status: status)
        guard !words.isEmpty else { throw Failure(errorDescription: tr("No words were recognised in this audio.")) }
        var lines = if let lyrics, !lyrics.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            align(lyrics: lyrics, to: words)
        } else {
            self.lines(from: words)
        }
        if precise { lines = try await realign(lines, media: media, vocals: isolateVocals, status: status) }
        return lines
    }

    /// Forced alignment of the lines' words to the media (to `range` only, if given): every word gets the time
    /// it is actually sung; words the aligner can't place keep theirs.
    static func realign(_ lines: [Line], media: URL, vocals: Bool, range: ClosedRange<Double>? = nil,
                        status: @escaping @MainActor (String, Double?) -> Void) async throws -> [Line] {
        let folder = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        await status(tr("Reading audio…"), nil)
        var source = folder.appending(path: "audio.wav")
        try await extractAudio(from: media, to: source)
        if vocals { source = try await Python.vocals(of: media, audio: source, status: status) }
        let speech = folder.appending(path: "speech.wav")
        try await extractAudio(from: source, to: speech, settings: speechSettings)
        return try await Python.align(lines, audio: speech, vocals: vocals, range: range, status: status)
    }

    static func temporaryFolder() throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appending(path: "KaraokeMaker-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    /// Any AVFoundation-readable audio or video → 16-bit WAV (44.1 kHz stereo unless `settings` say otherwise).
    static func extractAudio(from media: URL, to wav: URL, settings: [String: Any] = pcmSettings) async throws {
        let asset = AVURLAsset(url: media)
        guard let track = try await asset.loadTracks(withMediaType: .audio).first else {
            throw Failure(errorDescription: tr("This file has no audio track."))
        }
        try? FileManager.default.removeItem(at: wav)
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: settings)
        reader.add(output)
        let writer = try AVAssetWriter(outputURL: wav, fileType: .wav)
        let input = AVAssetWriterInput(mediaType: .audio, outputSettings: settings)
        writer.add(input)
        reader.startReading()
        writer.startWriting()
        writer.startSession(atSourceTime: .zero)
        await pump(input) { output.copyNextSampleBuffer().map { input.append($0) } ?? false }
        await writer.finishWriting()
        if let error = reader.error ?? writer.error { throw error }
    }

    /// What the forced aligner reads.
    static let speechSettings: [String: Any] = pcmSettings.merging([AVSampleRateKey: 16_000, AVNumberOfChannelsKey: 1]) { $1 }

    static let pcmSettings: [String: Any] = [
        AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 44_100, AVNumberOfChannelsKey: 2,
        AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false,
        AVLinearPCMIsNonInterleaved: false,
    ]

    /// Feeds a writer input until `next` (which appends one buffer) returns false.
    static func pump(_ input: AVAssetWriterInput, _ next: @escaping () -> Bool) async {
        nonisolated(unsafe) let input = input  // only touched on the pump queue
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            input.requestMediaDataWhenReady(on: DispatchQueue(label: "pump")) {
                while input.isReadyForMoreMediaData {
                    if !next() {
                        input.markAsFinished()
                        done.resume()
                        return
                    }
                }
            }
        }
    }

    static func supportedLocales() async -> [Locale] {
        await SpeechTranscriber.supportedLocales.sorted {
            name(of: $0).localizedStandardCompare(name(of: $1)) == .orderedAscending
        }
    }

    static func name(of locale: Locale) -> String {
        Locale.current.localizedString(forIdentifier: locale.identifier) ?? locale.identifier
    }

    static func transcribe(_ audio: URL, locale: Locale,
                           status: @escaping @MainActor (String, Double?) -> Void) async throws -> [Word] {
        let transcriber = SpeechTranscriber(locale: locale, transcriptionOptions: [], reportingOptions: [],
                                            attributeOptions: [.audioTimeRange])
        if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
            await status(tr("Downloading the speech model…"), nil)
            try await request.downloadAndInstall()
        }
        await status(tr("Recognising lyrics…"), nil)
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        let collect = Task {
            var words: [Word] = []
            for try await result in transcriber.results { words += self.words(in: result.text) }
            return words
        }
        let file = try AVAudioFile(forReading: audio)
        if let end = try await analyzer.analyzeSequence(from: file) {
            try await analyzer.finalizeAndFinish(through: end)
        } else {
            await analyzer.cancelAndFinishNow()
        }
        return try await collect.value
    }

    /// One word per timed run. A run that doesn't start with a space continues the previous word (pieces of
    /// one word, or punctuation).
    static func words(in text: AttributedString) -> [Word] {
        var words: [Word] = []
        for run in text.runs {
            guard let range = run.audioTimeRange else { continue }
            let raw = String(text[run.range].characters)
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            if !words.isEmpty, raw.first?.isWhitespace == false {
                words[words.count - 1].text += trimmed
                words[words.count - 1].end = max(words[words.count - 1].end, range.end.seconds)
            } else {
                words.append(Word(text: trimmed, start: range.start.seconds, end: range.end.seconds))
            }
        }
        return words
    }

    /// The pasted lyrics, one karaoke line per text line, timed from the recognised words. A word-level edit
    /// distance pairs the two sequences, so misheard, missing and extra words don't throw the rest off; a pasted
    /// word paired with a similar recognised one takes its times, the others share the time between those.
    static func align(lyrics: String, to recognised: [Word]) -> [Line] {
        let textLines = lyrics.split(whereSeparator: \.isNewline)
            .map { $0.split(whereSeparator: \.isWhitespace).map(String.init) }
            .filter { !$0.isEmpty }
        let tokens = textLines.flatMap { $0 }
        let a = tokens.map(normalise), b = recognised.map { normalise($0.text) }
        let n = a.count, m = b.count

        // cost[i][j]: aligning the first i pasted words with the first j recognised ones.
        var cost = Array(repeating: Array(repeating: 0.0, count: m + 1), count: n + 1)
        for i in 0...n { cost[i][0] = Double(i) }
        for j in 0...m { cost[0][j] = Double(j) }
        var similar = Array(repeating: Array(repeating: 0.0, count: m + 1), count: n + 1)
        for i in stride(from: 1, through: n, by: 1) {
            for j in stride(from: 1, through: m, by: 1) {
                similar[i][j] = similarity(a[i - 1], b[j - 1])
                cost[i][j] = min(cost[i - 1][j - 1] + 2 * (1 - similar[i][j]), cost[i - 1][j] + 1, cost[i][j - 1] + 1)
            }
        }
        // Walk back: pasted word i-1 takes the times of recognised word j-1 when they were paired and alike.
        var times = [ClosedRange<Double>?](repeating: nil, count: n)
        var (i, j) = (n, m)
        while i > 0 && j > 0 {
            if cost[i][j] == cost[i - 1][j - 1] + 2 * (1 - similar[i][j]) {
                if similar[i][j] >= 0.5 { times[i - 1] = recognised[j - 1].start...recognised[j - 1].end }
                (i, j) = (i - 1, j - 1)
            } else if cost[i][j] == cost[i - 1][j] + 1 {
                i -= 1
            } else {
                j -= 1
            }
        }

        // Words without a time share the gap between the timed words around them.
        var words: [Word] = []
        var k = 0
        while k < n {
            if let t = times[k] {
                words.append(Word(text: tokens[k], start: t.lowerBound, end: t.upperBound))
                k += 1
                continue
            }
            var end = k
            while end < n && times[end] == nil { end += 1 }
            var run = Array(tokens[k..<end])
            let from = words.last?.end ?? max(0, (times[end...].compactMap { $0 }.first?.lowerBound ?? 0) - 0.4 * Double(run.count))
            var to = end < n ? times[end]!.lowerBound : (recognised.last?.end ?? from) + 0.4 * Double(run.count)
            if to - from < 0.15 * Double(run.count) {
                if end < n {
                    // No room before the next timed word: share that word's time with it.
                    run.append(tokens[end])
                    to = times[end]!.upperBound
                    end += 1
                } else {
                    to = from + 0.3 * Double(run.count)
                }
            }
            words += KaraokeDocument.spread(run, from: from, to: to)
            k = end
        }

        var lines: [Line] = []
        var next = words[...]
        for line in textLines {
            lines.append(Line(words: Array(next.prefix(line.count))))
            next = next.dropFirst(line.count)
        }
        return lines
    }

    /// Lowercase, no accents, no punctuation: "Perché," and "perche" are the same word.
    static func normalise(_ word: String) -> String {
        word.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil).filter { $0.isLetter || $0.isNumber }
    }

    /// 1 for the same word, down to 0 for nothing in common (by letter edit distance).
    static func similarity(_ a: String, _ b: String) -> Double {
        if a == b { return 1 }
        let a = Array(a), b = Array(b)
        guard !a.isEmpty, !b.isEmpty else { return 0 }
        var row = Array(0...b.count)
        for i in 1...a.count {
            var previous = row[0]
            row[0] = i
            for j in 1...b.count {
                let old = row[j]
                row[j] = min(row[j] + 1, row[j - 1] + 1, previous + (a[i - 1] == b[j - 1] ? 0 : 1))
                previous = old
            }
        }
        return 1 - Double(row[b.count]) / Double(max(a.count, b.count))
    }

    /// A new line after a pause, at the end of a sentence (or a comma, once the line has some length), or
    /// when the line gets long.
    static func lines(from words: [Word], maxCharacters: Int = 32, pause: Double = 0.6) -> [Line] {
        var lines: [Line] = []
        var current: [Word] = []
        for word in words {
            let length = current.map(\.text.count).reduce(current.count, +)
            if let last = current.last,
               word.start - last.end >= pause || length + word.text.count > maxCharacters
                || ".!?;:".contains(last.text.last ?? " ") || (last.text.hasSuffix(",") && length >= 20) {
                lines.append(Line(words: current))
                current = []
            }
            current.append(word)
        }
        if !current.isEmpty { lines.append(Line(words: current)) }
        return lines
    }
}
