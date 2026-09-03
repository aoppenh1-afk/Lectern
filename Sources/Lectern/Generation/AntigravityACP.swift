import AppKit
import CryptoKit
import Foundation
import Observation

struct AntigravityACPRelease: Equatable, Sendable {
    struct Member: Codable, Equatable, Sendable {
        let name: String
        let bytes: Int64
    }

    let version: String
    let url: URL
    let sha256: String
    let archiveBytes: Int64
    let executable: Member
    let harness: Member

    /// Pinned to the Google registry release verified by T3 Code on 2026-09-02.
    static var current: AntigravityACPRelease? {
        #if arch(arm64)
        AntigravityACPRelease(
            version: "agy_acp_server_20260818_01_RC01",
            url: URL(string: "https://dl.google.com/agy-extensions/releases/macos/agy-acp-server-agy_acp_server_20260818_01_RC01-darwin-arm64.zip")!,
            sha256: "f122ca7e7030a27f9649da4cf1a7d80e12c48c5f6118ff35affc34d56cbf83dd",
            archiveBytes: 314_500_221,
            executable: .init(name: "agy_acp_server.par", bytes: 792_105_680),
            harness: .init(name: "localharness_external", bytes: 101_551_680)
        )
        #else
        nil
        #endif
    }
}

struct AntigravityACPLayout: Sendable {
    let root: URL

    var managedDirectory: URL {
        root.appendingPathComponent("tools/antigravity-acp/darwin-arm64", isDirectory: true)
    }

    var versionsDirectory: URL {
        managedDirectory.appendingPathComponent("versions", isDirectory: true)
    }

    var activeRecord: URL {
        managedDirectory.appendingPathComponent("active.json")
    }

    var profileDirectory: URL {
        root.appendingPathComponent("providers/antigravity/default", isDirectory: true)
    }

    var acpProfileDirectory: URL {
        profileDirectory.appendingPathComponent("antigravity-acp", isDirectory: true)
    }

    var token: URL {
        acpProfileDirectory.appendingPathComponent("acp_token.json")
    }

    static func applicationSupport(fileManager: FileManager = .default) -> AntigravityACPLayout {
        let support = (try? fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )) ?? fileManager.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        return AntigravityACPLayout(root: support.appendingPathComponent("Lectern", isDirectory: true))
    }
}

struct AntigravityACPInstallation: Equatable, Sendable {
    let executable: URL
    let harness: URL
    let version: String
}

enum AntigravityACPContent {
    enum Input: Sendable {
        case data(Data, named: String)
        case file(URL, named: String)
    }

    enum Block: Equatable, Sendable {
        case text(String)
        case image(data: Data, mimeType: String)
        case audio(data: Data, mimeType: String)
        case resource(text: String, uri: String, mimeType: String)
        case resourceLink(uri: String, name: String, mimeType: String)
    }

    static let maximumAudioBytes = 20 * 1_024 * 1_024
    static let maximumImageBytes = 10 * 1_024 * 1_024
    static let maximumTextBytes = 1_024 * 1_024
    static let maximumTotalBytes = 50 * 1_024 * 1_024

    static func block(for input: Input) throws -> Block {
        let data: Data
        let name: String
        let fileURL: URL?
        switch input {
        case .data(let value, let filename):
            data = value
            name = filename
            fileURL = nil
        case .file(let url, let filename):
            data = try Data(contentsOf: url, options: .mappedIfSafe)
            name = filename
            fileURL = url
        }

        let type = mimeType(for: name)
        if type.hasPrefix("audio/") {
            guard data.count <= maximumAudioBytes else {
                throw AntigravityACPError.unsupportedAttachment(
                    "\(name) is larger than Antigravity's 20 MiB native-audio limit."
                )
            }
            return .audio(data: data, mimeType: type)
        }
        if type.hasPrefix("image/") {
            guard data.count <= maximumImageBytes else {
                throw AntigravityACPError.unsupportedAttachment(
                    "\(name) is larger than Antigravity's 10 MiB image limit."
                )
            }
            return .image(data: data, mimeType: type)
        }
        if type == "application/pdf", let fileURL {
            return .resourceLink(uri: fileURL.absoluteString, name: name, mimeType: type)
        }
        guard data.count <= maximumTextBytes,
              let text = String(data: data, encoding: .utf8),
              !text.contains("\0") else {
            throw AntigravityACPError.unsupportedAttachment(
                "Antigravity accepts UTF-8 text files up to 1 MiB, images, PDFs, and supported audio."
            )
        }
        let uri = fileURL?.absoluteString ?? "lectern://attachment/\(name.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? name)"
        return .resource(text: text, uri: uri, mimeType: type)
    }

