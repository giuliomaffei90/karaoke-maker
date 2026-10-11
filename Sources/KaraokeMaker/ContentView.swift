import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @Binding var document: KaraokeDocument
    let fileURL: URL?

    @State private var player = PlayerModel()
    @State private var selectedLine: Line.ID?
    @State private var selectedWord: Word.ID?
    @State private var showInspector = true
    @AppStorage("timelineZoom") private var zoom = 150.0
    @State private var job: Job?
    @State private var showTranscribe = false
    @State private var choosingMedia = false
    @State private var failure: Failure?
    /// The other end of a Shift-click word selection.
    @State private var rangeEnd: Word.ID?
    @State private var looping = false
    /// What the Python side can do, for Realign; nil until checked or without Python.
    @State private var python: Python.Setup?
    @FocusState private var timelineFocused: Bool
    @State private var dropTargeted = false

    struct Job {
        var status: String
        var progress: Double?
        var task: Task<Void, Never>?
    }

    struct Failure: Identifiable {
        let id = UUID()
        let title: String
        let message: String
    }

    private var media: URL? {
        document.mediaURL.flatMap { FileManager.default.fileExists(atPath: $0.path) ? $0 : nil }
    }

    var body: some View {
        Group {
            if let media {
                editor
                    .task(id: media) { await player.load(media) }
                    .task { python = await Python.setup() }
            } else {
                ContentUnavailableView {
                    Label(document.mediaPath == nil ? tr("No Song Yet") : tr("Media Not Found"), systemImage: "music.mic")
                } description: {
                    Text(document.mediaPath == nil
                        ? tr("Choose a video or an audio file, or drop it here.")
                        : tr("%@ was moved or deleted. Choose it again to keep working.", document.mediaPath ?? ""))
                } actions: {
                    Button(tr("Choose Video or Audio…")) { choosingMedia = true }
                }
                .frame(minWidth: 600, minHeight: 400)
            }
        }
        // Audio or video dropped anywhere on the window becomes this song's media (the lyrics stay);
        // a .karaoke project opens in its own window.
        .onDrop(of: [.fileURL], isTargeted: $dropTargeted) { providers in
            guard let provider = providers.first else { return false }
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                guard let url else { return }
                Task { @MainActor in open(url) }
            }
            return true
        }
        .overlay {
            if dropTargeted {
                RoundedRectangle(cornerRadius: 12).strokeBorder(.tint, lineWidth: 3).padding(4).allowsHitTesting(false)
            }
        }
        .onChange(of: MediaInbox.shared.pending, initial: true) {
            if document.mediaPath == nil, let url = MediaInbox.shared.take() { document.mediaPath = url.path }
        }
        .toolbar { toolbar }
        .navigationSubtitle(subtitle)
        .fileImporter(isPresented: $choosingMedia, allowedContentTypes: [.movie, .audio]) { result in
            if case .success(let url) = result { document.mediaPath = url.path }
        }
        .sheet(isPresented: $showTranscribe) {
            TranscribeSheet(language: document.language, replaces: !document.lines.isEmpty,
                            lyrics: Binding { document.lyrics ?? "" } set: { document.lyrics = $0.isEmpty ? nil : $0 },
                            start: transcribe, install: installComponents)
        }
        .alert(failure?.title ?? "", isPresented: Binding { failure != nil } set: { if !$0 { failure = nil } }) {
            Button(tr("OK")) {}
        } message: {
            Text(failure?.message ?? "")
        }
        .focusedSceneValue(\.editor, actions)
    }

    // MARK: - Layout

    private var editor: some View {
        NavigationSplitView {
            sidebar.navigationSplitViewColumnWidth(min: 240, ideal: 320, max: 480)
        } detail: {
            VStack(spacing: 0) {
                PreviewPane(player: player, lines: document.lines, style: document.style)
                transport
                Divider()
                wordBar
                Divider()
                SongTimeline(lines: $document.lines, zoom: $zoom, selection: selectedWordIDs, primary: selectedWord,
                             now: player.now, duration: player.duration, isPlaying: player.isPlaying,
                             waveform: player.waveform, select: select(word:)) { t in
                    timelineFocused = true
                    player.scrub(to: t)
                }
                .frame(height: 150)
            }
            .focusable()
            .focusEffectDisabled()
            .focused($timelineFocused)
            .onKeyPress(.space) {
                player.toggle()
                return .handled
            }
            // ← → scrub in small steps (⇧ for bigger ones), playing a bit of audio at each step.
            .onKeyPress(keys: [.leftArrow, .rightArrow]) { press in
                let step = press.modifiers.contains(.shift) ? 0.5 : 0.05
                player.scrub(to: player.now + (press.key == .leftArrow ? -step : step), length: 0.25)
                return .handled
            }
        }
        .inspector(isPresented: $showInspector) {
            StyleInspector(style: $document.style).inspectorColumnWidth(min: 260, ideal: 300, max: 420)
        }
        .onChange(of: player.now) {
            // Follow the song while it plays (not while looping a part of it).
            guard player.isPlaying, !looping, let l = document.lineIndex(at: player.now), document.lines[l].id != selectedLine else { return }
            selectedLine = document.lines[l].id
        }
        .onChange(of: looping) { player.loop(looping ? loopRange : nil, restart: true) }
        .onChange(of: loopRange) { if looping { player.loop(loopRange, restart: false) } }
        .onChange(of: selectedLine) {
            // A line picked on its own (not through one of its words) drops the word selection and cues the line.
            guard let l = document.lineIndex(selectedLine), document.wordIndex(selectedWord)?.line != l else { return }
            selectedWord = nil
            rangeEnd = nil
            if !player.isPlaying { player.seek(document.lines[l].start) }
        }
    }

    /// The lyrics, word by word: click a word to select it and put the playhead on it, click beside the words to
    /// pick the whole line.
    private var sidebar: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(document.lines) { line in
                        LineRow(line: line, current: line.id == currentLineID, now: player.now,
                                selection: selectedWordIDs, primary: selectedWord, select: select(word:)) { text in
                            if let l = document.lineIndex(line.id) { document.setText(text, ofLine: l) }
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(RoundedRectangle(cornerRadius: 8)
                            .fill(line.id == selectedLine ? Color.primary.opacity(0.08) : .clear))
                        .contentShape(Rectangle())
                        .onTapGesture { selectedLine = line.id }
                        .id(line.id)
                        .contextMenu {
                            Button(tr("Merge with Next Line")) { merge(line.id) }
                                .disabled(line.id == document.lines.last?.id)
                            Button(tr("Delete Line"), role: .destructive) { delete(line.id) }
                        }
                    }
                }
                .padding(8)
            }
            .onChange(of: selectedLine) {
                if let selectedLine { withAnimation { proxy.scrollTo(selectedLine) } }
            }
        }
        .overlay {
            if document.lines.isEmpty {
                ContentUnavailableView(tr("No Lyrics"), systemImage: "text.quote",
                                       description: Text(tr("Transcribe the song, or add lines at the playhead.")))
            }
        }
    }

    private var currentLineID: Line.ID? {
        document.lineIndex(at: player.now).map { document.lines[$0].id }
    }

    private var transport: some View {
        HStack(spacing: 12) {
            Button(action: player.toggle) {
                Image(systemName: player.isPlaying ? "pause.fill" : "play.fill").frame(width: 16)
            }
            .buttonStyle(.borderless)
            .help(player.isPlaying ? tr("Pause (Space)") : tr("Play (Space)"))
            .accessibilityLabel(player.isPlaying ? tr("Pause") : tr("Play"))
            Text(player.now.timecode).monospacedDigit()
            Slider(value: Binding { player.now } set: { player.seek($0) }, in: 0...max(1, player.duration))
                .accessibilityLabel(tr("Position"))
            Text(player.duration.timecode).monospacedDigit().foregroundStyle(.secondary)
        }
        .font(.callout)
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }

    /// The selected word's text and what can be done to it, above the timeline.
    private var wordBar: some View {
        // In a scroll view: a row of fixed-size controls would otherwise set the column's minimum width, and the
        // split view can't take a minimum that changes with the selection.
        GeometryReader { geo in
            ScrollView(.horizontal) {
                wordBarContent
                    .padding(.horizontal, 12)
                    .frame(minWidth: geo.size.width, minHeight: 40, alignment: .leading)
            }
            .scrollIndicators(.never)
        }
        .frame(height: 40)
    }

    private var wordBarContent: some View {
        HStack(spacing: 6) {
            if let id = selectedWord, let (l, w) = document.wordIndex(id) {
                let word = document.lines[l].words[w]
                TextField(tr("Word"), text: wordBinding(id).text)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 170)
                Text("\(word.start.timecode) – \(word.end.timecode)")
                    .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    .padding(.trailing, 6)
                Group {
                    barButton(tr("Add Word After"), "plus") {
                        if let new = document.insertWord(after: id, text: "…") { select(word: new) }
                    }
                    barButton(tr("Merge with Next Word"), "link") { document.mergeWithNextWord(id) }
                        .disabled(w + 1 >= document.lines[l].words.count)
                    barButton(tr("Delete Word"), "trash") {
                        document.deleteWord(id)
                        selectedWord = nil
                        rangeEnd = nil
                    }
                    Divider().frame(height: 18)
                    barButton(tr("Start New Line Here"), "return") { document.splitLine(atWord: id) }
                        .disabled(w == 0)
                    barButton(tr("Move to Previous Line"), "arrow.turn.left.up") { moveUpAction(id)?() }
                        .disabled(moveUpAction(id) == nil)
                    Divider().frame(height: 18)
                    barButton(tr("Set Start to Playhead"), "arrow.left.to.line") {
                        document.lines[l].words[w].start = min(player.now, word.end - 0.05)
                    }
                    barButton(tr("Set End to Playhead"), "arrow.right.to.line") {
                        document.lines[l].words[w].end = max(player.now, word.start + 0.05)
                    }
                    barButton(tr("Move Earlier"), "chevron.left") { document.nudgeWord(id, by: -0.02) }
                    barButton(tr("Move Later"), "chevron.right") { document.nudgeWord(id, by: 0.02) }
                }
            } else {
                Text(document.lines.isEmpty ? tr("Transcribe the song, or add lines at the playhead.")
                     : tr("Click a word in the lyrics or in the timeline to edit it · ⇧-click to select more words"))
                    .foregroundStyle(.secondary).lineLimit(1)
                Button(tr("Add Line at Playhead"), action: addLine)
            }
            Spacer(minLength: 24)
            Button(tr("Realign Line"), systemImage: "wand.and.sparkles") { realign(line: selectedLine) }
                .disabled(python?.aligner != true || job != nil || selectedLine == nil)
                .help(python?.aligner == true
                    ? tr("Times this line's words again from the voice: use it after correcting the text")
                    : tr("Needs the components for precise timing: install them from Transcribe…"))
            Toggle(tr("Loop"), systemImage: "repeat", isOn: $looping)
                .toggleStyle(.button)
                .disabled(selectedLine == nil)
                .help(tr("Plays the selected words over and over, or the whole line when no word is selected"))
            Divider().frame(height: 18)
            barButton(tr("Zoom Out"), "minus.magnifyingglass") { zoomBy(1 / 1.5) }
            barButton(tr("Zoom In"), "plus.magnifyingglass") { zoomBy(1.5) }
        }
        .controlSize(.regular)
    }

    private func barButton(_ title: String, _ symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { Image(systemName: symbol).frame(width: 18) }
            .buttonStyle(.borderless)
            .help(title)
            .accessibilityLabel(title)
    }

    private func zoomBy(_ factor: Double) {
        zoom = (zoom * factor).clamped(to: SongTimeline.zoomRange)
    }

    /// The words of the selection: the clicked one and, with ⇧, the ones up to the other end on its line.
    private var selectedWordIDs: Set<Word.ID> {
        guard let (l, a) = document.wordIndex(selectedWord) else { return [] }
        let b = document.wordIndex(rangeEnd).flatMap { $0.line == l ? $0.word : nil } ?? a
        return Set(document.lines[l].words[min(a, b)...max(a, b)].map(\.id))
    }

    /// Click on a word, in the lyrics or the timeline: selects it and puts the playhead on it; ⇧ extends the
    /// selection along its line.
    private func select(word id: Word.ID) {
        guard let (l, w) = document.wordIndex(id) else { return }
        if NSEvent.modifierFlags.contains(.shift), document.wordIndex(selectedWord)?.line == l {
            rangeEnd = id
        } else {
            selectedWord = id
            rangeEnd = nil
            player.seek(document.lines[l].words[w].start)
        }
        selectedLine = document.lines[l].id
    }

    @ToolbarContentBuilder private var toolbar: some ToolbarContent {
        if let job {
            ToolbarItem {
                HStack(spacing: 8) {
                    if let p = job.progress {
                        ProgressView(value: p).frame(width: 80)
                    } else {
                        ProgressView().controlSize(.small)
                    }
                    Button(tr("Stop")) { job.task?.cancel() }
                }
                .padding(.horizontal, 8)
            }
            .sharedBackgroundVisibility(.hidden)
            ToolbarSpacer(.fixed)
        }
        ToolbarItem {
            Button(tr("Transcribe")) { showTranscribe = true }
                .buttonStyle(.glass)  // same shape and padding as Export, without its tint
                .disabled(media == nil || job != nil)
                .help(tr("Recognise the lyrics and their timing from the audio"))
        }
        ToolbarSpacer(.fixed)
        ToolbarItem {
            Button(tr("Export"), action: export)
                .buttonStyle(.glassProminent)
                .disabled(media == nil || job != nil || document.lines.isEmpty)
                .help(tr("Render the karaoke video"))
        }
        ToolbarSpacer(.fixed)
        ToolbarItem {
            Button { showInspector.toggle() } label: {
                Label(tr("Inspector"), systemImage: "sidebar.trailing")
            }
            .help(showInspector ? tr("Hide Inspector") : tr("Show Inspector"))
            .disabled(media == nil)
        }
    }

    private var subtitle: String {
        if let job {
            return job.progress.map { "\(job.status) \(Int($0 * 100))%" } ?? job.status
        }
        guard let media else { return "" }
        let count = document.lines.count
        return media.lastPathComponent + (count == 0 ? "" : " · " + tr(count == 1 ? "%d line" : "%d lines", count))
    }

    // MARK: - Bindings by id (a deleted line or word never leaves a stale index behind)

    private func wordBinding(_ id: Word.ID) -> Binding<Word> {
        Binding {
            document.wordIndex(id).map { document.lines[$0.line].words[$0.word] } ?? Word(text: "", start: 0, end: 0)
        } set: { new in
            if let (l, w) = document.wordIndex(id) { document.lines[l].words[w] = new }
        }
    }

    // MARK: - Actions

    private var actions: EditorActions {
        let ready = media != nil && job == nil
        let line = document.lineIndex(selectedLine)
        return EditorActions(
            chooseMedia: job == nil ? { choosingMedia = true } : nil,
            transcribe: ready ? { showTranscribe = true } : nil,
            export: ready && !document.lines.isEmpty ? export : nil,
            playPause: media != nil ? { player.toggle() } : nil,
            addLine: media != nil ? addLine : nil,
            splitLine: selectedWord.flatMap { id in
                (document.wordIndex(id)?.word ?? 0) > 0 ? { document.splitLine(atWord: id) } : nil
            },
            moveToPreviousLine: selectedWord.flatMap(moveUpAction),
            mergeLine: line.flatMap { $0 + 1 < document.lines.count ? { merge(selectedLine) } : nil },
            deleteLine: line != nil ? { delete(selectedLine) } : nil,
            loop: line != nil ? { looping.toggle() } : nil,
            realignLine: line != nil && canRealign ? { realign(line: selectedLine) } : nil,
            realignAll: !document.lines.isEmpty && canRealign ? { realign(line: nil) } : nil,
            zoomIn: media != nil ? { zoomBy(1.5) } : nil,
            zoomOut: media != nil ? { zoomBy(1 / 1.5) } : nil
        )
    }

    private func open(_ url: URL) {
        guard let type = UTType(filenameExtension: url.pathExtension) else { return }
        if type.conforms(to: .karaokeProject) {
            NSDocumentController.shared.openDocument(withContentsOf: url, display: true) { _, _, _ in }
        } else if type.conforms(to: .audiovisualContent) {
            document.mediaPath = url.path
        } else {
            failure = Failure(title: tr("Couldn't Open the File"), message: tr("Drop an audio file (MP3, WAV…) or a video (MOV, MP4…)."))
        }
    }

    private func moveUpAction(_ id: Word.ID) -> (() -> Void)? {
        guard let (l, _) = document.wordIndex(id), l > 0 else { return nil }
        return {
            let previous = document.lines[l - 1].id
            document.moveToPreviousLine(atWord: id)
            selectedLine = previous
        }
    }

    private func addLine() {
        selectedLine = document.insertLine(at: player.now, text: tr("New line"))
    }

    private func merge(_ id: Line.ID?) {
        if let l = document.lineIndex(id) { document.mergeWithNext(l) }
    }

    private func delete(_ id: Line.ID?) {
        guard let l = document.lineIndex(id) else { return }
        document.lines.remove(at: l)
        selectedLine = document.lines.indices.contains(l) ? document.lines[l].id : document.lines.last?.id
    }

    /// Runs a long task with its status in the subtitle and a Stop button in the toolbar.
    private func run(_ failureTitle: String, _ work: @escaping (_ report: @escaping @MainActor (String, Double?) -> Void) async throws -> Void) {
        job = Job(status: tr("Starting…"))
        job?.task = Task {
            do {
                try await work { status, progress in
                    job?.status = status
                    job?.progress = progress
                }
            } catch {
                if !Task.isCancelled && !(error is CancellationError) {
                    failure = Failure(title: failureTitle, message: error.localizedDescription)
                }
            }
            job = nil
        }
    }

    private var canRealign: Bool { media != nil && job == nil && python?.aligner == true }

    /// Forced alignment of one line (with a little audio either side), or of every line when `id` is nil.
    private func realign(line id: Line.ID?) {
        guard let media else { return }
        let vocals = python?.demucs == true
        var lines = document.lines, range: ClosedRange<Double>?
        if let l = document.lineIndex(id) {
            lines = [document.lines[l]]
            range = max(0, document.lines[l].start - 2)...(document.lines[l].end + 2)
        }
        run(tr("Couldn't Realign the Words")) { report in
            for line in try await Transcription.realign(lines, media: media, vocals: vocals, range: range, status: report) {
                if let i = document.lineIndex(line.id) { document.lines[i] = line }
            }
        }
    }

    private func installComponents() {
        run(tr("Couldn't Install the Components")) { report in
            report(tr("Installing the components (about 1 GB)…"), nil)
            try await Python.install()
            python = await Python.setup()
        }
    }

    private func transcribe(_ locale: Locale, _ isolateVocals: Bool, _ precise: Bool) {
        guard let media else { return }
        document.language = locale.identifier
        run(tr("Couldn't Recognise the Lyrics")) { report in
            let lines = try await Transcription.run(media: media, locale: locale, isolateVocals: isolateVocals,
                                                       precise: precise, lyrics: document.lyrics, status: report)
            document.lines = lines
            selectedLine = lines.first?.id
        }
    }

    /// One save panel with the format and size in it; renders straight into the chosen file and shows it in the
    /// Finder.
    private func export() {
        guard let media, let window = NSApp.keyWindow else { return }
        let base = (fileURL ?? media).deletingPathExtension().lastPathComponent
        let choice = ExportChoice()
        let panel = NSSavePanel()
        panel.canCreateDirectories = true
        let options = NSHostingView(rootView: ExportOptions(choice: choice, hasVideo: player.aspect != nil) { [weak panel] kind in
            guard let panel else { return }
            panel.allowedContentTypes = [kind.contentType]
            panel.nameFieldStringValue = base + (kind == .overlay ? " Overlay" : " Karaoke")
        })
        options.frame.size = options.fittingSize
        panel.accessoryView = options
        panel.allowedContentTypes = [choice.kind.contentType]
        panel.nameFieldStringValue = base + (choice.kind == .overlay ? " Overlay" : " Karaoke")
        panel.beginSheetModal(for: window) { response in
            guard response == .OK, let url = panel.url else { return }
            let (kind, height) = (choice.kind, choice.height)
            choice.remember()
            let (lines, style) = (document.lines, document.style)
            run(tr("Couldn't Export the Video")) { report in
                do {
                    try await Exporter.export(media: media, lines: lines, style: style, kind: kind, height: height, to: url) { p in
                        Task { @MainActor in report(tr("Rendering…"), p) }
                    }
                } catch {
                    try? FileManager.default.removeItem(at: url)  // no half-written video left behind
                    throw error
                }
                NSWorkspace.shared.activateFileViewerSelecting([url])
            }
        }
    }

    /// The selected words (a Shift-click range, one word, or the whole line) — what Loop plays.
    private var loopRange: ClosedRange<Double>? {
        guard let l = document.lineIndex(selectedLine), !document.lines[l].words.isEmpty else { return nil }
        let words = document.lines[l].words
        let picked = [selectedWord, rangeEnd].compactMap { id in words.firstIndex { $0.id == id } }
        guard let lo = picked.min(), let hi = picked.max() else { return document.lines[l].start...document.lines[l].end }
        return words[lo].start...words[hi].end
    }
}

