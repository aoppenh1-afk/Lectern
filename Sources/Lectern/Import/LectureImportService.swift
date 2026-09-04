import AVFoundation
import Foundation
import SwiftData

@MainActor
final class LectureImportService {
    struct ImportMetadata {
        var title: String?
        var course: Course?
        var language: LectureLanguage?
        var capturedAt: Date?
        var sourceProviderRaw: String?
        var sourceKey: String?
        var sourcePageURL: String?
        var sourceMediaURL: String?
        var sourceTeacherName: String?
        var sourceSeriesName: String?
        var sourceSubscriptionID: UUID?

        init(
            title: String? = nil,
            course: Course? = nil,
            language: LectureLanguage? = nil,
            capturedAt: Date? = nil,
            sourceProviderRaw: String? = nil,
            sourceKey: String? = nil,
            sourcePageURL: String? = nil,
            sourceMediaURL: String? = nil,
            sourceTeacherName: String? = nil,
            sourceSeriesName: String? = nil,
            sourceSubscriptionID: UUID? = nil
        ) {
            self.title = title
            self.course = course
            self.language = language
            self.capturedAt = capturedAt
            self.sourceProviderRaw = sourceProviderRaw
            self.sourceKey = sourceKey
            self.sourcePageURL = sourcePageURL
            self.sourceMediaURL = sourceMediaURL
            self.sourceTeacherName = sourceTeacherName
            self.sourceSeriesName = sourceSeriesName
            self.sourceSubscriptionID = sourceSubscriptionID
        }
    }

    private let modelContainer: ModelContainer
    private let recordingsDirectory: URL
    private let recordingLedger: RecordingFileLedger

    init(modelContainer: ModelContainer, recordingsDirectory: URL? = nil) {
        self.modelContainer = modelContainer
        if let recordingsDirectory {
            self.recordingsDirectory = recordingsDirectory
        } else {
            let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            self.recordingsDirectory = support.appendingPathComponent("Lectern/Recordings", isDirectory: true)
        }
        self.recordingLedger = RecordingFileLedger(recordingsDirectory: self.recordingsDirectory)
        try? FileManager.default.createDirectory(at: self.recordingsDirectory, withIntermediateDirectories: true)
    }

    /// Imports an audio file into Lectern's managed recordings directory and creates Lecture + Recording.
    @discardableResult
    func importAudio(
        from sourceURL: URL,
        metadata: ImportMetadata,
        moveSource: Bool = false
    ) throws -> Lecture {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: sourceURL.path) else {
            throw CaptureError.importFailed("The file couldn't be found.")
        }

        let stamp = Self.fileStampFormatter.string(from: Date())
        let ext = sourceURL.pathExtension.isEmpty ? "mp3" : sourceURL.pathExtension
        let destinationURL = recordingsDirectory
            .appendingPathComponent("Imported \(stamp).\(ext)")

        do {
            if moveSource {
                try fileManager.moveItem(at: sourceURL, to: destinationURL)
            } else {
                try fileManager.copyItem(at: sourceURL, to: destinationURL)
            }
        } catch {
            throw CaptureError.importFailed("Couldn't store the audio file: \(error.localizedDescription)")
        }

        let audioFile: AVAudioFile
        do {
            audioFile = try AVAudioFile(forReading: destinationURL)
        } catch {
            try? fileManager.removeItem(at: destinationURL)
            throw CaptureError.importFailed("This file isn't readable audio: \(error.localizedDescription)")
        }

        let actualSampleRate = audioFile.processingFormat.sampleRate
        let duration = Double(audioFile.length) / (actualSampleRate > 0 ? actualSampleRate : 16_000)
        let attributes = try? destinationURL.resourceValues(forKeys: [.fileSizeKey])
        let sizeBytes = Int64(attributes?.fileSize ?? 0)

        // Important retention detail:
        // Lecture.capturedAt: represents original shiur date / creation date
        // Recording.recordedAt: represents LOCAL import date (Date()) for retention
        let capturedAt = metadata.capturedAt
            ?? (try? sourceURL.resourceValues(forKeys: [.creationDateKey]))?.creationDate
            ?? Date()
        let localImportTime = Date()

        let course = metadata.course
        let title = metadata.title ?? sourceURL.deletingPathExtension().lastPathComponent
        let language = metadata.language ?? course?.language ?? .english

        let context = modelContainer.mainContext
        let lecture = Lecture(
            title: title,
            capturedAt: capturedAt,
            duration: duration,
            status: .recorded,
            language: language
        )
        lecture.course = course
        lecture.sourceProviderRaw = metadata.sourceProviderRaw
        lecture.sourceKey = metadata.sourceKey
        lecture.sourcePageURL = metadata.sourcePageURL
        lecture.sourceMediaURL = metadata.sourceMediaURL
        lecture.sourceTeacherName = metadata.sourceTeacherName
        lecture.sourceSeriesName = metadata.sourceSeriesName
        lecture.sourceImportedAt = localImportTime
        lecture.sourceSubscriptionID = metadata.sourceSubscriptionID

        lecture.recording = Recording(
            filePath: destinationURL.path,
            sampleRate: actualSampleRate,
            sizeBytes: sizeBytes,
            recordedAt: localImportTime
        )

        context.insert(lecture)
        recordingLedger.reclaim(filePath: destinationURL.path)
        try? context.save()

        return lecture
    }

    private static let fileStampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH.mm.ss"
        return formatter
    }()
}