    static func mimeType(for name: String) -> String {
        switch URL(fileURLWithPath: name).pathExtension.lowercased() {
        case "aac": return "audio/aac"
        case "flac": return "audio/flac"
        case "mp3": return "audio/mp3"
        case "m4a": return "audio/m4a"
        case "mp4": return "audio/mp4"
        case "ogg": return "audio/ogg"
        case "wav": return "audio/wav"
        case "webm": return "audio/webm"
        case "bmp": return "image/bmp"
        case "jpg", "jpeg": return "image/jpeg"
        case "png": return "image/png"
        case "webp": return "image/webp"
        case "pdf": return "application/pdf"
        case "json", "jsonl": return "application/json"
        case "md", "mdx": return "text/markdown"
        case "csv": return "text/csv"
        case "html": return "text/html"
        default: return "text/plain"
        }
    }
}

enum AntigravityACPProfile {
    private static let removedEnvironmentKeys: Set<String> = [
        "GEMINI_API_KEY", "GOOGLE_API_KEY", "GOOGLE_APPLICATION_CREDENTIALS",
        "GOOGLE_CLOUD_PROJECT", "GOOGLE_CLOUD_LOCATION", "GOOGLE_CLOUD_QUOTA_PROJECT",
        "GOOGLE_GENAI_USE_VERTEXAI", "GCLOUD_PROJECT", "CLOUDSDK_CORE_PROJECT",
        "AGY_ACP_CCPA_PROJECT", "AGY_ACP_ENABLE_OAUTH", "GEMINI_HOME",
        "AGY_ACP_FORCE_FILE_STORAGE", "ANTIGRAVITY_HARNESS_PATH", "BROWSER",
        "PYTHONUNBUFFERED", "ELECTRON_RUN_AS_NODE",
    ]

    static func prepare(layout: AntigravityACPLayout, fileManager: FileManager = .default) throws {
        for directory in [layout.profileDirectory, layout.acpProfileDirectory] {
            try fileManager.createDirectory(
                at: directory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        }

        let settings = layout.acpProfileDirectory.appendingPathComponent("settings.json")
        try Data("{\"auth\":{\"type\":\"oauth-personal\"}}\n".utf8).write(to: settings, options: .atomic)
        try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: settings.path)

        let helper = browserHelperURL(layout: layout)
        let script = """
        #!/bin/sh
        printf '__LECTERN_ANTIGRAVITY_AUTH_URL__%s\\n' "$1" >&2
        exit 0
        """
        try Data(script.utf8).write(to: helper, options: .atomic)
        try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: helper.path)
    }

    static func launchEnvironment(
        installation: AntigravityACPInstallation,
        layout: AntigravityACPLayout,
        base: [String: String] = ProcessInfo.processInfo.environment
    ) -> [String: String] {
        var environment = base.filter { !removedEnvironmentKeys.contains($0.key.uppercased()) }
        environment["GEMINI_HOME"] = layout.profileDirectory.path
        environment["AGY_ACP_FORCE_FILE_STORAGE"] = "1"
        environment["ANTIGRAVITY_HARNESS_PATH"] = installation.harness.path
        environment["BROWSER"] = "'\(browserHelperURL(layout: layout).path.replacingOccurrences(of: "'", with: "'\"'\"'"))' %s"
        environment["PYTHONUNBUFFERED"] = "1"
        return environment
    }

    private static func browserHelperURL(layout: AntigravityACPLayout) -> URL {
        layout.profileDirectory.appendingPathComponent("lectern-browser")
    }
}

enum AntigravityACPAuthorization {
    struct Pending: Equatable, Sendable {
        let authorizationURL: URL
        let redirectURL: URL
        let state: String
    }

