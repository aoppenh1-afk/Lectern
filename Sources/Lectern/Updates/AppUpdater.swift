import AppKit
import CryptoKit
import Foundation
import Observation

/// A published GitHub release that is newer than the running app.
struct AppRelease: Identifiable, Hashable, Sendable {
    let version: String
    /// Full Git tag (dev tags keep their timestamp/SHA suffix; stable tags
    /// equal the version with a `v` prefix).
    let tag: String
    /// True for dev-channel prereleases (`v2.3-dev.…` / `dev-…` tags).
    let isDev: Bool
    let name: String
    let notes: String
    let htmlURL: URL
    /// GitHub API URL of the `.zip` asset.
    let assetAPIURL: URL?
    let assetName: String?
    let checksumAPIURL: URL?

    var id: String { version }
}

/// Update track. Stable follows tested GitHub releases, published only when
/// the maintainer cuts one. Dev follows every commit on main via dev
/// prereleases and may break.
enum UpdateChannel: String, Sendable, CaseIterable {
    case stable
    case dev
}

/// Dotted numeric version compare ("1.2" < "1.2.1" < "1.10").
struct AppVersion: Comparable, Hashable, Sendable, CustomStringConvertible {
    let parts: [Int]

    init?(_ string: String) {
        var text = string.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("v") || text.hasPrefix("V") { text.removeFirst() }
        if let dash = text.firstIndex(where: { $0 == "-" || $0 == "+" }) {
            text = String(text[..<dash])
        }
        let pieces = text.split(separator: ".", omittingEmptySubsequences: false)
        guard !pieces.isEmpty else { return nil }
        var parts: [Int] = []
        for piece in pieces {
            guard let value = Int(piece), value >= 0 else { return nil }
            parts.append(value)
        }
        self.parts = parts
    }

    var description: String { parts.map(String.init).joined(separator: ".") }

    static func < (lhs: AppVersion, rhs: AppVersion) -> Bool {
        let count = max(lhs.parts.count, rhs.parts.count)
        for index in 0..<count {
            let l = index < lhs.parts.count ? lhs.parts[index] : 0
            let r = index < rhs.parts.count ? rhs.parts[index] : 0
            if l != r { return l < r }
        }
        return false
    }
}

enum AppUpdaterError: LocalizedError {
    case repositoryNotConfigured
    case notFound
    case unauthorized
    case rateLimited
    case http(Int)
    case noAsset
    case checksumMismatch
    case unzipFailed
    case bundleMissing
    case notWritable(String)

    var errorDescription: String? {
        switch self {
        case .repositoryNotConfigured:
            return "This build has no update repository configured."
        case .notFound:
            return "GitHub returned 404. Nothing has been published yet, or download the latest release from the Releases page."
        case .unauthorized:
            return "GitHub rejected the request (401)."
        case .rateLimited:
            return "GitHub rate limit reached. Try again in a few minutes."
        case .http(let code):
            return "GitHub returned HTTP \(code)."
        case .noAsset:
            return "The latest release has no Lectern .zip attached."
        case .checksumMismatch:
            return "The downloaded file did not match its published checksum, so it was discarded."
        case .unzipFailed:
            return "The downloaded archive could not be expanded."
        case .bundleMissing:
            return "The archive did not contain Lectern.app."
        case .notWritable(let path):
            return "Lectern cannot replace itself at \(path). Move Lectern to your Applications folder and try again, or install the download manually."
        }
    }
}

/// Checks GitHub Releases for a newer build and installs it in place.
///
/// There is no Developer ID here, so this deliberately avoids Sparkle and
/// signature checks. Integrity comes from HTTPS to GitHub plus the optional
/// `.sha256` sidecar the release script publishes next to the zip.
@Observable
@MainActor
final class AppUpdater {
    enum Phase: Equatable {
        case idle
        case checking
        case upToDate
        case available
        case downloading(Double)
        case installing
        case failed(String)
    }

    static let repositoryInfoKey = "LecternUpdateRepository"
    static let autoCheckKey = "updates.autoCheck"
    static let lastCheckKey = "updates.lastCheck"
    static let skippedVersionKey = "updates.skippedVersion"
    static let skippedDevVersionKey = "updates.skippedVersion.dev"
    static let channelKey = "updates.channel"

