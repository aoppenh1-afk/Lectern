import AVFoundation
import Foundation
import Observation
import SwiftData

@MainActor
@Observable
final class ShiurAutomationService {
    private(set) var isChecking = false
    private(set) var activeItemIDs: Set<UUID> = []
    private(set) var lastCheckError: String?

    private let modelContainer: ModelContainer
    private let importService: LectureImportService
    private let downloader: RemoteAudioDownloader
    private let provider: any ShiurSourceProvider
    private let transcriptionService: TranscriptionService
    private let transcriptionPreferences: TranscriptionPreferences
    private let generationService: GenerationService
    private let completionNotifier: any CompletionNotifying

    private var activeSourceKeys: Set<String> = []

    private var activeSubscriptionIDs: Set<UUID> = []

    init(
        modelContainer: ModelContainer,
        importService: LectureImportService? = nil,
        downloader: RemoteAudioDownloader? = nil,
        provider: (any ShiurSourceProvider)? = nil,
        transcriptionService: TranscriptionService,
        transcriptionPreferences: TranscriptionPreferences,
        generationService: GenerationService,
        completionNotifier: any CompletionNotifying = SystemCompletionNotifier.shared
    ) {
        self.modelContainer = modelContainer
        self.importService = importService ?? LectureImportService(modelContainer: modelContainer)
        self.downloader = downloader ?? RemoteAudioDownloader()
        self.provider = provider ?? YUTorahSourceProvider()
        self.transcriptionService = transcriptionService
        self.transcriptionPreferences = transcriptionPreferences
        self.generationService = generationService
        self.completionNotifier = completionNotifier
    }

    // MARK: - Subscriptions Check

    func checkSubscriptions(dueOnly: Bool = true) async {
        guard !isChecking else { return }
        isChecking = true
        lastCheckError = nil
        defer { isChecking = false }

        let context = modelContainer.mainContext
        let descriptor = FetchDescriptor<ShiurSubscription>()
        let subscriptions = (try? context.fetch(descriptor)) ?? []

        let targets = subscriptions.filter { sub in
            guard sub.isEnabled else { return false }
            return !dueOnly || sub.isDue()
        }

        for subscription in targets {
            await checkSubscription(subscription, ignoreDue: true)
        }
    }

    func checkSubscription(_ subscription: ShiurSubscription, ignoreDue: Bool = false) async {
        guard !activeSubscriptionIDs.contains(subscription.id) else { return }
        if !ignoreDue && !subscription.isDue() { return }

        activeSubscriptionIDs.insert(subscription.id)
        defer { activeSubscriptionIDs.remove(subscription.id) }

        guard let feedURL = subscription.resolvedFeedURL else {
            subscription.lastError = "Missing or invalid feed URL."
            try? modelContainer.mainContext.save()
            return
        }

        subscription.lastCheckedAt = Date()

        let fetchResult: FeedFetchResult
        do {
            fetchResult = try await provider.fetchFeed(
                url: feedURL,
                eTag: subscription.eTag,
                lastModified: subscription.lastModified,
                maxResults: 100
            )
        } catch {
            subscription.lastError = "Feed fetch failed: \(error.localizedDescription)"
            try? modelContainer.mainContext.save()
            return
        }

        switch fetchResult {
        case .notModified:
            subscription.lastSuccessfulCheckAt = Date()
            subscription.lastError = nil
            try? modelContainer.mainContext.save()

        case .newItems(let items, let channelTitle, let eTag, let lastModified):
            let context = modelContainer.mainContext
            let previousSuccess = subscription.lastSuccessfulCheckAt
            let previousSeen = subscription.seenItemIDsData
            let isFirstCheck = previousSuccess == nil
            var seen = subscription.seenItemIDs
            // Feeds can contain duplicate entries and need not be newest-first.
            let orderedItems = items.sorted { $0.date > $1.date }
            let uniqueItems = orderedItems.filter {
                seen.insert($0.shiurID).inserted
            }
            let candidates = isFirstCheck
                ? (subscription.isBaselineFutureOnly ? [] : Array(uniqueItems.prefix(5)))
                : uniqueItems
            var pending: [ShiurAutomationItem] = []
            for remoteItem in candidates.reversed() {
                guard findExistingLecture(shiurID: remoteItem.shiurID) == nil,
                      findAutomationItem(sourceKey: remoteItem.sourceKey) == nil else { continue }
                let item = ShiurAutomationItem(
                    sourceKey: remoteItem.sourceKey,
                    shiurID: remoteItem.shiurID,
                    subscriptionID: subscription.id,
                    title: remoteItem.title,
                    teacherName: remoteItem.teacherName,
                    seriesName: remoteItem.seriesName,
                    publicationDate: remoteItem.date,
                    pageURLString: remoteItem.pageURL?.absoluteString,
                    mediaURLString: remoteItem.enclosureURL?.absoluteString,
                    duration: remoteItem.duration,
                    targetCourseIDData: subscription.course.flatMap {
                        try? JSONEncoder().encode($0.persistentModelID)
                    },
                    language: subscription.language,
                    autoTranscribe: subscription.autoTranscribe,
                    autoGenerateNotes: subscription.autoGenerateNotes
                )
                context.insert(item)
                pending.append(item)
            }

            subscription.markSeen(itemIDs: orderedItems.reversed().map(\.shiurID))
            subscription.lastSuccessfulCheckAt = Date()
            subscription.eTag = eTag
            subscription.lastModified = lastModified
            subscription.lastError = nil
            if let channelTitle, !channelTitle.isEmpty,
               subscription.displayName.starts(with: "YU Torah") || subscription.displayName.isEmpty {
                subscription.displayName = channelTitle
            }

            // Persist the entire queue with its feed checkpoint before starting any
            // download. A restart must not lose the remainder behind a cached ETag.
            do {
                try context.save()
            } catch {
                for item in pending { context.delete(item) }
                subscription.lastSuccessfulCheckAt = previousSuccess
                subscription.seenItemIDsData = previousSeen
                subscription.eTag = nil
                subscription.lastModified = nil
                subscription.lastError = "Could not save the import queue: \(error.localizedDescription)"
                lastCheckError = subscription.lastError
                return
            }
            for item in pending {
                await processItem(item, targetCourse: subscription.course)
            }
        }
    }