    static func parse(_ url: URL) throws -> Pending {
        guard url.absoluteString.utf8.count <= 16_384,
              url.scheme == "https",
              url.host == "accounts.google.com",
              url.path == "/o/oauth2/v2/auth",
              url.user == nil,
              url.password == nil,
              url.fragment == nil,
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let items = components.queryItems else {
            throw AntigravityACPError.authenticationFailed("Antigravity returned an invalid Google sign-in URL.")
        }
        func values(_ name: String) -> [String] {
            items.filter { $0.name == name }.compactMap(\.value)
        }
        let states = values("state")
        let redirects = values("redirect_uri")
        guard values("response_type") == ["code"],
              states.count == 1, !states[0].isEmpty, states[0].utf8.count <= 512,
              !states[0].contains(where: \Character.isWhitespace),
              redirects.count == 1,
              let redirect = URL(string: redirects[0]),
              redirect.scheme == "http",
              redirect.host == "127.0.0.1",
              redirect.path == "/",
              redirect.query == nil,
              redirect.fragment == nil,
              let port = redirect.port,
              port >= 1_024 else {
            throw AntigravityACPError.authenticationFailed("Antigravity returned an invalid Google sign-in URL.")
        }
        return Pending(authorizationURL: url, redirectURL: redirect, state: states[0])
    }

    static func validate(_ url: URL) throws {
        _ = try parse(url)
    }

    static func callback(_ value: String, for pending: Pending) throws -> URL {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.utf8.count <= 16_384,
              let callback = URL(string: trimmed),
              callback.scheme == "http",
              callback.host == "127.0.0.1",
              callback.port == pending.redirectURL.port,
              callback.path == pending.redirectURL.path,
              callback.user == nil,
              callback.password == nil,
              callback.fragment == nil,
              let components = URLComponents(url: callback, resolvingAgainstBaseURL: false),
              let items = components.queryItems else {
            throw AntigravityACPError.authenticationFailed("Paste the complete local Google callback URL.")
        }
        func values(_ name: String) -> [String] {
            items.filter { $0.name == name }.compactMap(\.value)
        }
        let states = values("state")
        let codes = values("code")
        guard states == [pending.state], codes.count == 1, !codes[0].isEmpty,
              codes[0].utf8.count <= 8_192 else {
            throw AntigravityACPError.authenticationFailed("The callback URL does not match this sign-in attempt.")
        }
        return callback
    }
}

enum AntigravityACPError: LocalizedError, Sendable {
    case unsupportedPlatform
    case notInstalled
    case invalidInstallation(String)
    case downloadFailed(String)
    case unsupportedAttachment(String)
    case authenticationFailed(String)

    var errorDescription: String? {
        switch self {
        case .unsupportedPlatform:
            return "Google does not publish this Antigravity ACP runtime for this Mac."
        case .notInstalled:
            return "Install the official Antigravity runtime in Lectern Settings first."
        case .invalidInstallation(let detail), .downloadFailed(let detail),
             .unsupportedAttachment(let detail), .authenticationFailed(let detail):
            return detail
        }
    }
}

private final class AntigravityACPDownload: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let destination: URL
    private let expectedBytes: Int64
    private let progress: @Sendable (Int64, Int64) -> Void
    private let lock = NSLock()
    private var continuation: CheckedContinuation<HTTPURLResponse, Error>?
    private var session: URLSession?
    private var task: URLSessionDownloadTask?

    init(
        destination: URL,
        expectedBytes: Int64,
        progress: @escaping @Sendable (Int64, Int64) -> Void
    ) {
        self.destination = destination
        self.expectedBytes = expectedBytes
        self.progress = progress
    }

    func start(url: URL) async throws -> HTTPURLResponse {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let configuration = URLSessionConfiguration.ephemeral
                configuration.timeoutIntervalForRequest = 120
                configuration.timeoutIntervalForResource = 45 * 60
                let session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
                let task = session.downloadTask(with: url)
                lock.lock()
                self.continuation = continuation
                self.session = session
                self.task = task
                lock.unlock()
                task.resume()
            }
        } onCancel: {
            cancel()
        }
    }

    func cancel() {
        lock.lock()
        let task = self.task
        lock.unlock()
        task?.cancel()
        finish(.failure(CancellationError()))
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        guard totalBytesWritten <= expectedBytes else {
            downloadTask.cancel()
            finish(.failure(AntigravityACPError.downloadFailed(
                "The Antigravity download exceeded the pinned release size."
            )))
            return
        }
        progress(totalBytesWritten, expectedBytes)
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        do {
            guard let response = downloadTask.response as? HTTPURLResponse else {
                throw AntigravityACPError.downloadFailed("Google returned an invalid download response.")
            }
            try FileManager.default.moveItem(at: location, to: destination)
            finish(.success(response))
        } catch {
            finish(.failure(error))
        }
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: (any Error)?
    ) {
        if let error { finish(.failure(error)) }
    }

    private func finish(_ result: Result<HTTPURLResponse, Error>) {
        lock.lock()
        let continuation = self.continuation
        self.continuation = nil
        let session = self.session
        self.session = nil
        task = nil
        lock.unlock()
        guard let continuation else { return }
        session?.finishTasksAndInvalidate()
        continuation.resume(with: result)
    }
}

