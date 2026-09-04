import AppKit
import Foundation
import SQLite3
import SwiftData
import SwiftUI

@MainActor
final class LecternApplicationDelegate: NSObject, NSApplicationDelegate {
    private var statusBarController: StatusBarController?
    private var didFinishLaunching = false

    func configure(statusBarController: StatusBarController) {
        self.statusBarController = statusBarController
        if didFinishLaunching {
            statusBarController.installIfNeeded()
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        didFinishLaunching = true
        statusBarController?.installIfNeeded()
    }
}

enum LecternStoreLocation {
    private static let storeFileName = "Lectern.store"
    private static let requiredLegacyTables = ["ZCOURSE", "ZLECTURE"]

    static func preparedStoreURL(fileManager: FileManager = .default) throws -> URL {
        if let override = ProcessInfo.processInfo.environment["LECTERN_STORE_PATH"], !override.isEmpty {
            return URL(fileURLWithPath: override)
        }

        let applicationSupport = try fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let lecternDirectory = applicationSupport
            .appendingPathComponent("Lectern", isDirectory: true)
            .appendingPathComponent("Data", isDirectory: true)
        try fileManager.createDirectory(at: lecternDirectory, withIntermediateDirectories: true)

        let destination = lecternDirectory.appendingPathComponent(storeFileName)
        guard !fileManager.fileExists(atPath: destination.path) else { return destination }

        let legacyStore = applicationSupport.appendingPathComponent("default.store")
        let backupsDirectory = applicationSupport
            .appendingPathComponent("Lectern", isDirectory: true)
            .appendingPathComponent("Backups", isDirectory: true)
        let backupStores = ((try? fileManager.subpathsOfDirectory(atPath: backupsDirectory.path)) ?? [])
            .filter { $0.hasSuffix("default.store") }
            .map { backupsDirectory.appendingPathComponent($0) }
            .sorted { lhs, rhs in
                let leftDate = (try? lhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                let rightDate = (try? rhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                return leftDate > rightDate
            }

        if let source = ([legacyStore] + backupStores).first(where: legacyStoreContainsLecternData) {
            try copyStore(from: source, to: destination, fileManager: fileManager)
        }
        return destination
    }

    static func legacyStoreContainsLecternData(_ storeURL: URL) -> Bool {
        var database: OpaquePointer?
        guard sqlite3_open_v2(storeURL.path, &database, SQLITE_OPEN_READONLY, nil) == SQLITE_OK,
              let database else {
            if let database { sqlite3_close(database) }
            return false
        }
        defer { sqlite3_close(database) }

        let placeholders = requiredLegacyTables.map { _ in "?" }.joined(separator: ",")
        let sql = "SELECT COUNT(*) FROM sqlite_master WHERE type = 'table' AND name IN (\(placeholders))"
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
              let statement else { return false }
        defer { sqlite3_finalize(statement) }
        let transientDestructor = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        for (index, table) in requiredLegacyTables.enumerated() {
            sqlite3_bind_text(statement, Int32(index + 1), table, -1, transientDestructor)
        }
        return sqlite3_step(statement) == SQLITE_ROW
            && sqlite3_column_int(statement, 0) == requiredLegacyTables.count
    }

    private static func copyStore(from source: URL, to destination: URL, fileManager: FileManager) throws {
        try fileManager.copyItem(at: source, to: destination)

        let sourceWAL = URL(fileURLWithPath: source.path + "-wal")
        let destinationWAL = URL(fileURLWithPath: destination.path + "-wal")
        if fileManager.fileExists(atPath: sourceWAL.path),
           ((try? sourceWAL.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) > 0 {
            try fileManager.copyItem(at: sourceWAL, to: destinationWAL)
        }
    }
}

@main
struct LecternApp: App {
    @NSApplicationDelegateAdaptor(LecternApplicationDelegate.self)
    private var applicationDelegate

    let container: ModelContainer
    private let captureController: CaptureController
    private let transcriptionPreferences: TranscriptionPreferences
    private let transcriptionService: TranscriptionService
    private let generationService: GenerationService
    private let lectureChatService: LectureChatService
    private let courseSynthesisService: CourseSynthesisService
    private let cardSyncService: CardSyncService
    private let googleDocsAuth: GoogleDocsAuth
    private let googleDocsSync: GoogleDocsSyncService
    private let retentionService: RetentionService
    private let audioPlayer: LectureAudioPlayer
    private let surfacePreferences: SurfacePreferences
    private let pillController: PillWindowController
    private let statusBarController: StatusBarController
    private let canvasConnection: CanvasConnectionSettings
    private let canvasSync: CanvasSyncService
    private let canvasResourceOpener: CanvasResourceOpener
    private let appUpdater: AppUpdater
    private let onboardingState: OnboardingState
    private let notificationPreferences: NotificationPreferences
    private let remoteAudioDownloader: RemoteAudioDownloader
    private let lectureImportService: LectureImportService
    private let shiurAutomationService: ShiurAutomationService
    private let automationScheduler: AutomationScheduler

    init() {
        do {
            let schema = Schema([
                Course.self, Lecture.self, Recording.self,
                Artifact.self, Flashcard.self, QuizItem.self, ChatMessage.self,
                LiveBookmark.self, ReferenceAttachment.self,
                CanvasAssignment.self, CanvasEvent.self, CanvasResource.self,
                CanvasAnnouncement.self,
                ShiurSubscription.self, ShiurAutomationItem.self
            ])
            let storeURL = try LecternStoreLocation.preparedStoreURL()
            container = try ModelContainer(
                for: schema,
                configurations: [ModelConfiguration(url: storeURL)]
            )
        } catch {
            fatalError("Failed to create Lectern data store: \(error)")
        }
        captureController = CaptureController(modelContainer: container)
        transcriptionPreferences = TranscriptionPreferences()
        transcriptionService = TranscriptionService(
            modelContainer: container,
            preferences: transcriptionPreferences
        )
        generationService = GenerationService(modelContainer: container)
        lectureChatService = LectureChatService(modelContainer: container)
        courseSynthesisService = CourseSynthesisService()
        cardSyncService = CardSyncService(modelContainer: container)
        googleDocsAuth = GoogleDocsAuth()
        googleDocsSync = GoogleDocsSyncService(auth: googleDocsAuth, modelContainer: container)
        retentionService = RetentionService(modelContainer: container)
        audioPlayer = LectureAudioPlayer()
        surfacePreferences = SurfacePreferences()
        pillController = PillWindowController(capture: captureController,
                                              surfacePreferences: surfacePreferences)
        statusBarController = StatusBarController(capture: captureController,
                                                  surfacePreferences: surfacePreferences)
        canvasConnection = CanvasConnectionSettings()
        canvasSync = CanvasSyncService(modelContainer: container, connection: canvasConnection)
        canvasResourceOpener = CanvasResourceOpener(connection: canvasConnection)
        appUpdater = AppUpdater()
        onboardingState = OnboardingState()
        notificationPreferences = NotificationPreferences()

        let remoteAudioDownloader = RemoteAudioDownloader()
        self.remoteAudioDownloader = remoteAudioDownloader
        remoteAudioDownloader.sweepStaleDownloads()

        let lectureImportService = LectureImportService(modelContainer: container)
        self.lectureImportService = lectureImportService

        let shiurAutomationService = ShiurAutomationService(
            modelContainer: container,
            importService: lectureImportService,
            downloader: remoteAudioDownloader,
            transcriptionService: transcriptionService,
            transcriptionPreferences: transcriptionPreferences,
            generationService: generationService
        )
        self.shiurAutomationService = shiurAutomationService

        let automationScheduler = AutomationScheduler(automationService: shiurAutomationService)
        self.automationScheduler = automationScheduler
        automationScheduler.start()

        captureController.phaseChangeHandler = { [pillController, statusBarController] in
            pillController.refresh()
            statusBarController.refresh()
        }

        retentionService.startPeriodicSweep()
        GlobalRecordHotkey.install(
            onToggle: { [captureController] in captureController.toggle() },
            onBookmark: { [captureController] in
                _ = captureController.addBookmark()
            }
        )
        applicationDelegate.configure(statusBarController: statusBarController)
    }

    var body: some Scene {
        WindowGroup(id: "main") {
            SuperAppShellView()
                .ignoresSafeArea()
                .environment(captureController)
                .environment(transcriptionPreferences)
                .environment(transcriptionService)
                .environment(generationService)
                .environment(lectureChatService)
                .environment(courseSynthesisService)
                .environment(cardSyncService)
                .environment(googleDocsAuth)
                .environment(googleDocsSync)
                .environment(retentionService)
                .environment(audioPlayer)
                .environment(surfacePreferences)
                .environment(canvasConnection)
                .environment(canvasSync)
                .environment(canvasResourceOpener)
                .environment(appUpdater)
                .environment(onboardingState)
                .environment(notificationPreferences)
                .environment(shiurAutomationService)
                .preferredColorScheme(surfacePreferences.appearance.colorScheme)
                .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in
                    transcriptionService.cancelAll()
                    automationScheduler.stop()
                }
        }
        .modelContainer(container)
        .windowStyle(.hiddenTitleBar)
        .commands {
            CommandGroup(after: .appInfo) {
                Button("Check for Updates…") {
                    Task { await appUpdater.checkNow() }
                }
                .disabled(appUpdater.repository == nil)
            }

            CommandMenu("Capture") {
                Button(captureController.phase.isLive ? "Stop Recording" : "Start Recording") {
                    captureController.toggle()
                }
                .keyboardShortcut("r", modifiers: .command)

                Button("Drop Bookmark") {
                    captureController.addBookmark()
                }
                .keyboardShortcut("b", modifiers: [.option, .command])
                .disabled(!captureController.phase.isLive)
            }
        }

        Settings {
            SettingsView()
                .environment(surfacePreferences)
                .environment(googleDocsAuth)
                .environment(transcriptionPreferences)
                .environment(canvasConnection)
                .environment(canvasSync)
                .environment(appUpdater)
                .environment(onboardingState)
                .environment(notificationPreferences)
        }
        .modelContainer(container)
    }
}
