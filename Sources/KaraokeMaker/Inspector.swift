import SwiftUI

struct StyleInspector: View {
    @Binding var style: KaraokeStyle
    @AppStorage(UserPresets.key) private var userPresetData = Data()
    @State private var naming = false
    @State private var presetName = ""

    private static let families = NSFontManager.shared.availableFontFamilies

    var body: some View {
        let userPresets = UserPresets.decode(userPresetData)
        Form {
            Section(tr("Preset")) {
                Menu(tr("Apply Preset")) {
                    ForEach(KaraokeStyle.presets) { p in Button(p.name) { style = p.style } }
                    if !userPresets.isEmpty {
                        Divider()
                        ForEach(userPresets) { p in Button(p.name) { style = p.style } }
                    }
                }
                HStack {
                    Button(tr("Save as Preset…")) { presetName = ""; naming = true }
                    if !userPresets.isEmpty {
                        Menu(tr("Delete Preset")) {
                            ForEach(userPresets) { p in
                                Button(p.name) { userPresetData = UserPresets.encode(userPresets.filter { $0 != p }) }
                            }
                        }
                        .fixedSize()
                    }
                }
            }
            Section(tr("Text")) {
                Picker(tr("Font"), selection: $style.fontFamily) {
                    ForEach(Self.families, id: \.self) { Text($0).tag($0) }
                }
                slider(tr("Size"), $style.fontSize, 24...200)
                Toggle(tr("Bold"), isOn: $style.bold)
                Toggle(tr("Italic"), isOn: $style.italic)
                Toggle(tr("All caps"), isOn: $style.uppercase)
            }
            Section(tr("Colors")) {
                ColorPicker(tr("Sung"), selection: RGBA.binding($style.sung))
                ColorPicker(tr("Not yet sung"), selection: RGBA.binding($style.unsung))
                ColorPicker(tr("Outline"), selection: RGBA.binding($style.outline))
                ColorPicker(tr("Sung outline"), selection: RGBA.binding($style.sungOutline))
            }
            Section(tr("Outline and Shadow")) {
                slider(tr("Outline width"), $style.outlineWidth, 0...20)
                ColorPicker(tr("Shadow"), selection: RGBA.binding($style.shadow))
                slider(tr("Shadow blur"), $style.shadowBlur, 0...40)
                slider(tr("Shadow offset"), $style.shadowOffset, 0...20)
            }
            Section(tr("Layout")) {
                Picker(tr("Lines on screen"), selection: $style.lineCount) {
                    ForEach(1...3, id: \.self) { Text("\($0)").tag($0) }
                }
                .pickerStyle(.segmented)
                Picker(tr("Position"), selection: $style.position) {
                    Text(tr("Top")).tag(KaraokeStyle.Position.top)
                    Text(tr("Middle")).tag(KaraokeStyle.Position.middle)
                    Text(tr("Bottom")).tag(KaraokeStyle.Position.bottom)
                }
                .pickerStyle(.segmented)
                slider(tr("Margin"), $style.margin, 0...400)
                slider(tr("Line spacing"), $style.lineSpacing, 1...2.5, digits: 2)
            }
            Section(tr("Animation")) {
                Picker(tr("Fill"), selection: $style.fill) {
                    Text(tr("Smooth")).tag(KaraokeStyle.Fill.smooth)
                    Text(tr("Word by word")).tag(KaraokeStyle.Fill.word)
                }
                .pickerStyle(.segmented)
                slider(tr("Show before (s)"), $style.leadIn, 0.5...6, digits: 1)
            }
            Section(tr("Background")) {
                Toggle(tr("Box behind lines"), isOn: $style.box)
                ColorPicker(tr("Box color"), selection: RGBA.binding($style.boxColor)).disabled(!style.box)
                ColorPicker(tr("Background for audio files"), selection: RGBA.binding($style.background), supportsOpacity: false)
            }
        }
        .formStyle(.grouped)
        .alert(tr("Save Preset"), isPresented: $naming) {
            TextField(tr("Name"), text: $presetName)
            Button(tr("Save")) {
                let name = presetName.trimmingCharacters(in: .whitespaces)
                guard !name.isEmpty else { return }
                userPresetData = UserPresets.encode(userPresets.filter { $0.name != name } + [Preset(name: name, style: style)])
            }
            Button(tr("Cancel"), role: .cancel) {}
        } message: {
            Text(tr("Saves the current style so you can apply it to other songs."))
        }
    }