actor AntigravityACPInstaller {
    enum Phase: Sendable { case downloading, extracting, verifying }

    private struct ActiveRecord: Codable { let releaseId: String }
    private struct ReleaseRecord: Codable {
        let releaseId: String
        let version: String
        let executable: AntigravityACPRelease.Member
        let harness: AntigravityACPRelease.Member
    }

    let layout: AntigravityACPLayout
    private let fileManager: FileManager
    private var leases: Set<UUID> = []

    init(layout: AntigravityACPLayout, fileManager: FileManager = .default) {
        self.layout = layout
        self.fileManager = fileManager
    }

    func resolve() throws -> AntigravityACPInstallation {
        guard fileManager.fileExists(atPath: layout.activeRecord.path) else {
            throw AntigravityACPError.notInstalled
        }
        let active = try decode(ActiveRecord.self, at: layout.activeRecord)
        guard active.releaseId.range(of: "^[a-f0-9]{64}$", options: .regularExpression) != nil else {
            throw AntigravityACPError.invalidInstallation("The managed Antigravity runtime record is invalid. Reinstall it.")
        }
        return try completedRelease(id: active.releaseId)
    }

    func acquire() throws -> (installation: AntigravityACPInstallation, leaseID: UUID) {
        let installation = try resolve()
        let leaseID = UUID()
        leases.insert(leaseID)
        return (installation, leaseID)
    }

    func release(leaseID: UUID) {
        leases.remove(leaseID)
    }

    func hasNoLeases() -> Bool { leases.isEmpty }

    func install(
        release: AntigravityACPRelease,
        forceReinstall: Bool,
        progress: @escaping @Sendable (Int64, Int64) -> Void,
        phase: @escaping @Sendable (Phase) -> Void,
        validate: @escaping @Sendable (AntigravityACPInstallation) async throws -> Void
    ) async throws -> AntigravityACPInstallation {
        try fileManager.createDirectory(at: layout.versionsDirectory, withIntermediateDirectories: true)
        let destination = layout.versionsDirectory.appendingPathComponent(release.sha256, isDirectory: true)
        if forceReinstall, !leases.isEmpty {
            throw AntigravityACPError.invalidInstallation(
                "Antigravity is currently in use. Stop active work before reinstalling it."
            )
        }
        if !forceReinstall, fileManager.fileExists(atPath: destination.path) {
            let existing = try completedRelease(id: release.sha256)
            guard existing.version == release.version else {
                throw AntigravityACPError.invalidInstallation(
                    "The existing managed release has the wrong version. Remove it before reinstalling."
                )
            }
            phase(.verifying)
            try await validate(existing)
            try activate(releaseID: release.sha256)
            return existing
        }

        let requiredBytes = release.archiveBytes + release.executable.bytes + release.harness.bytes
            + 256 * 1_024 * 1_024
        if let capacity = try? layout.versionsDirectory.resourceValues(
            forKeys: [.volumeAvailableCapacityForImportantUsageKey]
        ).volumeAvailableCapacityForImportantUsage,
           capacity < requiredBytes {
            throw AntigravityACPError.downloadFailed(
                "Antigravity needs at least \(Int((requiredBytes + 1_048_575) / 1_048_576)) MiB of free space to install."
            )
        }

        let staging = layout.managedDirectory.appendingPathComponent(".install-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: staging, withIntermediateDirectories: false)
        defer { try? fileManager.removeItem(at: staging) }

        let archive = staging.appendingPathComponent("download.zip")
        do {
            phase(.downloading)
            let response = try await AntigravityACPDownload(
                destination: archive,
                expectedBytes: release.archiveBytes,
                progress: progress
            ).start(url: release.url)
            guard response.statusCode == 200 else {
                throw AntigravityACPError.downloadFailed("Google did not return the Antigravity runtime download.")
            }
        } catch let error as AntigravityACPError {
            throw error
        } catch {
            throw AntigravityACPError.downloadFailed("Could not download Antigravity from Google: \(error.localizedDescription)")
        }

        let archiveSize = try fileSize(archive)
        progress(archiveSize, release.archiveBytes)
        guard archiveSize == release.archiveBytes,
              try sha256(of: archive) == release.sha256 else {
            throw AntigravityACPError.downloadFailed(
                "The Antigravity download failed its size or SHA-256 check. Nothing was installed."
            )
        }

        let members = try processOutput("/usr/bin/unzip", ["-Z1", archive.path])
            .split(whereSeparator: \Character.isNewline).map(String.init)
        guard members == [release.executable.name, release.harness.name]
                || members == [release.harness.name, release.executable.name] else {
            throw AntigravityACPError.invalidInstallation(
                "The archive must contain exactly the Antigravity executable and its harness."
            )
        }

        let pair = staging.appendingPathComponent("pair", isDirectory: true)
        phase(.extracting)
        try fileManager.createDirectory(at: pair, withIntermediateDirectories: false)
        try runProcess("/usr/bin/unzip", [
            "-qq", "-j", archive.path, release.executable.name, release.harness.name, "-d", pair.path,
        ])
        let executable = pair.appendingPathComponent(release.executable.name)
        let harness = pair.appendingPathComponent(release.harness.name)
        guard try fileSize(executable) == release.executable.bytes,
              try fileSize(harness) == release.harness.bytes else {
            throw AntigravityACPError.invalidInstallation("The downloaded Antigravity runtime is incomplete.")
        }
        try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: harness.path)

        let candidate = AntigravityACPInstallation(
            executable: executable,
            harness: harness,
            version: release.version
        )
        phase(.verifying)
        try await validate(candidate)

        let record = ReleaseRecord(
            releaseId: release.sha256,
            version: release.version,
            executable: release.executable,
            harness: release.harness
        )
        try JSONEncoder().encode(record).write(
            to: pair.appendingPathComponent(".install-complete.json"), options: .atomic
        )

        var backup: URL?
        if fileManager.fileExists(atPath: destination.path) {
            let candidate = layout.versionsDirectory.appendingPathComponent(".previous-\(UUID().uuidString)")
            try fileManager.moveItem(at: destination, to: candidate)
            backup = candidate
        }
        do {
            try fileManager.moveItem(at: pair, to: destination)
            try activate(releaseID: release.sha256)
        } catch {
            if fileManager.fileExists(atPath: destination.path) {
                try? fileManager.removeItem(at: destination)
            }
            if let backup {
                try? fileManager.moveItem(at: backup, to: destination)
            }
            throw error
        }
        if let backup { try? fileManager.removeItem(at: backup) }
        return try completedRelease(id: release.sha256)
    }

    func removeManagedRuntime() throws {
        guard leases.isEmpty else {
            throw AntigravityACPError.invalidInstallation(
                "Antigravity is currently in use. Stop active generation or transcription before removing it."
            )
        }
        let expectedSuffix = "/tools/antigravity-acp/darwin-arm64"
        guard layout.managedDirectory.standardizedFileURL.path.hasSuffix(expectedSuffix) else {
            throw AntigravityACPError.invalidInstallation("Refused to remove an unexpected directory.")
        }
        if fileManager.fileExists(atPath: layout.managedDirectory.path) {
            try fileManager.removeItem(at: layout.managedDirectory)
        }
    }

    private func completedRelease(id: String) throws -> AntigravityACPInstallation {
        let directory = layout.versionsDirectory.appendingPathComponent(id, isDirectory: true)
        let record = try decode(ReleaseRecord.self, at: directory.appendingPathComponent(".install-complete.json"))
        let executable = directory.appendingPathComponent(record.executable.name)
        let harness = directory.appendingPathComponent(record.harness.name)
        guard record.releaseId == id,
              try fileSize(executable) == record.executable.bytes,
              try fileSize(harness) == record.harness.bytes,
              fileManager.isExecutableFile(atPath: executable.path),
              fileManager.isExecutableFile(atPath: harness.path) else {
            throw AntigravityACPError.invalidInstallation(
                "The managed Antigravity runtime is incomplete. Remove it and reinstall."
            )
        }
        return .init(executable: executable, harness: harness, version: record.version)
    }

    private func activate(releaseID: String) throws {
        let activeTemporary = layout.managedDirectory.appendingPathComponent("active.json.\(UUID().uuidString)")
        try JSONEncoder().encode(ActiveRecord(releaseId: releaseID)).write(to: activeTemporary, options: .atomic)
        if fileManager.fileExists(atPath: layout.activeRecord.path) {
            _ = try fileManager.replaceItemAt(layout.activeRecord, withItemAt: activeTemporary)
        } else {
            try fileManager.moveItem(at: activeTemporary, to: layout.activeRecord)
        }
    }

    private func decode<T: Decodable>(_ type: T.Type, at url: URL) throws -> T {
        let size = try fileSize(url)
        guard size > 0, size <= 16_384 else {
            throw AntigravityACPError.invalidInstallation("The managed Antigravity runtime record is invalid.")
        }
        return try JSONDecoder().decode(type, from: Data(contentsOf: url))
    }

    private func fileSize(_ url: URL) throws -> Int64 {
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        guard values.isRegularFile == true, let size = values.fileSize else {
            throw AntigravityACPError.invalidInstallation("A managed Antigravity file is missing.")
        }
        return Int64(size)
    }

    private func sha256(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var digest = SHA256()
        while let chunk = try handle.read(upToCount: 4 * 1_024 * 1_024), !chunk.isEmpty {
            digest.update(data: chunk)
        }
        return digest.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private func processOutput(_ executable: String, _ arguments: [String]) throws -> String {
        let pipe = Pipe()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = pipe
        process.standardError = Pipe()
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw AntigravityACPError.invalidInstallation("The verified Antigravity archive could not be read.")
        }
        return String(decoding: data, as: UTF8.self)
    }

    private func runProcess(_ executable: String, _ arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw AntigravityACPError.invalidInstallation("The verified Antigravity archive could not be extracted.")
        }
    }
}

