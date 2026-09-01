import AppKit
import SwiftUI

let output = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first ?? "/tmp/lectern-export-sheet.png")
let app = NSApplication.shared
app.setActivationPolicy(.prohibited)

Task { @MainActor in
    let lecture = Lecture(
        title: "Shiur 4-14",
        artifacts: [Artifact(kind: .rawTranscript, content: "[00:00] Sample transcript")]
    )
    let hostingView = NSHostingView(rootView: LectureBundleExportSheet(lecture: lecture))
    hostingView.frame = NSRect(x: 0, y: 0, width: 580, height: 540)
    hostingView.layoutSubtreeIfNeeded()

    guard let representation = hostingView.bitmapImageRepForCachingDisplay(in: hostingView.bounds) else {
        fatalError("Could not create export-sheet bitmap")
    }
    hostingView.cacheDisplay(in: hostingView.bounds, to: representation)
    guard let png = representation.representation(using: .png, properties: [:]) else {
        fatalError("Could not encode export-sheet bitmap")
    }
    try png.write(to: output, options: .atomic)
    print(output.path)
    app.terminate(nil)
}

app.run()
