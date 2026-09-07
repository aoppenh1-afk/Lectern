import AVFoundation
import CoreGraphics
import Observation
import ScreenCaptureKit
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
    private(set) var activeSource: CaptureSource = .microphone

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
    /// `source` overrides the Settings default (nil inherits it).
    func toggle(in course: Course?, language: LectureLanguage? = nil, source: CaptureSource? = nil) {
        switch phase {
        case .idle:
            Task { await start(in: course, language: language, source: source) }
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

    private var micPipeline: CapturePipeline?
    private var systemPipeline: CapturePipeline?
    private var systemCapture: SystemAudioCapture?
    private var microphoneTapInstalled = false
    private var destinationURL: URL?
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

    func start(in course: Course?, language: LectureLanguage? = nil, source: CaptureSource? = nil) async {
        guard case .idle = phase else { return }
        let resolvedSource = source ?? CaptureSource.preferred
        activeLanguage = language ?? course?.language ?? .english
        activeSource = resolvedSource
        errorMessage = nil
        phase = .requestingPermission
        notifyPhaseChange()

        if resolvedSource.includesMicrophone {
            guard await Self.microphoneAccessGranted() else {
                phase = .idle
                errorMessage = "Microphone access is off. Allow it in System Settings › Privacy & Security › Microphone."
                notifyPhaseChange()
                return
            }
        }

        if resolvedSource.includesSystemAudio {
            guard await Self.systemAudioAccessGranted() else {
                phase = .idle
                errorMessage = CaptureError.systemAudioDenied.localizedDescription
                notifyPhaseChange()
                return
            }
        }

        do {
            try await beginCapture(course: course, source: resolvedSource)
        } catch {
            await abortLiveCapture()
            phase = .idle
            errorMessage = Self.startFailureMessage(error)
            notifyPhaseChange()
        }
    }

    func stop() {
        guard case .recording(let startedAt) = phase else { return }
        phase = .saving
        notifyPhaseChange()

        stopMicrophone()

        let finishedMic = micPipeline
        let finishedSystem = systemPipeline
        let runningSystemCapture = systemCapture
        let mixedDestination = destinationURL
        let course = activeCourse
        let language = activeLanguage
        let source = activeSource
        micPipeline = nil
        systemPipeline = nil
        systemCapture = nil
        destinationURL = nil
        activeCourse = nil
        activeLanguage = .english

        Task {
            await runningSystemCapture?.stop()
            persistFinishedCapture(
                startedAt: startedAt,
                source: source,
                micPipeline: finishedMic,
                systemPipeline: finishedSystem,
                mixedDestination: mixedDestination,
                course: course,
                language: language
            )
        }
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

        let adopted = RecordingFileLedger.collapseRecoveryCandidates(candidates)
        let adoptedPaths = Set(adopted.map { $0.url.standardizedFileURL.path })
        for leftover in candidates where !adoptedPaths.contains(leftover.url.standardizedFileURL.path) {
            recordingLedger.discard(filePath: leftover.url.path)
        }
        for candidate in adopted {
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

    var liveStatusTitle: String {
        switch activeSource {
        case .microphone: return "Recording"
        case .systemAudio: return MeetingAudioTarget.isZoomRunning ? "Recording Zoom" : "Recording system audio"
        case .mixed: return MeetingAudioTarget.isZoomRunning ? "Recording Zoom + mic" : "Recording system audio + mic"
        }
    }

    // MARK: - Internals

    private func beginCapture(course: Course?, source: CaptureSource) async throws {
        let stamp = Self.fileStampFormatter.string(from: Date())
        let baseName = "Lecture \(stamp)"
        destinationURL = recordingsDirectory.appendingPathComponent("\(baseName).wav")

        if source.includesSystemAudio {
            let url = source == .mixed
                ? recordingsDirectory.appendingPathComponent("\(baseName)-system.wav")
                : destinationURL!
            let pipeline = try CapturePipeline(
                sourceFormat: SystemAudioCapture.expectedFormat,
                destinationURL: url
            )
            let capture = SystemAudioCapture()
            capture.onBuffer = { [pipeline] buffer in
                pipeline.ingest(buffer)
            }
            capture.onFailure = { [weak self] error in
                Task { @MainActor in
                    self?.handleSystemCaptureFailure(error)
                }
            }
            try await capture.start()
            systemPipeline = pipeline
            systemCapture = capture
        }

        if source.includesMicrophone {
            let url = source == .mixed
                ? recordingsDirectory.appendingPathComponent("\(baseName)-mic.wav")
                : destinationURL!
            try startMicrophone(destinationURL: url)
        }

        liveBookmarks = []
        activeCourse = course
        phase = .recording(startedAt: Date())
        notifyPhaseChange()
    }

    private func startMicrophone(destinationURL: URL) throws {
        let sourceFormat = engine.inputNode.outputFormat(forBus: 0)
        guard sourceFormat.sampleRate > 0, sourceFormat.channelCount > 0 else {
            throw CaptureError.noInputHardware
        }

        let newPipeline = try CapturePipeline(sourceFormat: sourceFormat, destinationURL: destinationURL)
        let tapHandler: @Sendable (AVAudioPCMBuffer, AVAudioTime) -> Void = { [newPipeline] buffer, _ in
            newPipeline.ingest(buffer)
        }
        engine.inputNode.installTap(onBus: 0, bufferSize: 4096, format: sourceFormat,
                                    block: tapHandler)
        microphoneTapInstalled = true
        engine.prepare()
        try engine.start()
        micPipeline = newPipeline
    }

    private func stopMicrophone() {
        if microphoneTapInstalled {
            engine.inputNode.removeTap(onBus: 0)
            microphoneTapInstalled = false
        }
        if engine.isRunning {
            engine.stop()
        }
    }

    private func abortLiveCapture() async {
        stopMicrophone()
        micPipeline?.abort()
        systemPipeline?.abort()
        micPipeline = nil
        systemPipeline = nil
        let capture = systemCapture
        systemCapture = nil
        destinationURL = nil
        await capture?.stop()
    }

    private func handleSystemCaptureFailure(_ error: Error) {
        guard case .recording = phase else { return }
        errorMessage = "System audio capture stopped: \(error.localizedDescription)"
        notifyPhaseChange()
    }

    private func persistFinishedCapture(
        startedAt: Date,
        source: CaptureSource,
        micPipeline: CapturePipeline?,
        systemPipeline: CapturePipeline?,
        mixedDestination: URL?,
        course: Course?,
        language: LectureLanguage
    ) {
        let micResult = micPipeline?.finish()
        let systemResult = systemPipeline?.finish()

        let fileURL: URL
        let sizeBytes: Int64

        do {
            switch source {
            case .microphone:
                let finished = try finishedPair(micResult)
                fileURL = finished.url
                sizeBytes = finished.size
            case .systemAudio:
                let finished = try finishedPair(systemResult)
                fileURL = finished.url
                sizeBytes = finished.size
            case .mixed:
                guard let destination = mixedDestination else {
                    throw CaptureError.mixdownFailed("Missing mix destination.")
                }
                let mic = try finishedPair(micResult)
                let system = try finishedPair(systemResult)
                sizeBytes = try WAVMixdown.mix(urls: [system.url, mic.url], destination: destination)
                fileURL = destination
                try? FileManager.default.removeItem(at: mic.url)
                try? FileManager.default.removeItem(at: system.url)
            }
        } catch {
            errorMessage = "Capture failed while saving: \(error.localizedDescription)"
            phase = .idle
            liveBookmarks = []
            notifyPhaseChange()
            return
        }

        persistLecture(
            startedAt: startedAt,
            duration: Date().timeIntervalSince(startedAt),
            fileURL: fileURL,
            sizeBytes: sizeBytes,
            course: course,
            language: language
        )
        phase = .idle
        liveBookmarks = []
        notifyPhaseChange()
    }

    private func finishedPair(_ result: Result<(URL, Int64), Error>?) throws -> (url: URL, size: Int64) {
        guard let result else {
            throw CaptureError.mixdownFailed("The recording pipeline was missing.")
        }
        switch result {
        case .success(let pair):
            return (pair.0, pair.1)
        case .failure(let error):
            throw error
        }
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

    private static func systemAudioAccessGranted() async -> Bool {
        if CGPreflightScreenCaptureAccess() { return true }
        if CGRequestScreenCaptureAccess() { return true }
        do {
            _ = try await SCShareableContent.current
            return true
        } catch {
            return false
        }
    }

    private static func startFailureMessage(_ error: Error) -> String {
        if error is CaptureError {
            return error.localizedDescription
        }
        let nsError = error as NSError
        let text = nsError.localizedDescription
        if text.localizedCaseInsensitiveContains("declin")
            || text.localizedCaseInsensitiveContains("not authorized")
            || (text.localizedCaseInsensitiveContains("screen") && text.localizedCaseInsensitiveContains("denied")) {
            return CaptureError.systemAudioDenied.localizedDescription
        }
        return "Couldn't start capture: \(error.localizedDescription)"
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