@MainActor
@Observable
final class AntigravityACPManager {
    enum InstallationPhase: Equatable { case downloading, extracting, verifying }

    enum RuntimeState: Equatable {
        case checking
        case notInstalled
        case installing(phase: InstallationPhase, downloaded: Int64, total: Int64)
        case ready(version: String)
        case cancelled
        case failed(String)
    }

    enum AuthState: Equatable {
        case unavailable
        case signedOut
        case signingIn
        case waitingForBrowser(URL)
        case signedIn
        case signingOut
        case failed(String)
    }

    static let shared = AntigravityACPManager()

    private(set) var runtimeState: RuntimeState = .checking
    private(set) var authState: AuthState = .unavailable
    private(set) var authDetail: String?
    private(set) var installation: AntigravityACPInstallation?
    private var authenticationConnection: ACPConnection?
    private var pendingAuthorization: AntigravityACPAuthorization.Pending?
    private var installationTask: Task<Void, Never>?
    private var activeConnections: [UUID: ACPConnection] = [:]

    let layout: AntigravityACPLayout
    private let installer: AntigravityACPInstaller

    init(layout: AntigravityACPLayout = .applicationSupport()) {
        self.layout = layout
        installer = AntigravityACPInstaller(layout: layout)
    }

    var isInstalled: Bool { installation != nil }
    var isSignedIn: Bool { authState == .signedIn }
    var hasActiveWork: Bool { !activeConnections.isEmpty }

