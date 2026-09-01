import Foundation

struct GoogleTab {
    let id: String
    let title: String
    let bodyEndIndex: Int

    var isEmpty: Bool { bodyEndIndex <= 2 }
}

struct GoogleDocument {
    let id: String
    let title: String
    let tabs: [GoogleTab]
}

struct GoogleBatchResult {
    let addedTabIDs: [String]
}

/// Thin Google Docs REST client. Tab create/update payloads are hand-built
/// so we're not stuck on generated types that lag the tabs API.
struct GoogleDocsClient {
    private let session: URLSession = .shared
    private let docsRoot = URL(string: "https://docs.googleapis.com/v1/documents")!

    func createDocument(title: String, accessToken: String) async throws -> GoogleDocument {
        let json = try await request(
            url: docsRoot,
            method: "POST",
            accessToken: accessToken,
            body: ["title": title]
        )
        guard let id = json["documentId"] as? String else {
            throw GoogleDocsError.malformed("Google didn't return a document id.")
        }
        return try await getDocument(id: id, accessToken: accessToken)
    }

    func getDocument(id: String, accessToken: String) async throws -> GoogleDocument {
        var components = URLComponents(url: docsRoot.appendingPathComponent(id), resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "includeTabsContent", value: "true")]
        let json = try await request(
            url: components.url!,
            method: "GET",
            accessToken: accessToken,
            body: nil
        )
        return parseDocument(json)
    }

    func batchUpdate(documentID: String, requests: [[String: Any]], accessToken: String) async throws -> GoogleBatchResult {
        let batchURL = URL(string: "https://docs.googleapis.com/v1/documents/\(documentID):batchUpdate")!
        let json = try await request(
            url: batchURL,
            method: "POST",
            accessToken: accessToken,
            body: ["requests": requests]
        )
        return GoogleBatchResult(addedTabIDs: parseAddedTabIDs(json))
    }

    func addDocumentTab(documentID: String, title: String, accessToken: String) async throws -> String {
        let result = try await batchUpdate(
            documentID: documentID,
            requests: [[
                "addDocumentTab": [
                    "tabProperties": ["title": title]
                ]
            ]],
            accessToken: accessToken
        )
        if let id = result.addedTabIDs.first { return id }

        let doc = try await getDocument(id: documentID, accessToken: accessToken)
        if let match = doc.tabs.last(where: { $0.title == title }) {
            return match.id
        }
        throw GoogleDocsError.malformed("Google created a tab but didn't return its id.")
    }

    func renameTab(documentID: String, tabID: String, title: String, accessToken: String) async throws {
        _ = try await batchUpdate(
            documentID: documentID,
            requests: [[
                "updateDocumentTabProperties": [
                    "tabProperties": [
                        "tabId": tabID,
                        "title": title
                    ],
                    "fields": "title"
                ]
            ]],
            accessToken: accessToken
        )
    }

    func replaceTabContent(
        documentID: String,
        tabID: String,
        bodyEndIndex: Int,
        plan: NotesMarkdownConverter.WritePlan,
        accessToken: String
    ) async throws {
        _ = try await batchUpdate(
            documentID: documentID,
            requests: plan.requests(tabId: tabID, existingBodyEndIndex: bodyEndIndex),
            accessToken: accessToken
        )
    }

    static func editURL(documentID: String, tabID: String?) -> URL? {
        var url = "https://docs.google.com/document/d/\(documentID)/edit"
        if let tabID, !tabID.isEmpty {
            url += "?tab=\(tabID)"
        }
        return URL(string: url)
    }

    // MARK: - HTTP

    private func request(
        url: URL,
        method: String,
        accessToken: String,
        body: [String: Any]?
    ) async throws -> [String: Any] {
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        }

        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]

        if !(200..<300).contains(status) {
            if let error = json["error"] as? [String: Any] {
                let message = error["message"] as? String ?? "Google Docs request failed (\(status))."
                throw GoogleDocsError.api(status: status, message: message)
            }
            throw GoogleDocsError.api(status: status, message: "Google Docs request failed (\(status)).")
        }
        return json
    }

    private func parseDocument(_ json: [String: Any]) -> GoogleDocument {
        let id = json["documentId"] as? String ?? ""
        let title = json["title"] as? String ?? ""
        let rawTabs = json["tabs"] as? [[String: Any]] ?? []
        return GoogleDocument(id: id, title: title, tabs: flattenTabs(rawTabs))
    }

    private func flattenTabs(_ tabs: [[String: Any]]) -> [GoogleTab] {
        var result: [GoogleTab] = []
        for tab in tabs {
            if let props = tab["tabProperties"] as? [String: Any],
               let id = props["tabId"] as? String {
                let title = props["title"] as? String ?? ""
                let body = (tab["documentTab"] as? [String: Any])?["body"] as? [String: Any]
                result.append(GoogleTab(id: id, title: title, bodyEndIndex: bodyEndIndex(body)))
            }
            if let children = tab["childTabs"] as? [[String: Any]] {
                result.append(contentsOf: flattenTabs(children))
            }
        }
        return result
    }

    private func bodyEndIndex(_ body: [String: Any]?) -> Int {
        guard let content = body?["content"] as? [[String: Any]],
              let last = content.last else { return 1 }
        return jsonInt(last["endIndex"]) ?? 1
    }

    private func parseAddedTabIDs(_ json: [String: Any]) -> [String] {
        guard let replies = json["replies"] as? [[String: Any]] else { return [] }
        var ids: [String] = []
        for reply in replies {
            guard let added = reply["addDocumentTab"] as? [String: Any] else { continue }
            if let id = added["tabId"] as? String {
                ids.append(id)
            } else if let props = added["tabProperties"] as? [String: Any],
                      let id = props["tabId"] as? String {
                ids.append(id)
            }
        }
        return ids
    }

    private func jsonInt(_ value: Any?) -> Int? {
        if let int = value as? Int { return int }
        if let number = value as? NSNumber { return number.intValue }
        return nil
    }
}