    // MARK: - Pipeline Processing

    func processItem(_ item: ShiurAutomationItem, targetCourse: Course? = nil) async {
        guard !activeItemIDs.contains(item.id) else { return }
        activeItemIDs.insert(item.id)
        defer { activeItemIDs.remove(item.id) }

        while activeSourceKeys.contains(item.sourceKey) {
            do { try await Task.sleep(for: .milliseconds(100)) }
            catch { return }
        }
        guard !Task.isCancelled else { return }
        activeSourceKeys.insert(item.sourceKey)
        defer { activeSourceKeys.remove(item.sourceKey) }

        if let targetCourse {
            item.targetCourseIDData = try? JSONEncoder().encode(targetCourse.persistentModelID)
        }
        let course = targetCourse ?? resolvedCourse(for: item)
        if item.state == .imported ||
            ((item.state == .discovered || item.state == .downloading) && findExistingLecture(shiurID: item.shiurID) != nil) {
            item.state = item.autoTranscribe ? .waitingForTranscription : .complete
            item.stateMessage = nil
            try? modelContainer.mainContext.save()
        }

        if item.state == .discovered || item.state == .downloading {
            do {
                _ = try await downloadAndImportLecture(for: item, course: course, remoteItem: RemoteShiurItem(
                    shiurID: item.shiurID,
                    title: item.title,
                    teacherName: item.teacherName,
                    seriesName: item.seriesName,
                    date: item.publicationDate,
                    duration: item.duration,
                    pageURL: item.pageURL,
                    enclosureURL: item.mediaURL
                ))
            } catch {
                return
            }
        }

        // 3. Transcription
        if item.state == .waitingForTranscription || item.state == .transcribing {
            guard let lecture = findExistingLecture(shiurID: item.shiurID) else {
                item.state = .failed
                item.stateMessage = "Associated lecture was deleted."
                try? modelContainer.mainContext.save()
                return
            }

            if lecture.hasCompletedRawTranscript {
                // Transcript already exists
                item.state = item.autoGenerateNotes ? .waitingForNotes : .complete
                try? modelContainer.mainContext.save()
            } else {
                if transcriptionPreferences.source == .askEachTime {
                    item.state = .failed
                    item.stateMessage = "Automatic transcription requires a default transcriber. Choose one in Settings › Transcription."
                    try? modelContainer.mainContext.save()
                    return
                }

                item.state = .transcribing
                try? modelContainer.mainContext.save()

                transcriptionService.enqueue(lectureID: lecture.persistentModelID)

                // Wait for transcription to finish
                while transcriptionService.isQueuedOrRunning(lectureID: lecture.persistentModelID) {
                    do { try await Task.sleep(for: .milliseconds(250)) }
                    catch { return }
                }

                if lecture.status == .failed {
                    item.state = .failed
                    item.stateMessage = lecture.statusMessage ?? "Transcription failed."
                    try? modelContainer.mainContext.save()
                    return
                }

                if lecture.hasCompletedRawTranscript {
                    item.state = item.autoGenerateNotes ? .waitingForNotes : .complete
                    item.stateMessage = nil
                    try? modelContainer.mainContext.save()
                } else {
                    item.state = .failed
                    item.stateMessage = lecture.statusMessage ?? "Transcription stopped before a complete transcript was saved."
                    try? modelContainer.mainContext.save()
                    return
                }
            }
        }

        // 4. Notes Generation
        if item.state == .waitingForNotes || item.state == .generatingNotes {
            guard let lecture = findExistingLecture(shiurID: item.shiurID) else {
                item.state = .failed
                item.stateMessage = "Associated lecture was deleted."
                try? modelContainer.mainContext.save()
                return
            }

            if lecture.artifact(of: .notes) != nil {
                item.state = .complete
                item.stateMessage = nil
                try? modelContainer.mainContext.save()
                return
            }

            item.state = .generatingNotes
            try? modelContainer.mainContext.save()

            let profileID = UserDefaults.standard.string(forKey: "generation.agentID") ?? AgentProfiles.codexID
            guard let profile = AgentProfiles.profile(id: profileID) else {
                item.state = .failed
                item.stateMessage = "Default study agent is not configured. Set one in Settings › Agents."
                try? modelContainer.mainContext.save()
                return
            }

            let thinkingLevelRaw = UserDefaults.standard.string(forKey: "generation.thinkingLevel")
                ?? ThinkingLevel.medium.rawValue
            let thinkingLevel = ThinkingLevel(rawValue: thinkingLevelRaw) ?? .medium

            do {
                try await generationService.generateDirectly(
                    lecture: lecture,
                    kinds: [.cleanedTranscript, .notes],
                    profile: profile,
                    thinkingLevel: thinkingLevel,
                    modelOverride: profile.model
                )
                item.state = .complete
                item.stateMessage = nil
                try? modelContainer.mainContext.save()
            } catch {
                item.state = .failed
                item.stateMessage = "Clean up & note taking failed: \(error.localizedDescription)"
                try? modelContainer.mainContext.save()
            }
        }
    }