    func startInstallation(reinstall: Bool = false) {
        guard installationTask == nil else { return }
        installationTask = Task { @MainActor [weak self] in
            guard let self else { return }
            await install(reinstall: reinstall)
            installationTask = nil
        }
    }

    func cancelInstallation() {
        installationTask?.cancel()
        installationTask = nil
        runtimeState = .cancelled
        authState = .unavailable
    }

    func refresh() async {
        runtimeState = .checking
        do {
            let resolved = try await installer.resolve()
            try AntigravityACPProfile.prepare(layout: layout)
            try await validate(resolved)
            installation = resolved
            runtimeState = .ready(version: resolved.version)
            await refreshAuthenticationStatus()
        } catch AntigravityACPError.notInstalled {
            installation = nil
            runtimeState = .notInstalled
            authState = .unavailable
        } catch {
            installation = nil
            runtimeState = .failed(error.localizedDescription)
            authState = .unavailable
        }
    }

    func install(reinstall: Bool = false) async {
        guard let release = AntigravityACPRelease.current else {
            runtimeState = .failed(AntigravityACPError.unsupportedPlatform.localizedDescription)
            return
        }
        runtimeState = .installing(phase: .downloading, downloaded: 0, total: release.archiveBytes)
        do {
            let installed = try await installer.install(
                release: release,
                forceReinstall: reinstall,
                progress: { downloaded, total in
                    Task { @MainActor [weak self] in
                        self?.runtimeState = .installing(
                            phase: .downloading, downloaded: downloaded, total: total
                        )
                    }
                },
                phase: { phase in
                    Task { @MainActor [weak self] in
                        guard let self else { return }
                        let bytes: (Int64, Int64)
                        if case .installing(_, let downloaded, let total) = runtimeState {
                            bytes = (downloaded, total)
                        } else {
                            bytes = (0, release.archiveBytes)
                        }
                        let mapped: InstallationPhase = switch phase {
                        case .downloading: .downloading
                        case .extracting: .extracting
                        case .verifying: .verifying
                        }
                        runtimeState = .installing(phase: mapped, downloaded: bytes.0, total: bytes.1)
                    }
                },
                validate: { candidate in
                    try await AntigravityACPManager.validateInstallation(candidate)
                }
            )
            installation = installed
            runtimeState = .ready(version: installed.version)
            await refreshAuthenticationStatus()
        } catch {
            if Task.isCancelled {
                runtimeState = .cancelled
                authState = .unavailable
            } else {
                runtimeState = .failed(error.localizedDescription)
                authState = .unavailable
            }
        }
    }