/// A line of the lyrics as words you can click; double-click to retype the whole line.
private struct LineRow: View {
    let line: Line
    let current: Bool
    let now: Double
    let selection: Set<Word.ID>
    let primary: Word.ID?
    let select: (Word.ID) -> Void
    let commit: (String) -> Void
    @State private var editing = false
    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(line.start.timecode)
                .font(.caption.monospacedDigit())
                .foregroundStyle(current ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
            if editing {
                TextField(tr("Lyrics"), text: $text, axis: .vertical)
                    .textFieldStyle(.plain)
                    .focused($focused)
                    .onSubmit { finish() }
                    .onExitCommand { editing = false }
                    .onChange(of: focused) { if !focused { finish() } }
            } else {
                FlowLayout(spacing: 2) {
                    ForEach(line.words) { word in
                        let selected = selection.contains(word.id)
                        // While its line plays, a word lights up once it's sung.
                        let sung = current && word.start <= now
                        Text(word.text)
                            .fontWeight(current ? .semibold : .regular)
                            .foregroundStyle(sung ? AnyShapeStyle(.tint) : AnyShapeStyle(.primary))
                            .padding(.horizontal, 3)
                            .padding(.vertical, 1)
                            .background {
                                if selected {
                                    RoundedRectangle(cornerRadius: 4)
                                        .strokeBorder(Color.accentColor, lineWidth: word.id == primary ? 2 : 1)
                                }
                            }
                            .contentShape(Rectangle())
                            .onTapGesture { select(word.id) }
                            .accessibilityAddTraits(.isButton)
                            .accessibilityAction { select(word.id) }
                    }
                }
                .simultaneousGesture(TapGesture(count: 2).onEnded {
                    text = line.text
                    editing = true
                    focused = true
                })
                .help(tr("Click a word to select it, double-click to edit the line"))
            }
        }
        .padding(.vertical, 2)
    }

    private func finish() {
        guard editing else { return }
        editing = false
        if text != line.text { commit(text) }
    }
}