    private(set) var phase: Phase = .idle
    private(set) var availableRelease: AppRelease?
    /// Set when an automatic check finds something the user has not dismissed.
    var pendingPrompt: AppRelease?

    let repository: String?
    let currentVersion: String
    private let session: URLSession
    private let userDefaults: UserDefaults
    private var attemptedLaunchCheck = false

    init(
        repository: String? = Bundle.main.object(forInfoDictionaryKey: AppUpdater.repositoryInfoKey) as? String,
        currentVersion: String = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0",
        session: URLSession = .shared,
        userDefaults: UserDefaults = .standard
    ) {
        let trimmed = repository?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        self.repository = trimmed.isEmpty ? nil : trimmed
        self.currentVersion = currentVersion
        self.session = session
        self.userDefaults = userDefaults
        if userDefaults.object(forKey: Self.autoCheckKey) == nil {
            userDefaults.set(true, forKey: Self.autoCheckKey)
        }
    }

    var releasesPageURL: URL? {
        repository.flatMap { URL(string: "https://github.com/\($0)/releases") }
    }

    var autoCheckEnabled: Bool {
        get { userDefaults.bool(forKey: Self.autoCheckKey) }
        set { userDefaults.set(newValue, forKey: Self.autoCheckKey) }
    }

    /// Selected update track. Switching tracks clears the current result so
    /// the next check starts fresh; per-track skips are kept separately.
    var channel: UpdateChannel {
        get {
            if let raw = userDefaults.string(forKey: Self.channelKey),
               let parsed = UpdateChannel(rawValue: raw) {
                return parsed
            }
            return .stable
        }
        set {
            userDefaults.set(newValue.rawValue, forKey: Self.channelKey)
            phase = .idle
            availableRelease = nil
            pendingPrompt = nil
        }
    }

    /// Full dev tag baked in at build time by scripts/release-dev.sh.
    /// Nil for stable builds (and local builds, which carry no dev stamp).
    /// An unresolved `$(…)` placeholder — what Xcode leaves when the build
    /// setting is undefined — counts as missing, mirroring
    /// GoogleOAuthConfiguration.
    var currentDevTag: String? {
        let raw = devInfoValue("LecternDevTag")
        return raw.isEmpty ? nil : raw
    }

    var isDevBuild: Bool { currentDevTag != nil }

    /// Human-readable version including the dev stamp when present.
    var displayVersion: String {
        guard isDevBuild else { return currentVersion }
        let sha = devInfoValue("LecternDevSHA")
        guard !sha.isEmpty else { return "\(currentVersion)-dev" }
        return "\(currentVersion)-dev \(String(sha.prefix(7)))"
    }

