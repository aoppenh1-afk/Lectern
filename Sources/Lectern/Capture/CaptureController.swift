import AVFoundation
import Observation
import SwiftData
import SwiftUI

/// Owns the lecture capture state machine: permission, engine, WAV pipeline,
/// and the Lecture/Recording rows created when a capture stops.
@MainActor
@Observable
final class CaptureController {
    struct PendingBookmark: Identifiable {
        let id = UUID()
        let createdAt: Date
        let offset: TimeInterval
        let note: String
        let isExamAlert: Bool
    }
    enum Phase {
        case idle
        case requestingPermission
        case recording(startedAt: Date)
        case saving

        var isLive: Bool {
            switch self {
            case .requestingPermission, .recording, .saving: return true
            case .idle: return false
            }
        }
    }

    private(set) var phase: Phase = .idle
    private(set) var errorMessage: String?
    private(set) var liveBookmarks: [PendingBookmark] = []

    /// Invoked whenever the phase machine changes state (for UI surfaces
    /// like the notch pill).
    var phaseChangeHandler: (() -> Void)? {
        didSet { phaseChangeHandler?() }
    }

    private func notifyPhaseChange() {
        phaseChangeHandler?()
    }

    /// Menu-bar / global-hotkey entry point: start if idle, stop if live.
    func toggle() {
        toggle(in: activeCourse)
    }

    /// Start/stop a capture, filing the resulting lecture into `course`.
    /// `language` overrides the course's default (nil inherits it).
    func toggle(in course: Course?, language: LectureLanguage? = nil) {
        switch phase {
        case .idle:
            Task { await start(in: course, language: language) }
        case .recording:
            stop()
        case .requestingPermission, .saving:
            break
        }
    }

    /// Imports an existing audio file as a lecture. Transcription starts only
    /// when the user requests it from the lecture.
    func importAudio(at sourceURL: URL, into course: Course?, language: LectureLanguage? = nil) throws {
        try importService.importAudio(
            from: sourceURL,
            metadata: .init(
                course: course,
                language: language
            ),
            moveSource: false
        )
    }

    private let modelContainer: ModelContainer
    private let engine = AVAudioEngine()
    private let recordingsDirectory: URL
    private let recordingLedger: RecordingFileLedger
    private let importService: LectureImportService

    private var pipeline: CapturePipeline?
    private var activeCourse: Course?
    private var activeLanguage: LectureLanguage = .english

    init(modelContainer: ModelContainer) {
        self.modelContainer = modelContainer

        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        recordingsDirectory = support.appendingPathComponent("Lectern/Recordings", isDirectory: true)
        recordingLedger = RecordingFileLedger(recordingsDirectory: recordingsDirectory)
        importService = LectureImportService(modelContainer: modelContainer, recordingsDirectory: recordingsDirectory)

        try? FileManager.default.createDirectory(at: recordingsDirectory,
                                                withIntermediateDirectories: true)
    }

    /// Removes the lecture's audio from disk and records the filename so launch
    /// recovery cannot resurrect it as a "Recovered" lecture.
    func discardLectureRecording(_ lecture: Lecture) {
        if let path = lecture.recording?.filePath {
            recordingLedger.discard(filePath: path)
        }
    }

    // MARK: - Lifecycle

    func start(in course: Course?, language: LectureLanguage? = nil) async {
        guard case .idle = phase else { return }
        activeLanguage = language ?? course?.language ?? .english
        errorMessage = nil
        phase = .requestingPermission
        notifyPhaseChange()

        guard await Self.microphoneAccessGranted() else {
            phase = .idle
            errorMessage = "Microphone access is off. Allow it in System Settings › Privacy & Security › Microphone."
            notifyPhaseChange()
            return
        }

        do {
            try beginCapture(course: course)
        } catch {
            pipeline?.abort()
            pipeline = nil
            engine.inputNode.removeTap(onBus: 0)
            phase = .idle
            errorMessage = "Couldn't start capture: \(error.localizedDescription)"
            notifyPhaseChange()
        }
    }

    func stop() {
        guard case .recording(let startedAt) = phase else { return }
        phase = .saving
        notifyPhaseChange()

        engine.inputNode.removeTap(onBus: 0)
        engine.stop()

        let finishedPipeline = pipeline
        pipeline = nil
        let course = activeCourse
        activeCourse = nil
        let language = activeLanguage
        activeLanguage = .english

        guard let finishedPipeline else {
            phase = .idle
            liveBookmarks = []
            notifyPhaseChange()
            return
        }

        switch finishedPipeline.finish() {
        case .success(let (fileURL, totalBytes)):
            persistLecture(startedAt: startedAt,
                           duration: Date().timeIntervalSince(startedAt),
                           fileURL: fileURL,
                           sizeBytes: totalBytes,
                           course: course,
                           language: language)
        case .failure(let error):
            errorMessage = "Capture failed while saving: \(error.localizedDescription)"
        }
        phase = .idle
        liveBookmarks = []
        notifyPhaseChange()
    }

