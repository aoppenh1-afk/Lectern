import CryptoKit
import Foundation
import Observation
import SwiftData

@MainActor
@Observable
final class LecternCloudSharing {
    let auth = LecternCloudAuth()
    private let container: ModelContainer
    private let defaults: UserDefaults
    private var timer: Task<Void, Never>?
    private var lastHash: String?
    private var revision: Int?
    private var userID: String?
    private(set) var isBusy = false
    private(set) var status = "Sign in, choose courses, then start sharing."
    private(set) var lastSync: Date?
    private(set) var email: String?
    private(set) var needsReview = false
    private(set) var sharingEnabled: Bool
    var sharedCourseIDs: Set<String> {
        didSet { defaults.set(Array(sharedCourseIDs), forKey: "hostedSharing.courses"); lastHash = nil }
    }
    var shareUnfiled: Bool {
        didSet { defaults.set(shareUnfiled, forKey: "hostedSharing.unfiled"); lastHash = nil }
    }
    static var connectionURL: URL { LecternCloudAuth.origin.appendingPathComponent("mcp") }

    init(container: ModelContainer, defaults: UserDefaults = .standard) {
        self.container = container
        self.defaults = defaults
        sharedCourseIDs = Set(defaults.stringArray(forKey: "hostedSharing.courses") ?? [])
        shareUnfiled = defaults.bool(forKey: "hostedSharing.unfiled")
        sharingEnabled = defaults.bool(forKey: "hostedSharing.enabled")
        userID = defaults.string(forKey: "hostedSharing.user")
        revision = defaults.object(forKey: "hostedSharing.revision") as? Int
        lastSync = defaults.object(forKey: "hostedSharing.lastSync") as? Date
        if sharingEnabled { status = "Checking your hosted connection…" }
        timer = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                await self?.syncIfNeeded()
                try? await Task.sleep(for: .seconds(30))
            }
        }
    }

    static func id(for model: PersistentIdentifier) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return SHA256.hash(data: try encoder.encode(model)).map { String(format: "%02x", $0) }.joined()
    }

    func signIn() async {
        guard !isBusy else { return }
        isBusy = true
        defer { isBusy = false }
        do {
            try await auth.signIn()
            let info = try await metadata()
            try applyIdentity(info)
            // Reconnecting grants permission, but uploading remains an explicit user action.
            sharingEnabled = false
            defaults.set(false, forKey: "hostedSharing.enabled")
            revision = info.revision
            persistRevision()
            needsReview = false
            status = "Signed in. Choose courses and start sharing."
        } catch { status = error.localizedDescription }
    }

    func startSharing() async {
        guard !isBusy else { return }
        isBusy = true
        defer { isBusy = false }
        do {
            let info = try await metadata()
            try applyIdentity(info)
            // Explicit action lets this Mac replace the previous hosted selection.
            revision = info.revision
            sharingEnabled = true
            defaults.set(true, forKey: "hostedSharing.enabled")
            needsReview = false
            lastHash = nil
            try await upload()
        } catch { status = error.localizedDescription }
    }

    func syncIfNeeded() async {
        guard sharingEnabled, auth.isSignedIn, !isBusy, !needsReview else { return }
        isBusy = true
        defer { isBusy = false }
        do {
            // Check every cycle even when content is unchanged, so server-side revocation is visible.
            let info = try await metadata()
            try applyIdentity(info)
            guard revision == info.revision else {
                needsReview = true
                status = "Your hosted library changed on another device. Review your selection, then choose Replace hosted selection."
                return
            }
            try await upload()
        } catch { status = error.localizedDescription }
    }

    func deleteHostedLibrary() async {
        guard !isBusy else { return }
        isBusy = true
        defer { isBusy = false }
        // Pause before networking so a failed deletion cannot trigger another upload.
        sharingEnabled = false
        defaults.set(false, forKey: "hostedSharing.enabled")
        do {
            _ = try await request("api/library", method: "DELETE")
            auth.forget()
            revision = nil
            lastHash = nil
            lastSync = nil
            needsReview = false
            defaults.removeObject(forKey: "hostedSharing.revision")
            defaults.removeObject(forKey: "hostedSharing.lastSync")
            status = "Hosted library deleted. All AI connections are revoked. Your local library is kept."
        } catch {
            status = "Deletion was not confirmed. Your hosted copy may still be available. Retry here or delete it at Manage connections. \(error.localizedDescription)"
        }
    }

    func shutdown() {
        timer?.cancel()
        timer = nil
        auth.cancelSignIn()
    }

    private struct Metadata: Decodable {
        let revision: Int
        let email: String
        let user_id: String
    }
    private func metadata() async throws -> Metadata {
        try JSONDecoder().decode(Metadata.self, from: await request("api/library"))
    }
    private func applyIdentity(_ info: Metadata) throws {
        if let userID, userID != info.user_id {
            sharedCourseIDs = []
            shareUnfiled = false
            sharingEnabled = false
            defaults.set(false, forKey: "hostedSharing.enabled")
            revision = nil
            lastHash = nil
            lastSync = nil
            defaults.removeObject(forKey: "hostedSharing.lastSync")
        }
        userID = info.user_id
        email = info.email
        defaults.set(info.user_id, forKey: "hostedSharing.user")
    }
    private func persistRevision() {
        if let revision { defaults.set(revision, forKey: "hostedSharing.revision") }
    }

    private func upload() async throws {
        guard let revision else { throw LecternCloudError.message("Review your selection and start sharing again.") }
        let data = try snapshot().encoded()
        guard data.count <= LecternCloudSnapshot.maximumBytes else { throw LecternCloudError.message("The shared library exceeds 32 MiB. Select fewer courses.") }
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        guard digest != lastHash else { return }
        status = "Syncing selected lectures…"
        struct Upload: Decodable { let upload_id: String }
        let started = try await request("api/library/uploads", method: "POST", body: ["revision": revision])
        let upload = try JSONDecoder().decode(Upload.self, from: started)
        for offset in stride(from: 0, to: data.count, by: LecternCloudSnapshot.chunkBytes) {
            try Task.checkCancellation()
            let chunk = data.subdata(in: offset..<min(offset + LecternCloudSnapshot.chunkBytes, data.count))
            _ = try await request("api/library/uploads/\(upload.upload_id)", method: "PUT", body: ["offset": offset, "chunk": chunk.base64EncodedString()])
        }
        try Task.checkCancellation()
        struct Saved: Decodable { let revision: Int }
        let committed = try await request("api/library/uploads/\(upload.upload_id)/commit", method: "POST", body: [:])
        self.revision = try JSONDecoder().decode(Saved.self, from: committed).revision
        persistRevision()
        lastHash = digest
        lastSync = Date()
        defaults.set(lastSync, forKey: "hostedSharing.lastSync")
        status = "Shared library is up to date. ChatGPT and Claude can read it while this Mac is closed."
    }

    private func request(_ path: String, method: String = "GET", body: [String: Any]? = nil) async throws -> Data {
        var request = URLRequest(url: LecternCloudAuth.origin.appendingPathComponent(path))
        request.httpMethod = method
        request.timeoutInterval = 30
        request.setValue("Bearer \(try await auth.accessToken())", forHTTPHeaderField: "Authorization")
        if let body {
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let response = response as? HTTPURLResponse else { throw LecternCloudError.message("No response from Lectern’s hosted service.") }
        guard (200..<300).contains(response.statusCode) else {
            if response.statusCode == 401 { needsReview = true }
            if response.statusCode == 409 { needsReview = true }
            let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            throw LecternCloudError.message(payload?["error_description"] as? String ?? "Hosted connection failed (\(response.statusCode)). Try again or reconnect.")
        }
        return data
    }

    func snapshot() throws -> LecternCloudSnapshot {
        // Save first so newly created models get permanent IDs before sharing.
        try container.mainContext.save()
        let courses = try container.mainContext.fetch(FetchDescriptor<Course>())
        var selected: [LecternCloudSnapshot.Course] = []
        for course in courses {
            let id = try Self.id(for: course.persistentModelID)
            if sharedCourseIDs.contains(id) { selected.append(.init(id: id, name: course.name)) }
        }
        if shareUnfiled { selected.append(.init(id: "unfiled", name: "Unfiled lectures")) }
        let allowed = Set(selected.map(\.id))
        var lectures: [LecternCloudSnapshot.Lecture] = []
        for lecture in try container.mainContext.fetch(FetchDescriptor<Lecture>()) {
            let courseID = try lecture.course.map { try Self.id(for: $0.persistentModelID) } ?? "unfiled"
            guard allowed.contains(courseID) else { continue }
            var documents: [String: String] = [:]
            for (kind, key): (ArtifactKind, String) in [(.notes, "notes"), (.cleanedTranscript, "cleaned_transcript"), (.rawTranscript, "raw_transcript")] {
                if let content = lecture.artifact(of: kind)?.content, !content.isEmpty { documents[key] = content }
            }
            lectures.append(.init(id: try Self.id(for: lecture.persistentModelID), title: lecture.title, courseID: courseID,
                capturedAt: lecture.capturedAt.ISO8601Format(), documents: documents))
        }
        return .init(courses: selected.sorted { $0.id < $1.id }, lectures: lectures.sorted { $0.id < $1.id })
    }
}