    // MARK: - Download + Import Stage

    /// Downloads remote audio and creates the Lecture placecard.
    /// Caller must hold `activeSourceKeys` for `item.sourceKey`.
    /// On success sets item to `.waitingForTranscription`/`.complete` and returns the Lecture.
    /// On failure marks item `.failed` and throws the underlying error.
    private func downloadAndImportLecture(
        for item: ShiurAutomationItem,
        course: Course?,
        remoteItem: RemoteShiurItem
    ) async throws -> Lecture {
        // Race: lecture appeared while waiting on activeSourceKeys.
        if let existing = findExistingLecture(shiurID: item.shiurID) {
            item.state = item.autoTranscribe ? .waitingForTranscription : .complete
            item.stateMessage = nil
            try? modelContainer.mainContext.save()
            return existing
        }

        item.state = .downloading
        item.lastAttemptAt = Date()
        item.downloadAttempts += 1
        try? modelContainer.mainContext.save()

        let mediaURL: URL
        do {
            mediaURL = try await provider.resolveMediaURL(for: remoteItem)
        } catch {
            item.state = .failed
            item.stateMessage = "Media resolution failed: \(error.localizedDescription)"
            try? modelContainer.mainContext.save()
            throw error
        }

        let downloadedFile: URL
        do {
            downloadedFile = try await downloader.download(
                from: mediaURL,
                filenameStem: "\(item.shiurID)-\(item.title)"
            )
        } catch {
            item.state = .failed
            item.stateMessage = "Download failed: \(error.localizedDescription)"
            try? modelContainer.mainContext.save()
            throw error
        }

        let lecture: Lecture
        do {
            lecture = try importService.importAudio(
                from: downloadedFile,
                metadata: .init(
                    title: item.title,
                    course: course,
                    language: item.language,
                    capturedAt: item.publicationDate,
                    sourceProviderRaw: "yutorah",
                    sourceKey: item.sourceKey,
                    sourcePageURL: item.pageURLString,
                    sourceMediaURL: mediaURL.absoluteString,
                    sourceTeacherName: item.teacherName,
                    sourceSeriesName: item.seriesName,
                    sourceSubscriptionID: item.subscriptionID
                ),
                moveSource: true
            )
        } catch {
            try? FileManager.default.removeItem(at: downloadedFile)
            item.state = .failed
            item.stateMessage = "Import failed: \(error.localizedDescription)"
            try? modelContainer.mainContext.save()
            throw error
        }

        if let subID = item.subscriptionID,
           let sub = findSubscription(id: subID) {
            sub.lastImportedAt = Date()
            sub.lastImportedTitle = item.title
            sub.importedCount += 1
        }

        item.state = item.autoTranscribe ? .waitingForTranscription : .complete
        try? modelContainer.mainContext.save()
        return lecture
    }

