import SwiftUI
import UniformTypeIdentifiers

@main
struct KaraokeMakerApp: App {
    @NSApplicationDelegateAdaptor private var appDelegate: AppDelegate

    var body: some Scene {
        DocumentGroup(newDocument: KaraokeDocument()) { file in
            ContentView(document: file.$document, fileURL: file.fileURL)
        }
        .commands {
            SidebarCommands()
            InspectorCommands()
            EditorCommands()
        }
        .defaultSize(width: 1425, height: 873)
        // Start with a new empty song, not with the projects that were open last time.
        .restorationBehavior(.disabled)
    }
}

/// Launch behaviour, and files dropped on the Dock icon or opened with the app from the Finder.
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationWillFinishLaunching(_ notification: Notification) {
        // Launch into an empty song: no Open panel, no windows brought back from last time.
        UserDefaults.standard.register(defaults: [
            "NSShowAppCentricOpenPanelInsteadOfUntitledFile": false, "NSQuitAlwaysKeepsWindows": false,
        ])
    }

    func application(_ app: NSApplication, shouldRestoreSecureApplicationState coder: NSCoder) -> Bool { false }

    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls {
            if UTType(filenameExtension: url.pathExtension)?.conforms(to: .karaokeProject) == true {
                NSDocumentController.shared.openDocument(withContentsOf: url, display: true) { _, _, _ in }
            } else {
                MediaInbox.shared.pending.append(url)
            }
        }
        // An empty window takes the media right away; whatever is left gets a new window.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            for _ in MediaInbox.shared.pending { NSDocumentController.shared.newDocument(nil) }
        }
    }
}

/// Media waiting for a window without a song.
@MainActor @Observable
final class MediaInbox {
    static let shared = MediaInbox()
    var pending: [URL] = []

    func take() -> URL? { pending.isEmpty ? nil : pending.removeFirst() }
}

/// What the menu bar can do in the front window; nil = disabled.
struct EditorActions {
    var chooseMedia: (() -> Void)?
    var transcribe: (() -> Void)?
    var export: (() -> Void)?
    var playPause: (() -> Void)?
    var addLine: (() -> Void)?
    var splitLine: (() -> Void)?
    var moveToPreviousLine: (() -> Void)?
    var mergeLine: (() -> Void)?
    var deleteLine: (() -> Void)?
    var loop: (() -> Void)?
    var realignLine: (() -> Void)?
    var realignAll: (() -> Void)?
    var zoomIn: (() -> Void)?
    var zoomOut: (() -> Void)?
}

extension FocusedValues {
    @Entry var editor: EditorActions?
}

struct EditorCommands: Commands {
    @FocusedValue(\.editor) private var editor

    var body: some Commands {
        CommandGroup(after: .saveItem) {
            Divider()
            item(tr("Choose Video or Audio…"), \.chooseMedia).keyboardShortcut("o", modifiers: [.command, .shift])
            item(tr("Export…"), \.export).keyboardShortcut("e")
        }
        CommandGroup(after: .toolbar) {
            Divider()
            item(tr("Zoom In"), \.zoomIn).keyboardShortcut("+")
            item(tr("Zoom Out"), \.zoomOut).keyboardShortcut("-")
        }
        CommandMenu(tr("Lyrics")) {
            item(tr("Transcribe…"), \.transcribe).keyboardShortcut("t", modifiers: [.command, .option])
            Divider()
            item(tr("Play/Pause"), \.playPause)
            item(tr("Loop Selection"), \.loop).keyboardShortcut("l", modifiers: [.command, .option])
            Divider()
            item(tr("Realign Line"), \.realignLine).keyboardShortcut("a", modifiers: [.command, .option])
            item(tr("Realign All Words"), \.realignAll)
            Divider()
            item(tr("Add Line at Playhead"), \.addLine).keyboardShortcut("n", modifiers: [.command, .option])
            item(tr("Start New Line at Selected Word"), \.splitLine).keyboardShortcut("k", modifiers: [.command, .option])
            item(tr("Move Selected Word to Previous Line"), \.moveToPreviousLine).keyboardShortcut("u", modifiers: [.command, .option])
            item(tr("Merge with Next Line"), \.mergeLine).keyboardShortcut("j", modifiers: [.command, .option])
            item(tr("Delete Line"), \.deleteLine).keyboardShortcut(.delete, modifiers: [.command, .option])
        }
    }

    private func item(_ title: String, _ action: KeyPath<EditorActions, (() -> Void)?>) -> some View {
        Button(title) { editor?[keyPath: action]?() }.disabled(editor?[keyPath: action] == nil)
    }
}
