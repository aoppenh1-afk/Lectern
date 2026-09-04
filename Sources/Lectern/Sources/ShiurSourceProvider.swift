import Foundation

protocol ShiurSourceProvider: Sendable {
    var providerKey: String { get }
    var displayName: String { get }

    func search(query: String) async throws -> [ShiurDiscoveryResult]
    func resolveSubscription(for entity: ShiurSubscriptionEntity) async throws -> ResolvedSubscription
    func resolveSharedURL(_ url: URL) async throws -> ShiurDiscoveryResult
    func fetchFeed(url: URL, eTag: String?, lastModified: String?, maxResults: Int) async throws -> FeedFetchResult
    func resolveMediaURL(for item: RemoteShiurItem) async throws -> URL
}