    /// Drops a timestamp against the active recording. Option-Command-B adds
    /// a plain bookmark; recording surfaces can attach a note or exam flag.
    @discardableResult
    func addBookmark(note: String = "", isExamAlert: Bool = false) -> Bool {
        guard case .recording(let startedAt) = phase else { return false }
        let trimmed = note.trimmingCharacters(in: .whitespacesAndNewlines)
        liveBookmarks.append(PendingBookmark(
            createdAt: Date(),
            offset: Date().timeIntervalSince(startedAt),
            note: trimmed,
            isExamAlert: isExamAlert
        ))
        notifyPhaseChange()
        return true
    }

    /// On launch, adopts any WAV left behind by a crash mid-lecture.
    func recoverUnclaimedRecordings() {
        guard !phase.isLive else { return }

        let context = modelContainer.mainContext
        let existing = (try? context.fetch(FetchDescriptor<Recording>())) ?? []
        let claimedPaths = Set(existing.map(\.filePath))
        let candidates = recordingLedger.recoverCandidates(claimedPaths: claimedPaths)
        guard !candidates.isEmpty else { return }

        for candidate in candidates {
            let lecture = Lecture(
                title: "Recovered · \(Self.displayFormatter.string(from: candidate.capturedAt))",
                capturedAt: candidate.capturedAt,
                status: .recorded
            )
            lecture.recording = Recording(filePath: candidate.url.path,
                                          sampleRate: 16_000,
                                          sizeBytes: candidate.sizeBytes,
                                          recordedAt: candidate.capturedAt)
            context.insert(lecture)
            recordingLedger.reclaim(filePath: candidate.url.path)
        }

        try? context.save()
    }

    // MARK: - Elapsed time for UI

    var elapsedInterval: TimeInterval {
        if case .recording(let startedAt) = phase {
            return Date().timeIntervalSince(startedAt)
        }
        return 0
    }

    /// Course shown in the popover while a capture is live.
    var activeCourseName: String? {
        phase.isLive ? activeCourse?.name : nil
    }

    // MARK: - Internals

    private func beginCapture(course: Course?) throws {
        let sourceFormat = engine.inputNode.outputFormat(forBus: 0)
        guard sourceFormat.sampleRate > 0, sourceFormat.channelCount > 0 else {
            throw CaptureError.noInputHardware
        }

        let stamp = Self.fileStampFormatter.string(from: Date())
        let destinationURL = recordingsDirectory.appendingPathComponent("Lecture \(stamp).wav")
        let newPipeline = try CapturePipeline(sourceFormat: sourceFormat, destinationURL: destinationURL)

        // The tap fires on AVFAudio's realtime render thread, NOT the main
        // actor. The handler must be @Sendable/nonisolated or the runtime
        // asserts the wrong queue and traps.
        let tapHandler: @Sendable (AVAudioPCMBuffer, AVAudioTime) -> Void = { [newPipeline] buffer, _ in
            newPipeline.ingest(buffer)
        }
        engine.inputNode.installTap(onBus: 0, bufferSize: 4096, format: sourceFormat,
                                    block: tapHandler)
        engine.prepare()
        try engine.start()

        pipeline = newPipeline
        liveBookmarks = []
        activeCourse = course
        phase = .recording(startedAt: Date())
        notifyPhaseChange()
    }

    @discardableResult
    private func persistLecture(startedAt: Date, duration: TimeInterval, fileURL: URL, sizeBytes: Int64, course: Course?, language: LectureLanguage, title overrideTitle: String? = nil) -> Lecture {
        let context = modelContainer.mainContext

        let baseTitle = course.map { "\($0.name) · " } ?? ""
        let title = overrideTitle ?? "\(baseTitle)\(Self.displayFormatter.string(from: startedAt))"

        // Saving a recording is intentionally independent from transcription.
        // The user may close the laptop now and transcribe later.
        let lecture = Lecture(title: title,
                              capturedAt: startedAt,
                              duration: duration,
                              status: .recorded,
                              language: language)
        lecture.course = course
        lecture.recording = Recording(filePath: fileURL.path,
                                      sampleRate: 16_000,
                                      sizeBytes: sizeBytes,
                                      recordedAt: startedAt)
        for pending in liveBookmarks {
            let bookmark = LiveBookmark(offset: pending.offset,
                                        note: pending.note,
                                        isExamAlert: pending.isExamAlert)
            bookmark.createdAt = pending.createdAt
            bookmark.lecture = lecture
            lecture.bookmarks.append(bookmark)
        }
        context.insert(lecture)
        recordingLedger.reclaim(filePath: fileURL.path)
        try? context.save()
        return lecture
    }

    private static func microphoneAccessGranted() async -> Bool {
        await withCheckedContinuation { continuation in
            AVAudioApplication.requestRecordPermission { granted in
                continuation.resume(returning: granted)
            }
        }
    }

    private static let displayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()

    private static let fileStampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH.mm.ss"
        return formatter
    }()
}
