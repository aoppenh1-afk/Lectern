import AppKit
import UniformTypeIdentifiers

@MainActor
enum ReferenceMaterialPicker {
    static func chooseFiles() -> [URL]? {
        let panel = NSOpenPanel()
        panel.title = "Attach class materials"
        panel.message = "Choose notes, handouts, or slides to use with this course."
        panel.prompt = "Attach"
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = ReferenceMaterialService.supportedContentTypes
        return panel.runModal() == .OK ? panel.urls : nil
    }
}
