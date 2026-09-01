import Foundation
import Observation
import SwiftData

/// Prunes lecture audio older than the configured retention window, keeping
/// transcripts/notes/cards/quizzes forever. Audio is never deleted before its
/// lecture has been transcribed.
@MainActor
@Observable
final class RetentionService {
    private let modelContainer: ModelContainer
    private var sweepTask: Task<Void, Never>?

    init(modelContainer: ModelContainer) {
        self.modelContainer = modelContainer
    }

    var retentionDays: Int {
        let stored = UserDefaults.standard.integer(forKey: "retentionDays")
        guard stored != 0 else { return 3 }
        return max(1, min(stored, 365))
    }

    /// Deletes eligible WAV files and marks their Recording rows pruned.
    @discardableResult
    func sweepNow() -> Int {
        let context = modelContainer.mainContext
        let recordings = (try? context.fetch(FetchDescriptor<Recording>())) ?? []

        guard let cutoff = Calendar.current.date(byAdding: .day,
                                                 value: -retentionDays,
                                                 to: Date()) else { return 0 }

        var prunedCount = 0
        for recording in recordings where recording.prunedAt == nil {
            guard recording.recordedAt < cutoff else { continue }

            // Protection rule: audio survives until its lecture transcribed.
            guard let lecture = recording.lecture,
                  lecture.artifact(of: .rawTranscript) != nil else { continue }

            if FileManager.default.fileExists(atPath: recording.filePath) {
                try? FileManager.default.removeItem(atPath: recording.filePath)
            }
            recording.prunedAt = Date()
            prunedCount += 1
        }

        if prunedCount > 0 {
            try? context.save()
        }
        return prunedCount
    }

    /// Launch-time sweep plus a light periodic cadence for long-running apps.
    func startPeriodicSweep(everyHours: Double = 6) {
        sweepTask?.cancel()
        sweepTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(everyHours * 3_600))
                guard !Task.isCancelled else { break }
                self?.sweepNow()
            }
        }
    }

    func stopPeriodicSweep() {
        sweepTask?.cancel()
        sweepTask = nil
    }
}
