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
            subscription.lastSuccessfulCheckAt = Date()
            subscription.eTag = eTag
            subscription.lastModified = lastModified
            subscription.lastError = nil

            if let channelTitle, !channelTitle.isEmpty,
               subscription.displayName.starts(with: "YU Torah") || subscription.displayName.isEmpty {
                subscription.displayName = channelTitle
            }

            // Baseline check: if subscription has never seen any items yet, establish baseline
            if subscription.seenItemIDs.isEmpty {
                let allIDs = items.map(\.shiurID)
                subscription.markSeen(itemIDs: allIDs)
                try? modelContainer.mainContext.save()
                return
            }

            // Filter new items not seen by this subscription
            let newItems = items
                .filter { !subscription.hasSeen(itemID: $0.shiurID) }
                .sorted(by: { $0.date < $1.date }) // Process oldest to newest

            for remoteItem in newItems {
                subscription.markSeen(itemIDs: [remoteItem.shiurID])
                try? modelContainer.mainContext.save()

                if findExistingLecture(shiurID: remoteItem.shiurID) != nil {
                    subscription.lastImportedAt = Date()
                    subscription.lastImportedTitle = remoteItem.title
                    subscription.importedCount += 1
                    try? modelContainer.mainContext.save()
                    continue
                }

                let automationItem = ShiurAutomationItem(
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
                    state: .discovered,
                    language: subscription.language,
                    autoTranscribe: subscription.autoTranscribe,
                    autoGenerateNotes: subscription.autoGenerateNotes
                )
                modelContainer.mainContext.insert(automationItem)
                try? modelContainer.mainContext.save()

                await processItem(automationItem, targetCourse: subscription.course)
            }
        }
    }

    // MARK: - Pipeline Processing

    func processItem(_ item: ShiurAutomationItem, targetCourse: Course? = nil) async {
        guard !activeItemIDs.contains(item.id) else { return }
        activeItemIDs.insert(item.id)
        defer { activeItemIDs.remove(item.id) }

        if item.state == .discovered || item.state == .downloading {
            item.state = .downloading
            item.lastAttemptAt = Date()
            item.downloadAttempts += 1
            try? modelContainer.mainContext.save()

            let remoteItem = RemoteShiurItem(
                shiurID: item.shiurID,
                title: item.title,
                teacherName: item.teacherName,
                seriesName: item.seriesName,
                date: item.publicationDate,
                duration: item.duration,
                pageURL: item.pageURL,
                enclosureURL: item.mediaURL
            )

            let mediaURL: URL
            do {
                mediaURL = try await provider.resolveMediaURL(for: remoteItem)
            } catch {
                item.state = .failed
                item.stateMessage = "Media resolution failed: \(error.localizedDescription)"
                try? modelContainer.mainContext.save()
                return
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
                return
            }

            do {
                _ = try importService.importAudio(
                    from: downloadedFile,
                    metadata: .init(
                        title: item.title,
                        course: targetCourse,
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
                return
            }

            if let subID = item.subscriptionID,
               let sub = findSubscription(id: subID) {
                sub.lastImportedAt = Date()
                sub.lastImportedTitle = item.title
                sub.importedCount += 1
            }

            item.state = item.autoTranscribe ? .waitingForTranscription : .complete
            try? modelContainer.mainContext.save()
        }

        // 3. Transcription
        if item.state == .waitingForTranscription || item.state == .transcribing {
            guard let lecture = findExistingLecture(shiurID: item.shiurID) else {
                item.state = .failed
                item.stateMessage = "Associated lecture was deleted."
                try? modelContainer.mainContext.save()
                return
            }

            if lecture.artifact(of: .rawTranscript) != nil {
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
                while lecture.status == .transcribing {
                    try? await Task.sleep(for: .seconds(1))
                }

                if lecture.status == .failed {
                    item.state = .failed
                    item.stateMessage = lecture.statusMessage ?? "Transcription failed."
                    try? modelContainer.mainContext.save()
                    return
                }

                if lecture.status == .ready && lecture.artifact(of: .rawTranscript) != nil {
                    item.state = item.autoGenerateNotes ? .waitingForNotes : .complete
                    try? modelContainer.mainContext.save()
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
                item.stateMessage = "Notes generation failed: \(error.localizedDescription)"
                try? modelContainer.mainContext.save()
            }
        }
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
        modelContainer.mainContext.insert(automationItem)
        try? modelContainer.mainContext.save()

        await processItem(automationItem, targetCourse: course)

        if let created = findExistingLecture(shiurID: remoteItem.shiurID) {
            return created
        }

        throw NSError(
            domain: "ShiurAutomationService",
            code: -1,
            userInfo: [NSLocalizedDescriptionKey: automationItem.stateMessage ?? "Import failed."]
        )
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
        let descriptor = FetchDescriptor<Lecture>()
        let lectures = (try? context.fetch(descriptor)) ?? []
        return lectures.first(where: { $0.sourceKey == key })
    }

    private func findSubscription(id: UUID) -> ShiurSubscription? {
        let context = modelContainer.mainContext
        let descriptor = FetchDescriptor<ShiurSubscription>()
        let subscriptions = (try? context.fetch(descriptor)) ?? []
        return subscriptions.first(where: { $0.id == id })
    }
}