/// Lays its views out left to right, wrapping onto new rows like text.
private struct FlowLayout: Layout {
    var spacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(subviews, width: proposal.width ?? .infinity)
        return CGSize(width: proposal.width ?? rows.map(\.maxX).max() ?? 0, height: rows.last.map { $0.y + $0.height } ?? 0)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for row in arrange(subviews, width: bounds.width) {
            for (i, x) in row.items {
                subviews[i].place(at: CGPoint(x: bounds.minX + x, y: bounds.minY + row.y), proposal: .unspecified)
            }
        }
    }

    private struct Row {
        var items: [(Int, CGFloat)] = []
        var y: CGFloat = 0, height: CGFloat = 0, maxX: CGFloat = 0
    }

    private func arrange(_ subviews: Subviews, width: CGFloat) -> [Row] {
        var rows = [Row()]
        var x: CGFloat = 0
        for (i, view) in subviews.enumerated() {
            let size = view.sizeThatFits(.unspecified)
            if x > 0 && x + size.width > width {
                let y = rows[rows.count - 1].y + rows[rows.count - 1].height + spacing
                rows.append(Row(y: y))
                x = 0
            }
            rows[rows.count - 1].items.append((i, x))
            rows[rows.count - 1].height = max(rows[rows.count - 1].height, size.height)
            rows[rows.count - 1].maxX = x + size.width
            x += size.width + spacing
        }
        return rows
    }
}

/// The video (or the background colour) with the lyrics drawn over it, exactly as the export draws them.
private struct PreviewPane: View {
    let player: PlayerModel
    let lines: [Line]
    let style: KaraokeStyle

    var body: some View {
        ZStack {
            if player.aspect != nil {
                PlayerLayerView(player: player.player)
            } else {
                Color(cgColor: style.background.cgColor)
            }
            TimelineView(.animation(paused: !player.isPlaying)) { _ in
                let time = player.isPlaying ? player.time : player.now
                Canvas { ctx, size in
                    ctx.withCGContext { cg in
                        cg.translateBy(x: 0, y: size.height)
                        cg.scaleBy(x: 1, y: -1)
                        KaraokeRenderer.draw(lines, style: style, at: time, in: cg, size: size)
                    }
                }
            }
        }
        .aspectRatio(player.aspect ?? 16 / 9, contentMode: .fit)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.black)
        .accessibilityElement()
        .accessibilityLabel(tr("Preview"))
    }
}
