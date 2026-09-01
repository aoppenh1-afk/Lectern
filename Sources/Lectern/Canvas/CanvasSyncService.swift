import Foundation
import Observation
import SwiftData

@MainActor
@Observable
final class CanvasSyncService {
    enum Phase: Equatable {
        case idle
        case syncing
        case failed(String)
    }

    private let modelContainer: ModelContainer
    private let connection: CanvasConnectionSettings
    private let defaults = UserDefaults.standard
    private static let lastSyncKey = "canvas.lastSuccessfulSync"
    private static let lastSyncDataVersionKey = "canvas.lastSuccessfulSyncDataVersion"

    private(set) var phase: Phase = .idle
    private(set) var lastSyncAt: Date?
    private(set) var lastSyncedDataVersion: Int
    private(set) var lastWarnings: [String] = []

    init(modelContainer: ModelContainer, connection: CanvasConnectionSettings) {
        self.modelContainer = modelContainer
        self.connection = connection
        lastSyncAt = defaults.object(forKey: Self.lastSyncKey) as? Date
        lastSyncedDataVersion = defaults.integer(forKey: Self.lastSyncDataVersionKey)
    }

    var isSyncing: Bool { phase == .syncing }
    var errorMessage: String? {
        guard case .failed(let message) = phase else { return nil }
        return message
    }

    func syncIfNeeded(maxAge: TimeInterval = CanvasAutomaticSyncPolicy.maxAge) async {
        guard connection.isConnected, !isSyncing else { return }
        guard CanvasAutomaticSyncPolicy.shouldSync(
            lastSyncAt: lastSyncAt,
            lastSyncedDataVersion: lastSyncedDataVersion,
            maxAge: maxAge
        ) else { return }
        await syncNow()
    }

    func syncNow() async {
        guard !isSyncing else { return }
        phase = .syncing
        do {
            let credentials = try connection.credentials()
            let snapshot = try await CanvasClient(credentials: credentials).fetchSnapshot()
            try apply(snapshot)
            lastWarnings = snapshot.warnings
            let now = Date()
            lastSyncAt = now
            lastSyncedDataVersion = CanvasAutomaticSyncPolicy.dataVersion
            defaults.set(now, forKey: Self.lastSyncKey)
            defaults.set(lastSyncedDataVersion, forKey: Self.lastSyncDataVersionKey)
            phase = .idle
        } catch {
            lastWarnings = []
            phase = .failed(error.localizedDescription)
        }
    }

    func clearError() {
        if case .failed = phase { phase = .idle }
    }