    private nonisolated func devInfoValue(_ key: String) -> String {
        let raw = (Bundle.main.object(forInfoDictionaryKey: key) as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return raw.contains("$(") ? "" : raw
    }

    nonisolated static func skippedKey(for channel: UpdateChannel) -> String {
        switch channel {
        case .stable: return skippedVersionKey
        case .dev: return skippedDevVersionKey
        }
    }

    // MARK: Checking

    /// Unconditional silent check run every time the app launches. Records the
    /// check timestamp so the periodic timer won't double-fire right after.
    func checkOnLaunch() async {
        guard !attemptedLaunchCheck else { return }
        attemptedLaunchCheck = true
        guard autoCheckEnabled, repository != nil else { return }
        do {
            if let release = try await fetchNewerRelease() {
                if userDefaults.string(forKey: Self.skippedKey(for: channel)) != release.version {
                    pendingPrompt = release
                }
            }
        } catch {
            // Launch checks stay quiet; the manual button reports errors.
        }
    }

    /// Periodic automatic check. Silent on failure; only surfaces a result
    /// when a newer, not-yet-skipped version exists.
    func checkAutomaticallyIfDue(now: Date = Date()) async {
        guard autoCheckEnabled, repository != nil else { return }
        let last = userDefaults.object(forKey: Self.lastCheckKey) as? Date ?? .distantPast
        guard now.timeIntervalSince(last) > 60 * 60 * 20 else { return }
        do {
            if let release = try await fetchNewerRelease() {
                if userDefaults.string(forKey: Self.skippedKey(for: channel)) != release.version {
                    pendingPrompt = release
                }
            }
        } catch {
            // Automatic checks stay quiet; the manual button reports errors.
        }
    }

    func checkNow() async {
        phase = .checking
        do {
            if let release = try await fetchNewerRelease() {
                phase = .available
                pendingPrompt = release
            } else {
                phase = .upToDate
            }
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }

    func skip(_ release: AppRelease) {
        userDefaults.set(release.version, forKey: Self.skippedKey(for: release.isDev ? .dev : .stable))
        pendingPrompt = nil
    }

    func fetchNewerRelease() async throws -> AppRelease? {
        guard let repository else { throw AppUpdaterError.repositoryNotConfigured }
        switch channel {
        case .stable:
            let url = URL(string: "https://api.github.com/repos/\(repository)/releases/latest")!
            let data = try await get(url, accept: "application/vnd.github+json")
            let release = try Self.parseRelease(data)
            userDefaults.set(Date(), forKey: Self.lastCheckKey)
            availableRelease = release
            // A dev build that switches back to stable is always offered the
            // latest stable release as its exit ramp, even when the dotted
            // versions compare equal (dev builds share the base version).
            if isDevBuild {
                return release.assetAPIURL == nil ? nil : release
            }
            guard let remote = AppVersion(release.version), let local = AppVersion(currentVersion) else {
                return nil
            }
            return remote > local ? release : nil
        case .dev:
            let url = URL(string: "https://api.github.com/repos/\(repository)/releases?per_page=30")!
            let data = try await get(url, accept: "application/vnd.github+json")
            guard let release = try Self.parseNewestDevRelease(data) else {
                userDefaults.set(Date(), forKey: Self.lastCheckKey)
                return nil
            }
            userDefaults.set(Date(), forKey: Self.lastCheckKey)
            availableRelease = release
            // Dev builds are ordered by publish time, not by dotted version:
            // every dev tag shares the base marketing version.
            if let current = currentDevTag, current == release.tag {
                return nil
            }
            return release
        }
    }

    nonisolated static func parseRelease(_ data: Data) throws -> AppRelease {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let payload = try decoder.decode(ReleasePayload.self, from: data)
        return makeRelease(from: payload)
    }

    /// Picks the newest dev-channel prerelease from a `GET /releases` list.
    /// Dev tags look like `v2.3-dev.20260910-143000-a1b2c3d` (or `dev-…`);
    /// ordering is by publish date, falling back to tag order since tags
    /// embed a UTC timestamp.
    nonisolated static func parseNewestDevRelease(_ data: Data) throws -> AppRelease? {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let payloads = try decoder.decode([ReleasePayload].self, from: data)
        let devs = payloads.filter { ($0.prerelease ?? false) && isDevTag($0.tag_name) }
        let sorted = devs.sorted {
            switch ($0.published_at, $1.published_at) {
            case let (a?, b?): return a > b
            case (_?, nil): return true
            case (nil, _?): return false
            default: return $0.tag_name > $1.tag_name
            }
        }
        guard let newest = sorted.first else { return nil }
        return makeRelease(from: newest)
    }

    /// Dev prerelease tags published by scripts/release-dev.sh.
    nonisolated static func isDevTag(_ tag: String) -> Bool {
        tag.hasPrefix("dev-") || tag.contains("-dev.")
    }

    private struct ReleasePayload: Decodable {
        let tag_name: String
        let name: String?
        let body: String?
        let html_url: URL
        let assets: [ReleaseAsset]
        let prerelease: Bool?
        let published_at: Date?
    }

    private struct ReleaseAsset: Decodable {
        let name: String
        let url: URL
    }

    private nonisolated static func makeRelease(from payload: ReleasePayload) -> AppRelease {
        let zip = payload.assets.first { $0.name.lowercased().hasSuffix(".zip") && $0.name.lowercased().contains("lectern") }
            ?? payload.assets.first { $0.name.lowercased().hasSuffix(".zip") }
        let checksum = zip.flatMap { zipAsset in
            payload.assets.first { $0.name == zipAsset.name + ".sha256" }
        }
        let stripped = payload.tag_name.hasPrefix("v") || payload.tag_name.hasPrefix("V")
            ? String(payload.tag_name.dropFirst()) : payload.tag_name
        let dev = isDevTag(payload.tag_name)
        return AppRelease(
            // Stable keeps the normalized dotted version so version compares
            // keep working; dev keeps the full tag so every commit is unique.
            version: dev ? stripped : (AppVersion(payload.tag_name)?.description ?? stripped),
            tag: payload.tag_name,
            isDev: dev,
            name: payload.name ?? payload.tag_name,
            notes: payload.body ?? "",
            htmlURL: payload.html_url,
            assetAPIURL: zip?.url,
            assetName: zip?.name,
            checksumAPIURL: checksum?.url
        )
    }

    // MARK: Installing

    func downloadAndInstall(_ release: AppRelease) async {
        guard let assetURL = release.assetAPIURL else {
            phase = .failed(AppUpdaterError.noAsset.localizedDescription)
            return
        }
        let bundleURL = Bundle.main.bundleURL
        let parent = bundleURL.deletingLastPathComponent()
        guard FileManager.default.isWritableFile(atPath: parent.path) else {
            phase = .failed(AppUpdaterError.notWritable(parent.path).localizedDescription)
            return
        }

        phase = .downloading(0)
        do {
            let staging = FileManager.default.temporaryDirectory
                .appendingPathComponent("Lectern-Update-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
            let zipURL = staging.appendingPathComponent(release.assetName ?? "Lectern.zip")
            try await download(assetURL, to: zipURL) { [weak self] fraction in
                self?.phase = .downloading(fraction)
            }

            if let checksumURL = release.checksumAPIURL {
                let published = try await get(checksumURL, accept: "application/octet-stream")
                try Self.verifyChecksum(of: zipURL, against: published)
            }

            phase = .installing
            let expanded = staging.appendingPathComponent("expanded", isDirectory: true)
            try FileManager.default.createDirectory(at: expanded, withIntermediateDirectories: true)
            try await Self.runProcess("/usr/bin/ditto", ["-x", "-k", zipURL.path, expanded.path])
            guard let newApp = Self.findAppBundle(in: expanded) else {
                throw AppUpdaterError.bundleMissing
            }
            // URLSession downloads are not quarantined, but strip defensively so a
            // relaunch never trips Gatekeeper on an ad-hoc signed build.
            try? await Self.runProcess("/usr/bin/xattr", ["-dr", "com.apple.quarantine", newApp.path])

            // AppKit vetoes termination while any sheet is attached (it beeps and
            // brings the window forward instead), so the prompt must be gone
            // before terminate is requested.
            pendingPrompt = nil
            try await Task.sleep(for: .milliseconds(500))
            try await Self.swapAndRelaunch(newApp: newApp, currentApp: bundleURL, staging: staging)
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }

    nonisolated static func verifyChecksum(of file: URL, against published: Data) throws {
        let expected = String(decoding: published, as: UTF8.self)
            .split(whereSeparator: { $0 == " " || $0 == "\n" })
            .first.map(String.init)?.lowercased() ?? ""
        let digest = SHA256.hash(data: try Data(contentsOf: file))
        let actual = digest.map { String(format: "%02x", $0) }.joined()
        guard !expected.isEmpty, expected == actual else { throw AppUpdaterError.checksumMismatch }
    }

    nonisolated static func findAppBundle(in directory: URL) -> URL? {
        let enumerator = FileManager.default.enumerator(
            at: directory, includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles, .skipsPackageDescendants])
        while let url = enumerator?.nextObject() as? URL {
            if url.pathExtension == "app",
               FileManager.default.fileExists(atPath: url.appendingPathComponent("Contents/Info.plist").path) {
                return url
            }
        }
        return nil
    }

    /// Hands the swap to a detached shell so the running binary can exit
    /// before its bundle is replaced, then relaunches the new copy.
    private static func swapAndRelaunch(newApp: URL, currentApp: URL, staging: URL) async throws {
        let pid = ProcessInfo.processInfo.processIdentifier
        let backup = currentApp.deletingLastPathComponent()
            .appendingPathComponent(".\(currentApp.lastPathComponent).previous")
        // $1 new app, $2 installed app, $3 backup path, $4 staging dir, $5 pid.
        // If the app has not exited after 30s (a stuck dialog, for example),
        // ask it to quit harder so the update still lands.
        let script = """
        waited=0
        while kill -0 "$5" 2>/dev/null; do
            sleep 0.2
            waited=$((waited + 1))
            if [ "$waited" -eq 150 ]; then kill -TERM "$5" 2>/dev/null; fi
            if [ "$waited" -ge 200 ]; then kill -KILL "$5" 2>/dev/null; break; fi
        done
        sleep 0.3
        rm -rf "$3"
        mv "$2" "$3" || exit 1
        if mv "$1" "$2"; then
            rm -rf "$3"
        else
            mv "$3" "$2"
        fi
        rm -rf "$4"
        open -n "$2"
        """
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", script, "lectern-update", newApp.path, currentApp.path, backup.path, staging.path, String(pid)]
        process.standardOutput = nil
        process.standardError = nil
        try process.run()
        NSApp.terminate(nil)
        // terminate(nil) returns if AppKit vetoed it; the helper will still
        // force the swap, but exiting cleanly here keeps the store consistent.
        try? await Task.sleep(for: .seconds(3))
        exit(0)
    }

    // MARK: Networking

    private func makeRequest(_ url: URL, accept: String) -> URLRequest {
        var request = URLRequest(url: url)
        request.setValue(accept, forHTTPHeaderField: "Accept")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        request.setValue("Lectern/\(currentVersion)", forHTTPHeaderField: "User-Agent")
        return request
    }

    private func get(_ url: URL, accept: String) async throws -> Data {
        let (data, response) = try await session.data(for: makeRequest(url, accept: accept))
        try Self.check(response)
        return data
    }

    /// Streams the asset to disk with a download task. `URLSession.bytes`
    /// yields one byte per await, which made an 11 MB zip take a minute.
    private final class DownloadDelegate: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
        let destination: URL
        let progress: @Sendable (Double) -> Void
        let continuation: CheckedContinuation<URLResponse, Error>
        private var lastReport = Date.distantPast

        init(destination: URL,
             progress: @escaping @Sendable (Double) -> Void,
             continuation: CheckedContinuation<URLResponse, Error>) {
            self.destination = destination
            self.progress = progress
            self.continuation = continuation
        }

        func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                        didWriteData bytesWritten: Int64, totalBytesWritten: Int64,
                        totalBytesExpectedToWrite: Int64) {
            guard totalBytesExpectedToWrite > 0, Date().timeIntervalSince(lastReport) > 0.15 else { return }
            lastReport = Date()
            progress(Double(totalBytesWritten) / Double(totalBytesExpectedToWrite))
        }

        func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                        didFinishDownloadingTo location: URL) {
            do {
                try? FileManager.default.removeItem(at: destination)
                try FileManager.default.moveItem(at: location, to: destination)
                continuation.resume(returning: downloadTask.response ?? URLResponse())
            } catch {
                continuation.resume(throwing: error)
            }
            session.finishTasksAndInvalidate()
        }

        func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
            if let error {
                continuation.resume(throwing: error)
                session.invalidateAndCancel()
            }
        }
    }

    private func download(_ url: URL, to destination: URL, progress: @escaping @MainActor (Double) -> Void) async throws {
        let request = makeRequest(url, accept: "application/octet-stream")
        let response: URLResponse = try await withCheckedThrowingContinuation { continuation in
            let delegate = DownloadDelegate(
                destination: destination,
                progress: { fraction in Task { @MainActor in progress(fraction) } },
                continuation: continuation)
            let session = URLSession(configuration: .ephemeral, delegate: delegate, delegateQueue: nil)
            session.downloadTask(with: request).resume()
        }
        try Self.check(response)
        progress(1)
    }

    private static func check(_ response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse else { return }
        switch http.statusCode {
        case 200..<300: return
        case 401: throw AppUpdaterError.unauthorized
        case 403 where http.value(forHTTPHeaderField: "X-RateLimit-Remaining") == "0":
            throw AppUpdaterError.rateLimited
        case 403, 404:
            throw AppUpdaterError.notFound
        default: throw AppUpdaterError.http(http.statusCode)
        }
    }

    private static func runProcess(_ path: String, _ arguments: [String]) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: path)
            process.arguments = arguments
            process.standardOutput = nil
            process.standardError = nil
            process.terminationHandler = { process in
                if process.terminationStatus == 0 {
                    continuation.resume()
                } else {
                    continuation.resume(throwing: AppUpdaterError.unzipFailed)
                }
            }
            do { try process.run() } catch { continuation.resume(throwing: error) }
        }
    }
}
