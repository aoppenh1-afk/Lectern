import AppKit
import UniformTypeIdentifiers

/// AppKit open panels for lecture import. SwiftUI `.fileImporter` does not
/// present from a Menu, and stacking two of them on one view leaves only the
/// last modifier working.
@MainActor
enum LectureImportPicker {
    static func chooseAudioFile() -> URL? {
        chooseFile(
            title: "Import Audio Lecture",
            message: "Choose an audio recording to add as a lecture.",
            contentTypes: [.audio]
        )
    }

    static func chooseBundle() -> URL? {
        chooseFile(
            title: "Import Lectern Bundle",
            message: "Choose a Lectern bundle to add as a lecture.",
            contentTypes: [.lecternBundle]
        )
    }

    private static func chooseFile(title: String, message: String, contentTypes: [UTType]) -> URL? {
        let panel = NSOpenPanel()
        panel.title = title
        panel.message = message
        panel.prompt = "Import"
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = contentTypes
        NSApp.activate(ignoringOtherApps: true)
        return panel.runModal() == .OK ? panel.url : nil
    }
}