    func retryItem(_ item: ShiurAutomationItem) async {
        guard !activeItemIDs.contains(item.id), item.state == .failed || item.state == .paused else { return }
        if let lecture = findExistingLecture(shiurID: item.shiurID) {
            if lecture.hasCompletedRawTranscript {
                item.state = item.autoGenerateNotes ? .waitingForNotes : .complete
            } else {
                item.state = item.autoTranscribe ? .waitingForTranscription : .complete
            }
        } else {
            item.state = .discovered
        }
        item.stateMessage = nil
        do { try modelContainer.mainContext.save() }
        catch {
            item.state = .failed
            item.stateMessage = "Could not save retry: \(error.localizedDescription)"
            return
        }
        await processItem(item)
    }

    func dismissItem(_ item: ShiurAutomationItem) {
        guard !activeItemIDs.contains(item.id) else { return }
        modelContainer.mainContext.delete(item)
        try? modelContainer.mainContext.save()
    }

    func dismissFailedItems(_ items: [ShiurAutomationItem]) {
        let ids = activeItemIDs
        for item in items where item.state == .failed && !ids.contains(item.id) {
            modelContainer.mainContext.delete(item)
        }
        try? modelContainer.mainContext.save()
    }

    // MARK: - One-Time Shiur Import

    func importShiur(
        _ remoteItem: RemoteShiurItem,
        into course: Course?,
        language: LectureLanguage = .hebrewEnglish,
        autoTranscribe: Bool = true,
        autoGenerateNotes: Bool = true
    ) async throws -> Lecture {
        // Global deduplication: if already exists, return existing
        if let existing = findExistingLecture(shiurID: remoteItem.shiurID) {
            return existing
        }

        let automationItem = ShiurAutomationItem(
            sourceKey: remoteItem.sourceKey,
            shiurID: remoteItem.shiurID,
            subscriptionID: nil,
            title: remoteItem.title,
            teacherName: remoteItem.teacherName,
            seriesName: remoteItem.seriesName,
            publicationDate: remoteItem.date,
            pageURLString: remoteItem.pageURL?.absoluteString,
            mediaURLString: remoteItem.enclosureURL?.absoluteString,
            duration: remoteItem.duration,
            state: .discovered,
            language: language,
            autoTranscribe: autoTranscribe,
            autoGenerateNotes: autoGenerateNotes
        )
        if let course {
            automationItem.targetCourseIDData = try? JSONEncoder().encode(course.persistentModelID)
        }
        modelContainer.mainContext.insert(automationItem)
        try? modelContainer.mainContext.save()

        // Fast path: wait for any concurrent download of the same shiur, then
        // download + create the Lecture placecard synchronously so the UI can
        // dismiss with "import successful". Transcription + notes continue in
        // the background via processItem (failures surface under
        // "Imports needing attention").
        while activeSourceKeys.contains(automationItem.sourceKey) {
            do { try await Task.sleep(for: .milliseconds(100)) }
            catch { throw CancellationError() }
        }
        guard !Task.isCancelled else { throw CancellationError() }
        activeSourceKeys.insert(automationItem.sourceKey)
        let lecture: Lecture
        do {
            lecture = try await downloadAndImportLecture(
                for: automationItem,
                course: course,
                remoteItem: remoteItem
            )
            activeSourceKeys.remove(automationItem.sourceKey)
        } catch {
            activeSourceKeys.remove(automationItem.sourceKey)
            throw error
        }

        // Background continuation: transcription + notes. processItem skips the
        // download stage because the lecture now exists.
        if automationItem.state != .complete {
            Task {
                await processItem(automationItem, targetCourse: course)
            }
        }

        return lecture
    }

