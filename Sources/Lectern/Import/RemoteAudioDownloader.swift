import AVFoundation
import Foundation

enum RemoteAudioDownloaderError: LocalizedError, Sendable {
    case invalidHTTPStatus(Int)
    case unreadableAudio(String)
    case emptyDownload
    case downloadFailed(String)

    var errorDescription: String? {
        switch self {
        case .invalidHTTPStatus(let code):
            return "Audio download failed: server returned HTTP \(code)."
        case .unreadableAudio(let reason):
            return "Downloaded audio file could not be read: \(reason)."
        case .emptyDownload:
            return "Downloaded audio file was empty (0 bytes)."
        case .downloadFailed(let reason):
            return "Download failed: \(reason)."
        }
    }
}

final class RemoteAudioDownloader: Sendable {
    private let session: URLSession
    private let downloadsDirectory: URL

    init(session: URLSession = .shared, downloadsDirectory: URL? = nil) {
        self.session = session
        if let downloadsDirectory {
            self.downloadsDirectory = downloadsDirectory
        } else {
            let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            self.downloadsDirectory = appSupport.appendingPathComponent("Lectern/Downloads", isDirectory: true)
        }
        try? FileManager.default.createDirectory(at: self.downloadsDirectory, withIntermediateDirectories: true)
    }

    /// Downloads a remote audio URL to a local validated file in temporary storage.
    /// Caller is responsible for moving or removing the resulting file.
    func download(from url: URL, filenameStem: String) async throws -> URL {
        try? FileManager.default.createDirectory(at: downloadsDirectory, withIntermediateDirectories: true)

        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 120)
        request.setValue("Lectern/1.3.3 (Macintosh; Mac OS X) AudioDownloader", forHTTPHeaderField: "User-Agent")

        let tempLocation: URL
        let response: URLResponse
        do {
            (tempLocation, response) = try await session.download(for: request)
        } catch {
            throw RemoteAudioDownloaderError.downloadFailed(error.localizedDescription)
        }

        guard let httpResponse = response as? HTTPURLResponse else {
            try? FileManager.default.removeItem(at: tempLocation)
            throw RemoteAudioDownloaderError.downloadFailed("Invalid server response.")
        }

        guard (200...299).contains(httpResponse.statusCode) else {
            try? FileManager.default.removeItem(at: tempLocation)
            throw RemoteAudioDownloaderError.invalidHTTPStatus(httpResponse.statusCode)
        }

        // Determine extension
        let ext = url.pathExtension.isEmpty ? "mp3" : url.pathExtension
        let safeStem = filenameStem.replacingOccurrences(of: "/", with: "-").prefix(64)
        let partFilename = "\(safeStem)-\(UUID().uuidString).\(ext).part"
        let partURL = downloadsDirectory.appendingPathComponent(partFilename)

        do {
            if FileManager.default.fileExists(atPath: partURL.path) {
                try FileManager.default.removeItem(at: partURL)
            }
            try FileManager.default.moveItem(at: tempLocation, to: partURL)
        } catch {
            try? FileManager.default.removeItem(at: tempLocation)
            throw RemoteAudioDownloaderError.downloadFailed("Failed to save downloaded file: \(error.localizedDescription)")
        }

        // Validate non-empty
        let values = try? partURL.resourceValues(forKeys: [.fileSizeKey])
        let sizeBytes = Int64(values?.fileSize ?? 0)
        guard sizeBytes > 0 else {
            try? FileManager.default.removeItem(at: partURL)
            throw RemoteAudioDownloaderError.emptyDownload
        }

        // Validate readable by AVFoundation
        do {
            _ = try AVAudioFile(forReading: partURL)
        } catch {
            try? FileManager.default.removeItem(at: partURL)
            throw RemoteAudioDownloaderError.unreadableAudio(error.localizedDescription)
        }

        // Rename from .part to final downloaded file
        let finalFilename = "\(safeStem)-\(UUID().uuidString).\(ext)"
        let finalURL = downloadsDirectory.appendingPathComponent(finalFilename)
        do {
            try FileManager.default.moveItem(at: partURL, to: finalURL)
        } catch {
            try? FileManager.default.removeItem(at: partURL)
            throw RemoteAudioDownloaderError.downloadFailed("Failed to finalize downloaded file: \(error.localizedDescription)")
        }

        return finalURL
    }

    /// Sweeps stale .part or dangling downloaded files.
    func sweepStaleDownloads() {
        let fileManager = FileManager.default
        guard let files = try? fileManager.contentsOfDirectory(at: downloadsDirectory, includingPropertiesForKeys: [.contentModificationDateKey]) else {
            return
        }

        let cutoff = Date().addingTimeInterval(-86400) // Older than 24 hours
        for file in files {
            let isPart = file.pathExtension == "part"
            let modDate = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? Date()
            if isPart || modDate < cutoff {
                try? fileManager.removeItem(at: file)
            }
        }
    }
}