    func remove() async {
        do {
            await stopActiveConnections()
            try await installer.removeManagedRuntime()
            installation = nil
            runtimeState = .notInstalled
            authState = .unavailable
        } catch {
            runtimeState = .failed(error.localizedDescription)
        }
    }

    func signIn() async {
        guard installation != nil else {
            authState = .failed(AntigravityACPError.notInstalled.localizedDescription)
            return
        }
        authState = .signingIn
        authDetail = nil
        do {
            let connection = try await makeConnection { url in
                Task { @MainActor in
                    do {
                        self.pendingAuthorization = try AntigravityACPAuthorization.parse(url)
                    } catch {
                        self.authenticationConnection?.shutdown()
                        self.authState = .failed(error.localizedDescription)
                        return
                    }
                    self.authState = .waitingForBrowser(url)
                    self.authDetail = nil
                    NSWorkspace.shared.open(url)
                }
            }
            authenticationConnection = connection
            defer {
                connection.shutdown()
                authenticationConnection = nil
            }
            let timeout = Task {
                try? await Task.sleep(for: .seconds(300))
                guard !Task.isCancelled else { return }
                connection.shutdown()
            }
            defer { timeout.cancel() }
            try await connection.authenticate(methodID: "oauth-personal")
            _ = try await connection.newSession(workingDirectory: FileManager.default.temporaryDirectory)
            authState = .signedIn
            authDetail = nil
            pendingAuthorization = nil
        } catch {
            authState = .failed(Self.authMessage(for: error))
        }
    }

    func cancelSignIn() {
        authenticationConnection?.shutdown()
        authenticationConnection = nil
        pendingAuthorization = nil
        authDetail = nil
        authState = installation == nil ? .unavailable : .signedOut
    }

    func completeSignIn(callbackURL: String) async {
        do {
            guard let pendingAuthorization else {
                throw AntigravityACPError.authenticationFailed("There is no active Google sign-in to complete.")
            }
            let callback = try AntigravityACPAuthorization.callback(callbackURL, for: pendingAuthorization)
            var request = URLRequest(url: callback)
            request.timeoutInterval = 15
            let configuration = URLSessionConfiguration.ephemeral
            configuration.timeoutIntervalForRequest = 15
            configuration.timeoutIntervalForResource = 15
            let (_, response) = try await URLSession(configuration: configuration).data(for: request)
            guard let http = response as? HTTPURLResponse, (200..<500).contains(http.statusCode) else {
                throw AntigravityACPError.authenticationFailed(
                    "Could not deliver the sign-in response to the local Antigravity process."
                )
            }
            authDetail = nil
        } catch {
            authDetail = error.localizedDescription
        }
    }

    func signOut() async {
        guard installation != nil else { return }
        authState = .signingOut
        do {
            await stopActiveConnections()
            let connection = try await makeConnection()
            defer { connection.shutdown() }
            try await connection.logout()
            authState = .signedOut
        } catch {
            authState = .failed("Antigravity sign-out failed: \(error.localizedDescription)")
        }
    }