    // MARK: - Redownload Audio

    func redownloadAudio(for lecture: Lecture) async throws {
        guard let sourceKey = lecture.sourceKey,
              let shiurID = sourceKey.split(separator: ":").last.map(String.init) else {
            throw NSError(domain: "ShiurAutomationService", code: -1, userInfo: [NSLocalizedDescriptionKey: "No source shiur ID available."])
        }

        let remoteItem = RemoteShiurItem(
            shiurID: shiurID,
            title: lecture.title,
            teacherName: lecture.sourceTeacherName,
            seriesName: lecture.sourceSeriesName,
            date: lecture.capturedAt,
            pageURL: lecture.sourcePageURL.flatMap(URL.init(string:)),
            enclosureURL: lecture.sourceMediaURL.flatMap(URL.init(string:))
        )

        let mediaURL = try await provider.resolveMediaURL(for: remoteItem)
        let downloadedFile = try await downloader.download(
            from: mediaURL,
            filenameStem: "\(shiurID)-\(lecture.title)"
        )

        let recordingsDir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Lectern/Recordings", isDirectory: true)
        let dest = recordingsDir.appendingPathComponent("Redownload-\(shiurID).\(downloadedFile.pathExtension)")

        if FileManager.default.fileExists(atPath: dest.path) {
            try? FileManager.default.removeItem(at: dest)
        }
        try FileManager.default.moveItem(at: downloadedFile, to: dest)

        let audioFile = try AVAudioFile(forReading: dest)
        let sampleRate = audioFile.processingFormat.sampleRate
        let sizeBytes = Int64((try? dest.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0)

        if let recording = lecture.recording {
            recording.filePath = dest.path
            recording.sampleRate = sampleRate
            recording.sizeBytes = sizeBytes
            recording.recordedAt = Date()
            recording.prunedAt = nil
        } else {
            let recording = Recording(
                filePath: dest.path,
                sampleRate: sampleRate,
                sizeBytes: sizeBytes,
                recordedAt: Date()
            )
            recording.lecture = lecture
            lecture.recording = recording
        }

        try? modelContainer.mainContext.save()
    }

    // MARK: - Startup Resume

    func resumePendingItems() {
        downloader.sweepStaleDownloads()

        let context = modelContainer.mainContext
        let descriptor = FetchDescriptor<ShiurAutomationItem>()
        let items = (try? context.fetch(descriptor)) ?? []

        for item in items where !item.state.isTerminal && item.state != .paused && item.state != .failed {
            Task {
                await self.processItem(item)
            }
        }
    }

    // MARK: - Lookup Helpers

    func findExistingLecture(shiurID: String) -> Lecture? {
        let key = "yutorah:\(shiurID)"
        let context = modelContainer.mainContext
        var descriptor = FetchDescriptor<Lecture>(predicate: #Predicate { $0.sourceKey == key })
        descriptor.fetchLimit = 1
        return try? context.fetch(descriptor).first
    }

    private func findAutomationItem(sourceKey: String) -> ShiurAutomationItem? {
        var descriptor = FetchDescriptor<ShiurAutomationItem>(predicate: #Predicate { $0.sourceKey == sourceKey })
        descriptor.fetchLimit = 1
        return try? modelContainer.mainContext.fetch(descriptor).first
    }

    private func resolvedCourse(for item: ShiurAutomationItem) -> Course? {
        if let data = item.targetCourseIDData,
           let id = try? JSONDecoder().decode(PersistentIdentifier.self, from: data),
           let course = modelContainer.mainContext.model(for: id) as? Course,
           !course.isDeleted { return course }
        return item.subscriptionID.flatMap { findSubscription(id: $0)?.course }
    }

    private func findSubscription(id: UUID) -> ShiurSubscription? {
        let context = modelContainer.mainContext
        var descriptor = FetchDescriptor<ShiurSubscription>(predicate: #Predicate { $0.id == id })
        descriptor.fetchLimit = 1
        return try? context.fetch(descriptor).first
    }
}
