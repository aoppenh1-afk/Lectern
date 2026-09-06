import Foundation
import Observation
import ParakeetTDT

/// Central check for whether the on-device transcription models are present.
/// Both pickers and Settings read this so rows stay in sync: downloaded
/// models are selectable, missing ones render grayed out with a
/// "Not downloaded" note instead of being hidden.
@MainActor
@Observable
final class LocalModelAvailability {
    var parakeetDownloaded = false
    var whisperDownloaded = false
    var whisperCLIInstalled = false
    private(set) var lastChecked: Date?

    init() {}

    /// Re-read the on-disk caches. Cheap file-existence checks; call from
    /// `.task`, `.onAppear`, after a download finishes, or when the
    /// transcription picker opens.
    func refresh() {
        parakeetDownloaded = Self.isParakeetCached()
        whisperDownloaded = Self.isWhisperCached()
        whisperCLIInstalled = WhisperTranscriptionEngine.isCLIInstalled
        lastChecked = Date()
    }

    func isDownloaded(_ model: BuiltInTranscriptionModel) -> Bool {
        switch model {
        case .parakeet: return parakeetDownloaded
        case .whisper: return whisperDownloaded
        case .antigravity: return true
        }
    }

    /// Mirrors `TranscriptionEngine.modelsRoot` + its `tokenizer.json`
    /// presence check without needing an engine instance.
    static func isParakeetCached() -> Bool {
        let modelsRoot = ModelDownloader.defaultCacheDirectory()
            .appendingPathComponent(TranscriptionEngine.repoId.replacingOccurrences(of: "/", with: "_"))
        return FileManager.default.fileExists(
            atPath: modelsRoot.appendingPathComponent("tokenizer.json").path
        )
    }

    static func isWhisperCached() -> Bool {
        FileManager.default.fileExists(atPath: WhisperTranscriptionEngine.modelURL.path)
    }
}