    private func apply(_ snapshot: CanvasSnapshot) throws {
        let context = modelContainer.mainContext
        let allCourses = try context.fetch(FetchDescriptor<Course>())
        var coursesByCanvasID = Dictionary(uniqueKeysWithValues: allCourses.compactMap { course in
            course.canvasID.map { ($0, course) }
        })

        for remote in snapshot.courses {
            let course: Course
            if let existing = coursesByCanvasID[remote.id] {
                course = existing
            } else if let localMatch = allCourses.first(where: {
                $0.canvasID == nil && $0.name.compare(remote.name, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame
            }) {
                course = localMatch
            } else {
                course = Course(name: remote.name, colorHex: Self.color(for: remote.id))
                context.insert(course)
            }
            course.canvasID = remote.id
            course.name = remote.name
            course.courseCode = remote.courseCode
            course.termName = remote.term?.name
            course.syllabusHTML = remote.syllabusBody
            course.instructorName = remote.teachers?.compactMap(\.displayName).first
            course.currentScore = remote.enrollments?.compactMap(\.computedCurrentScore).first
            course.currentGrade = remote.enrollments?.compactMap(\.computedCurrentGrade).first
            course.canvasURL = remote.htmlURL
            course.canvasUpdatedAt = Date()
            coursesByCanvasID[remote.id] = course
        }

        let courseNames = Dictionary(uniqueKeysWithValues: snapshot.courses.map { ($0.id, $0.name) })
        let courseCodes = Dictionary(uniqueKeysWithValues: snapshot.courses.map { ($0.id, $0.courseCode) })

        let existingAssignments = try context.fetch(FetchDescriptor<CanvasAssignment>())
        var assignmentsByID = Dictionary(uniqueKeysWithValues: existingAssignments.map { ($0.canvasID, $0) })
        for remote in snapshot.assignments {
            guard let courseID = remote.courseID else { continue }
            let value = assignmentsByID[remote.id] ?? CanvasAssignment(
                canvasID: remote.id,
                courseCanvasID: courseID,
                courseName: courseNames[courseID] ?? "Course",
                title: remote.name
            )
            if assignmentsByID[remote.id] == nil { context.insert(value) }
            value.courseCanvasID = courseID
            value.courseName = courseNames[courseID] ?? value.courseName
            value.courseCode = courseCodes[courseID] ?? nil
            value.title = remote.name
            value.detailsHTML = remote.description
            value.dueAt = remote.dueAt
            value.lockAt = remote.lockAt
            value.pointsPossible = remote.pointsPossible
            value.htmlURL = remote.htmlURL
            value.submissionState = remote.submission?.workflowState
            value.score = remote.submission?.score
            value.grade = remote.submission?.grade
            value.isMissing = remote.submission?.missing ?? false
            value.isExcused = remote.submission?.excused ?? false
            value.syncedAt = Date()
            assignmentsByID[remote.id] = value
        }

        let existingEvents = try context.fetch(FetchDescriptor<CanvasEvent>())
        var eventsByID = Dictionary(uniqueKeysWithValues: existingEvents.map { ($0.canvasID, $0) })
        for remote in snapshot.events {
            guard let startAt = remote.startAt else { continue }
            let courseID = Self.courseID(from: remote.contextCode)
            let value = eventsByID[remote.id] ?? CanvasEvent(canvasID: remote.id, title: remote.title, startAt: startAt)
            if eventsByID[remote.id] == nil { context.insert(value) }
            value.courseCanvasID = courseID
            value.courseName = courseID.flatMap { courseNames[$0] }
            value.title = remote.title
            value.detailsHTML = remote.description
            value.startAt = startAt
            value.endAt = remote.endAt
            value.locationName = remote.locationName
            value.locationAddress = remote.locationAddress
            value.htmlURL = remote.htmlURL
            value.syncedAt = Date()
            eventsByID[remote.id] = value
        }

        let existingResources = try context.fetch(FetchDescriptor<CanvasResource>())
        var resourcesByKey = Dictionary(uniqueKeysWithValues: existingResources.map { ($0.syncKey, $0) })
        for module in snapshot.modules {
            guard let courseID = module.courseID else { continue }
            for item in module.items ?? [] where item.type != "SubHeader" {
                let key = "\(courseID):\(module.id):\(item.id)"
                let value = resourcesByKey[key] ?? CanvasResource(
                    syncKey: key,
                    courseCanvasID: courseID,
                    courseName: courseNames[courseID] ?? "Course",
                    moduleName: module.name,
                    title: item.title,
                    kind: item.type,
                    position: item.position ?? 0
                )
                if resourcesByKey[key] == nil { context.insert(value) }
                value.canvasID = item.contentID ?? item.id
                value.courseName = courseNames[courseID] ?? value.courseName
                value.moduleName = module.name
                value.title = item.title
                value.kind = item.type
                value.htmlURL = item.htmlURL
                value.apiURL = item.url
                value.position = item.position ?? 0
                value.syncedAt = Date()
                resourcesByKey[key] = value
            }
        }

        let folderNames = Dictionary(uniqueKeysWithValues: snapshot.folders.compactMap { folder -> (String, String)? in
            guard let courseID = folder.courseID else { return nil }
            return ("\(courseID):\(folder.id)", Self.folderName(folder))
        })
        let moduleFilesByIdentity = Dictionary(
            resourcesByKey.values.compactMap { resource -> (String, CanvasResource)? in
                guard resource.kind.caseInsensitiveCompare("File") == .orderedSame,
                      let canvasID = resource.canvasID else { return nil }
                return ("\(resource.courseCanvasID):\(canvasID)", resource)
            },
            uniquingKeysWith: { first, _ in first }
        )
        for remote in snapshot.files {
            guard let courseID = remote.courseID else { continue }
            let key = "\(courseID):file:\(remote.id)"
            let moduleResource = moduleFilesByIdentity["\(courseID):\(remote.id)"]
            let value = resourcesByKey[key] ?? moduleResource ?? CanvasResource(
                syncKey: key,
                courseCanvasID: courseID,
                courseName: courseNames[courseID] ?? "Course",
                moduleName: remote.folderID.flatMap { folderNames["\(courseID):\($0)"] } ?? "Course files",
                title: remote.displayName ?? remote.filename ?? "Canvas file",
                kind: "File",
                position: 0
            )
            if resourcesByKey[key] == nil, moduleResource == nil { context.insert(value) }
            value.canvasID = remote.id
            value.courseName = courseNames[courseID] ?? value.courseName
            if moduleResource == nil {
                value.moduleName = remote.folderID.flatMap { folderNames["\(courseID):\($0)"] } ?? "Course files"
            }
            value.title = remote.displayName ?? remote.filename ?? value.title
            value.kind = "File"
            value.apiURL = remote.apiURL
            value.htmlURL = nil
            value.syncedAt = Date()
            if moduleResource == nil { resourcesByKey[key] = value }
        }

        let existingAnnouncements = try context.fetch(FetchDescriptor<CanvasAnnouncement>())
        var announcementsByID = Dictionary(uniqueKeysWithValues: existingAnnouncements.map { ($0.canvasID, $0) })
        for remote in snapshot.announcements {
            guard let courseID = Self.courseID(from: remote.contextCode),
                  let postedAt = remote.postedAt else { continue }
            let value = announcementsByID[remote.id] ?? CanvasAnnouncement(
                canvasID: remote.id,
                courseCanvasID: courseID,
                courseName: courseNames[courseID] ?? "Course",
                title: remote.title,
                postedAt: postedAt
            )
            if announcementsByID[remote.id] == nil { context.insert(value) }
            value.courseName = courseNames[courseID] ?? value.courseName
            value.title = remote.title
            value.messageHTML = remote.message
            value.postedAt = postedAt
            value.authorName = remote.author?.displayName
            value.htmlURL = remote.htmlURL
            value.syncedAt = Date()
            announcementsByID[remote.id] = value
        }

        try context.save()
    }

    private static func courseID(from contextCode: String?) -> Int64? {
        guard let contextCode, contextCode.hasPrefix("course_") else { return nil }
        return Int64(contextCode.dropFirst("course_".count))
    }

    private static func folderName(_ folder: CanvasFolderDTO) -> String {
        let fullName = folder.fullName ?? folder.name
        var components = fullName.split(separator: "/").map(String.init)
        if components.first?.caseInsensitiveCompare("course files") == .orderedSame {
            components.removeFirst()
        }
        return components.isEmpty ? "Course files" : components.joined(separator: " / ")
    }

    private static func color(for id: Int64) -> String {
        LecternTheme.coursePalette[Int(id.magnitude % UInt64(LecternTheme.coursePalette.count))]
    }
}

extension String {
    var canvasPlainText: String {
        CanvasHTMLTextCache.shared.text(for: self)
    }
}