    func openAuthorizationURLAgain() {
        guard case .waitingForBrowser(let url) = authState else { return }
        NSWorkspace.shared.open(url)
    }

    func makeConnection(
        onAuthorizationURL: (@Sendable (URL) -> Void)? = nil
    ) async throws -> ACPConnection {
        let acquired = try await installer.acquire()
        let connectionID = UUID()
        try AntigravityACPProfile.prepare(layout: layout)
        do {
            let connection = try await Self.connect(
                installation: acquired.installation,
                layout: layout,
                onAuthorizationURL: onAuthorizationURL,
                onClose: { [weak self, installer, leaseID = acquired.leaseID] in
                    Task {
                        await installer.release(leaseID: leaseID)
                        _ = await MainActor.run { self?.activeConnections.removeValue(forKey: connectionID) }
                    }
                }
            )
            activeConnections[connectionID] = connection
            return connection
        } catch {
            await installer.release(leaseID: acquired.leaseID)
            throw error
        }
    }

    private func stopActiveConnections() async {
        let connections = Array(activeConnections.values)
        activeConnections.removeAll()
        connections.forEach { $0.shutdown() }
        for _ in 0..<20 {
            if await installer.hasNoLeases() { return }
            try? await Task.sleep(for: .milliseconds(25))
        }
    }

    /// Authentication state comes from the ACP runtime, never from the normal
    /// `agy` CLI or the mere presence of a cached credential file.
    private func refreshAuthenticationStatus() async {
        do {
            let connection = try await makeConnection()
            defer { connection.shutdown() }
            try await connection.authenticate(methodID: "oauth-personal")
            _ = try await connection.newSession(workingDirectory: FileManager.default.temporaryDirectory)
            authState = .signedIn
            authDetail = nil
        } catch ACPConnection.ACPError.authRequired {
            authState = .signedOut
            authDetail = nil
        } catch {
            authState = .failed(Self.authMessage(for: error))
        }
    }

    private func validate(_ installation: AntigravityACPInstallation) async throws {
        try await Self.validateInstallation(installation)
    }

    nonisolated private static func validateInstallation(
        _ installation: AntigravityACPInstallation
    ) async throws {
        let temporaryRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("Lectern-Antigravity-Validation-\(UUID().uuidString)", isDirectory: true)
        let validationLayout = AntigravityACPLayout(root: temporaryRoot)
        defer { try? FileManager.default.removeItem(at: temporaryRoot) }
        let connection = try await connect(installation: installation, layout: validationLayout)
        defer { connection.shutdown() }
        guard connection.identity?.name == "antigravity-acp",
              connection.identity?.version == installation.version,
              connection.initialization?.protocolVersion == 1,
              connection.initialization?.supportsLoadSession == true,
              connection.initialization?.supportsResume == true,
              connection.initialization?.supportsLogout == true,
              connection.initialization?.authMethodIDs.contains("oauth-personal") == true else {
            throw AntigravityACPError.invalidInstallation(
                "The downloaded runtime did not identify as the expected Google Antigravity release."
            )
        }
    }

    nonisolated private static func connect(
        installation: AntigravityACPInstallation,
        layout: AntigravityACPLayout,
        onAuthorizationURL: (@Sendable (URL) -> Void)? = nil,
        onClose: (@Sendable () -> Void)? = nil
    ) async throws -> ACPConnection {
        try AntigravityACPProfile.prepare(layout: layout)
        let environment = AntigravityACPProfile.launchEnvironment(
            installation: installation,
            layout: layout
        )
        return try await ACPConnection.connect(
            executableURL: installation.executable,
            arguments: [],
            environment: environment,
            workingDirectory: layout.profileDirectory,
            onAuthorizationURL: onAuthorizationURL,
            onClose: onClose
        )
    }

    private static func authMessage(for error: Error) -> String {
        let message = error.localizedDescription
        if message.localizedCaseInsensitiveContains("SUBSCRIPTION_REQUIRED") {
            return "Google requires an eligible Antigravity subscription for this account."
        }
        if message.localizedCaseInsensitiveContains("denied")
            || message.localizedCaseInsensitiveContains("access_denied") {
            return "Google sign-in was not approved. Try again."
        }
        return "Google sign-in failed: \(message)"
    }
}
