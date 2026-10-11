import CryptoKit
import Foundation

/// The Python side: Demucs separates the vocals, Resources/align.py (Meta's MMS forced aligner) times the words.
/// Karaoke Maker installs both into its own environment in Application Support; a Python that already has them
/// (Demucs on the PATH, or KARAOKE_PYTHON) works too. Everything runs through the user's login shell.
enum Python {
    struct Setup: Equatable {
        var interpreter: String
        var demucs: Bool
        var aligner: Bool
    }

    static let environment = URL.applicationSupportDirectory.appending(path: "KaraokeMaker/python")

    // ponytail: login shell PATH plus pip's usual folders; add a path setting if someone's install isn't found.
    private static let path = #"export PATH="$PATH:$HOME/.local/bin:/opt/homebrew/bin:/usr/local/bin:$(echo $HOME/Library/Python/*/bin | tr ' ' ':')"; "#

    /// The Python to use and what it has; nil when there's no Python at all.
    static func setup() async -> Setup? {
        let script = path + #"""
            if [ -n "$KARAOKE_PYTHON" ]; then py="$KARAOKE_PYTHON"
            elif [ -x "$1/bin/python" ]; then py="$1/bin/python"
            elif d=$(command -v demucs); then py=$(head -1 "$d" | sed 's/^#!//'); case "$py" in *" "*) py=$(command -v python3);; esac
            else py=$(command -v python3); fi
            [ -n "$py" ] || exit 1
            echo "$py"
            "$py" -c 'import demucs, numpy' 2>/dev/null && echo demucs
            "$py" -c 'import torchaudio' 2>/dev/null && echo aligner
            exit 0
            """#
        guard let out = try? await shell(script, args: [environment.path], failure: ""),
              let interpreter = out.split(separator: "\n").first.map(String.init) else { return nil }
        let found = Set(out.split(separator: "\n"))
        return Setup(interpreter: interpreter, demucs: found.contains("demucs"), aligner: found.contains("aligner"))
    }

    /// Creates Karaoke Maker's own environment with Demucs and torchaudio (about 1 GB of downloads; the models,
    /// about 1.5 GB more, come on first use).
    static func install() async throws {
        let script = path + #"""
            for p in python3.12 python3.13 python3.11 python3; do command -v $p >/dev/null && break; done
            "$p" -m venv "$1" && "$1/bin/pip" install --upgrade pip && "$1/bin/pip" install demucs torchaudio numpy
            """#
        try await shell(script, args: [environment.path], failure: tr("The installation failed:"))
    }

    /// The vocals of `media` (`audio` is its WAV), separated once and kept in Caches for next time.
    static func vocals(of media: URL, audio: URL, status: @escaping @MainActor (String, Double?) -> Void) async throws -> URL {
        let attributes = try? FileManager.default.attributesOfItem(atPath: media.path)
        let key = "\(media.path)|\(attributes?[.size] ?? 0)|\((attributes?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0)"
        let name = SHA256.hash(data: Data(key.utf8)).map { String(format: "%02x", $0) }.joined()
        let cached = URL.cachesDirectory.appending(path: "KaraokeMaker/vocals/\(name).wav")
        if FileManager.default.fileExists(atPath: cached.path) { return cached }

        guard let setup = await setup(), setup.demucs else {
            throw Transcription.Failure(errorDescription: tr("Demucs isn't installed. Install the components from Transcribe…"))
        }
        await status(tr("Isolating vocals…"), 0)
        let out = audio.deletingLastPathComponent().appending(path: "demucs")
        try await shell(#""$1" -m demucs --two-stems=vocals -o "$2" "$3""#, args: [setup.interpreter, out.path, audio.path],
                        failure: tr("Demucs failed:")) { chunk in
            if let match = chunk.matches(of: #/(\d+)%\|/#).last, let p = Double(match.1) {
                Task { await status(tr("Isolating vocals…"), p / 100) }
            }
        }
        let files = FileManager.default.enumerator(at: out, includingPropertiesForKeys: nil)
        guard let vocals = files?.compactMap({ $0 as? URL }).first(where: { $0.lastPathComponent == "vocals.wav" }) else {
            throw Transcription.Failure(errorDescription: tr("Demucs didn't produce a vocals track."))
        }
        try FileManager.default.createDirectory(at: cached.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.moveItem(at: vocals, to: cached)
        return cached
    }

    static var alignScript: URL {
        Bundle.main.url(forResource: "align", withExtension: "py")
            ?? URL(fileURLWithPath: #filePath).deletingLastPathComponent().appending(path: "../../Resources/align.py").standardizedFileURL
    }

    /// The words of `lines` timed by the forced aligner on `audio` (16 kHz mono WAV), within `range` if given.
    static func align(_ lines: [Line], audio: URL, vocals: Bool, range: ClosedRange<Double>?,
                      status: @escaping @MainActor (String, Double?) -> Void) async throws -> [Line] {
        guard let setup = await setup(), setup.aligner else {
            throw Transcription.Failure(errorDescription: tr("Precise timing needs the extra components. Install them from Transcribe…"))
        }
        var job: [String: Any] = ["audio": audio.path, "lines": lines.map { $0.words.map(\.text) }, "vocals": vocals]
        if let range {
            job["start"] = max(0, range.lowerBound)
            job["end"] = range.upperBound
        }
        let jobFile = audio.deletingLastPathComponent().appending(path: "align.json")
        try JSONSerialization.data(withJSONObject: job).write(to: jobFile)
        await status(tr("Aligning words…"), nil)
        let out = try await shell(#""$1" -W ignore "$2" "$3""#, args: [setup.interpreter, alignScript.path, jobFile.path],
                                  failure: tr("The alignment failed:")) { chunk in
            if chunk.contains("STATUS model") {
                Task { await status(tr("Loading the alignment model (the first time it downloads 1.2 GB)…"), nil) }
            }
            if let match = chunk.matches(of: #/PROGRESS ([0-9.]+)/#).last, let p = Double(match.1) {
                Task { await status(tr("Aligning words…"), p) }
            }
        }
        let times = try JSONDecoder().decode([[[Double]?]].self, from: Data(out.utf8))
        return apply(times, to: lines)
    }

    /// The aligner's times on the words; a word it couldn't place keeps its own, nudged so nothing overlaps.
    static func apply(_ times: [[[Double]?]], to lines: [Line]) -> [Line] {
        var lines = lines
        for l in lines.indices where l < times.count {
            for w in lines[l].words.indices where w < times[l].count {
                if let t = times[l][w], t.count == 2 { (lines[l].words[w].start, lines[l].words[w].end) = (t[0], t[1]) }
            }
            for w in lines[l].words.indices.dropFirst() {
                lines[l].words[w].start = max(lines[l].words[w].start, lines[l].words[w - 1].end)
                lines[l].words[w].end = max(lines[l].words[w].end, lines[l].words[w].start + 0.05)
            }
        }
        return lines
    }

    /// Runs a zsh script with `args` as $1, $2…, handing each chunk of stderr to `onOutput`. Returns stdout;
    /// throws `failure` and the end of stderr if it fails.
    @discardableResult
    private static func shell(_ script: String, args: [String], failure: String,
                              onOutput: ((String) -> Void)? = nil) async throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-lc", script, "zsh"] + args
        let out = Pipe(), err = Pipe()
        process.standardOutput = out
        process.standardError = err
        let log = Log(), output = Log()
        err.fileHandleForReading.readabilityHandler = { handle in
            let chunk = String(decoding: handle.availableData, as: UTF8.self)
            log.append(chunk)
            onOutput?(chunk)
        }
        // Read stdout as it comes, so a chatty process never blocks on a full pipe.
        out.fileHandleForReading.readabilityHandler = { handle in
            output.append(String(decoding: handle.availableData, as: UTF8.self))
        }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (done: CheckedContinuation<Void, Error>) in
                process.terminationHandler = { _ in done.resume() }
                do { try process.run() } catch { done.resume(throwing: error) }
            }
        } onCancel: {
            process.terminate()
        }
        err.fileHandleForReading.readabilityHandler = nil
        out.fileHandleForReading.readabilityHandler = nil
        output.append(String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self))
        try Task.checkCancellation()
        guard process.terminationStatus == 0 else {
            let tail = log.text.split(separator: "\n").suffix(4).joined(separator: "\n")
            throw Transcription.Failure(errorDescription: failure + "\n" + tail)
        }
        return output.text
    }

    private final class Log: @unchecked Sendable {
        private let lock = NSLock()
        private var value = ""
        func append(_ s: String) { lock.withLock { value += s } }
        var text: String { lock.withLock { value } }
    }
}
