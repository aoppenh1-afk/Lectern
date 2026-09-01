import Foundation

/// SwiftUI only presents one `.fileImporter` per view, and Menu actions race
/// with that presentation. Import Audio File was bound that way, stacked under
/// Import Lectern Bundle, so the open panel never appeared.
///
/// The add-lecture menu must open an AppKit panel after the menu dismisses,
/// matching `ReferenceMaterialPicker`. `Task { @MainActor in }` is not a hop:
/// on the main actor it can run immediately, while the menu is still tearing down.

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let mainWindow = root.appendingPathComponent("Sources/Lectern/Views/MainWindowView.swift")
let picker = root.appendingPathComponent("Sources/Lectern/ImportExport/LectureImportPicker.swift")
let project = root.appendingPathComponent("Lectern.xcodeproj/project.pbxproj")

func read(_ url: URL) -> String {
    guard let source = try? String(contentsOf: url, encoding: .utf8) else {
        fputs("FAIL: missing \(url.path)\n", stderr)
        exit(1)
    }
    return source
}

let mainSource = read(mainWindow)
let pickerSource = read(picker)
let projectSource = read(project)

let fileImporterCount = mainSource.components(separatedBy: ".fileImporter(").count - 1
guard fileImporterCount == 0 else {
    fputs("FAIL: MainWindowView has \(fileImporterCount) fileImporter modifier(s). Stacking them (or presenting one from a Menu) does not open the audio import panel.\n", stderr)
    exit(1)
}

guard mainSource.contains("showingImporter") == false,
      mainSource.contains("showingBundleImporter") == false else {
    fputs("FAIL: Import Audio File still uses a SwiftUI fileImporter presentation flag\n", stderr)
    exit(1)
}

guard mainSource.contains("LectureImportPicker.chooseAudioFile") else {
    fputs("FAIL: Import Audio File is not wired to LectureImportPicker.chooseAudioFile()\n", stderr)
    exit(1)
}

guard mainSource.contains("LectureImportPicker.chooseBundle") else {
    fputs("FAIL: Import Lectern Bundle is not wired to LectureImportPicker.chooseBundle()\n", stderr)
    exit(1)
}

guard let menuRange = mainSource.range(of: "private var addLectureMenu"),
      let menuEnd = mainSource.range(of: "private var emptyList", range: menuRange.upperBound..<mainSource.endIndex) else {
    fputs("FAIL: could not find addLectureMenu in MainWindowView\n", stderr)
    exit(1)
}
let menuSource = String(mainSource[menuRange.lowerBound..<menuEnd.lowerBound])

guard menuSource.contains("DispatchQueue.main.async") else {
    fputs("FAIL: the add-lecture menu must hop with DispatchQueue.main.async so NSOpenPanel is not presented during menu dismissal\n", stderr)
    exit(1)
}

guard menuSource.contains("importAudioLecture()") else {
    fputs("FAIL: Import Audio File does not call importAudioLecture()\n", stderr)
    exit(1)
}

guard menuSource.contains("Task { @MainActor in") == false else {
    fputs("FAIL: Task { @MainActor in } can run immediately on the main actor and keeps the open panel from appearing after Import Audio File\n", stderr)
    exit(1)
}

guard pickerSource.contains("NSOpenPanel()") else {
    fputs("FAIL: LectureImportPicker must present NSOpenPanel\n", stderr)
    exit(1)
}

guard pickerSource.contains("contentTypes: [.audio]") else {
    fputs("FAIL: audio open panel must accept UTType.audio\n", stderr)
    exit(1)
}

guard pickerSource.contains("contentTypes: [.lecternBundle]") else {
    fputs("FAIL: bundle open panel must accept UTType.lecternBundle\n", stderr)
    exit(1)
}

guard pickerSource.contains("allowsMultipleSelection = false"),
      pickerSource.contains("canChooseFiles = true"),
      pickerSource.contains("canChooseDirectories = false") else {
    fputs("FAIL: lecture import panels must choose a single file\n", stderr)
    exit(1)
}

guard projectSource.contains("LectureImportPicker.swift in Sources") else {
    fputs("FAIL: LectureImportPicker.swift is not in the Lectern target, so Import Audio File cannot open a panel in the built app\n", stderr)
    exit(1)
}

print("PASS: lecture import uses a single-file AppKit open panel")