    private func slider(_ title: String, _ value: Binding<Double>, _ range: ClosedRange<Double>, digits: Int = 0) -> some View {
        LabeledContent(title) {
            HStack {
                Slider(value: value, in: range).accessibilityLabel(title)
                Text(value.wrappedValue, format: .number.precision(.fractionLength(digits)))
                    .monospacedDigit().foregroundStyle(.secondary).frame(width: 38, alignment: .trailing)
            }
        }
    }
}

struct TranscribeSheet: View {
    let language: String?
    let replaces: Bool
    @Binding var lyrics: String
    let start: (Locale, _ isolateVocals: Bool, _ precise: Bool) -> Void
    let install: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var locales: [Locale] = []
    @State private var selected = ""
    @AppStorage("isolateVocals") private var isolate = true
    @AppStorage("preciseTiming") private var precise = true
    /// What Python has; nil while looking (or when there's no Python).
    @State private var python: Python.Setup?
    @State private var looking = true

    var body: some View {
        let demucs = python?.demucs == true, aligner = python?.aligner == true
        VStack(spacing: 0) {
            Form {
                Picker(tr("Language"), selection: $selected) {
                    ForEach(locales, id: \.identifier) { Text(Transcription.name(of: $0)).tag($0.identifier) }
                }
                .disabled(locales.isEmpty)
                Section {
                    Toggle(isOn: Binding { isolate && demucs } set: { isolate = $0 }) {
                        Text(tr("Isolate the vocals"))
                        Text(tr("Separates the voice from the music with Demucs before listening: slower, much more accurate."))
                    }
                    .disabled(!demucs)
                    Toggle(isOn: Binding { precise && aligner } set: { precise = $0 }) {
                        Text(tr("Precise word timing"))
                        Text(tr("Finds where each word starts and ends in the voice. Works best with the exact lyrics pasted below."))
                    }
                    .disabled(!aligner)
                    if looking {
                        LabeledContent(tr("Looking for the components…")) { ProgressView().controlSize(.small) }
                    } else if !demucs || !aligner {
                        LabeledContent {
                            Button(tr("Install…")) {
                                install()
                                dismiss()
                            }
                        } label: {
                            Text(tr("Components not installed"))
                            Text(tr("Both options need Demucs and PyTorch: about 1 GB to install, plus 1.5 GB of models on first use."))
                        }
                    }
                }
                Section {
                    TextEditor(text: $lyrics)
                        .font(.body)
                        .frame(height: 180)
                        .accessibilityLabel(tr("Lyrics"))
                } header: {
                    Text(tr("Lyrics (optional)"))
                } footer: {
                    Text(tr("Paste the exact lyrics and the recognised timing is mapped onto them, one karaoke line per line of text. Leave empty to use the recognised words."))
                        .foregroundStyle(.secondary)
                }
                if replaces {
                    Text(tr("The recognised lyrics replace the current ones.")).foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)
            HStack {
                Spacer()
                Button(tr("Cancel"), role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button(tr("Transcribe")) {
                    start(Locale(identifier: selected), isolate && demucs, precise && aligner)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(selected.isEmpty)
            }
            .padding([.horizontal, .bottom], 20)
        }
        .frame(width: 540)
        .task {
            locales = await Transcription.supportedLocales()
            let ids = locales.map(\.identifier)
            let current = locales.first { $0.language.languageCode == Locale.current.language.languageCode }
            selected = language.flatMap { ids.contains($0) ? $0 : nil } ?? current?.identifier ?? ids.first ?? ""
            python = await Python.setup()
            looking = false
        }
    }
}

/// The format and size, last used ones remembered.
@MainActor @Observable
final class ExportChoice {
    var kind = ExportKind(rawValue: UserDefaults.standard.string(forKey: "exportKind") ?? "") ?? .video
    var height = UserDefaults.standard.object(forKey: "exportHeight") as? Int ?? 1080

    func remember() {
        UserDefaults.standard.set(kind.rawValue, forKey: "exportKind")
        UserDefaults.standard.set(height, forKey: "exportHeight")
    }
}

/// The options inside the export save panel.
struct ExportOptions: View {
    @Bindable var choice: ExportChoice
    let hasVideo: Bool
    let changed: (ExportKind) -> Void

    var body: some View {
        Form {
            Picker(tr("Format"), selection: $choice.kind) {
                ForEach(ExportKind.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.radioGroup)
            Text(choice.kind.detail).font(.callout).foregroundStyle(.secondary)
            if hasVideo {
                LabeledContent(tr("Size"), value: tr("Same as the video"))
            } else {
                Picker(tr("Size"), selection: $choice.height) {
                    Text("720p").tag(720)
                    Text("1080p").tag(1080)
                    Text("4K").tag(2160)
                }
                .fixedSize()
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .frame(width: 480)
        .onChange(of: choice.kind) { changed(choice.kind) }
    }
}
