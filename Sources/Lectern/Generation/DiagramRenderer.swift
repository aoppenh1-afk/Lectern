import CryptoKit
import Foundation
import WebKit

/// Renders mermaid diagram code to SVG using a bundled, offline mermaid.js
/// inside an offscreen WKWebView. Results are cached on disk by content hash.
@MainActor
final class DiagramRenderer {
    static let shared = DiagramRenderer()

    private var webView: WKWebView?
    private var pageReady = false
    private let cacheDirectory: URL

    private init() {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        cacheDirectory = caches.appendingPathComponent("LecternDiagrams", isDirectory: true)
        try? FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
    }

    func render(code: String) async throws -> Data {
        let key = Self.cacheKey(for: code)
        let cachedURL = cacheDirectory.appendingPathComponent("\(key).svg")

        if let cached = try? Data(contentsOf: cachedURL), !cached.isEmpty {
            return cached
        }

        let svgString = try await renderOffscreen(code: code)
        let svgData = Data(svgString.utf8)
        try? svgData.write(to: cachedURL)
        return svgData
    }

    private static func cacheKey(for code: String) -> String {
        SHA256.hash(data: Data(code.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private func renderOffscreen(code: String) async throws -> String {
        guard let jsURL = Bundle.main.url(forResource: "mermaid", withExtension: "js"),
              let mermaidSource = try? String(contentsOf: jsURL, encoding: .utf8) else {
            throw RendererError.mermaidUnavailable
        }

        let view = try ensureWebView()

        if !pageReady {
            let bootstrap = """
            <!DOCTYPE html>
            <html><head><meta charset="utf-8"><style>body{margin:0;background:transparent;}</style></head>
            <body><script>\(mermaidSource)</script>
            <script>
                window.mermaid.initialize({ startOnLoad: false, theme: 'neutral', securityLevel: 'loose' });
                window.__lecternReady = true;
            </script></body></html>
            """
            await view.loadPage(bootstrap)

            for _ in 0..<50 where !pageReady {
                let flag = try? await view.evaluateJavaScript("window.__lecternReady === true")
                if (flag as? Bool) == true {
                    pageReady = true
                    break
                }
                try await Task.sleep(for: .milliseconds(100))
            }
            guard pageReady else { throw RendererError.mermaidUnavailable }
        }

        // Base64 keeps arbitrary diagram text safe inside the JS string.
        let encoded = Data(code.utf8).base64EncodedString()
        let script = """
        (async () => {
            const bytes = atob("\(encoded)");
            const code = decodeURIComponent(bytes.split('').map(c => '%' + c.charCodeAt(0).toString(16).padStart(2, '0')).join(''));
            const { svg } = await window.mermaid.render("d" + Date.now() + Math.floor(Math.random() * 1000), code);
            return svg;
        })()
        """

        do {
            let result = try await view.evaluateJavaScript(script)
            guard let svg = result as? String, svg.contains("<svg") else {
                throw RendererError.emptyOutput
            }
            return svg
        } catch let error as RendererError {
            throw error
        } catch {
            throw RendererError.diagramFailed(error.localizedDescription)
        }
    }

    private func ensureWebView() throws -> WKWebView {
        if let webView { return webView }
        let configuration = WKWebViewConfiguration()
        let preferences = WKWebpagePreferences()
        preferences.allowsContentJavaScript = true
        configuration.defaultWebpagePreferences = preferences
        let view = WKWebView(frame: NSRect(x: 0, y: 0, width: 900, height: 700),
                             configuration: configuration)
        self.webView = view
        return view
    }

    enum RendererError: LocalizedError {
        case mermaidUnavailable
        case emptyOutput
        case diagramFailed(String)

        var errorDescription: String? {
            switch self {
            case .mermaidUnavailable: return "The bundled diagram renderer failed to load."
            case .emptyOutput: return "Diagram rendering produced no output."
            case .diagramFailed(let detail): return "Diagram failed: \(detail)"
            }
        }
    }
}

private extension WKWebView {
    func loadPage(_ html: String) async {
        let capture = PageLoadCapture()
        navigationDelegate = capture
        loadHTMLString(html, baseURL: nil)
        await capture.wait(timeoutSeconds: 15)
    }

    /// Resumes exactly once when the page finishes loading or times out.
    final class PageLoadCapture: NSObject, WKNavigationDelegate, @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<Void, Never>?
        private var finished = false

        func wait(timeoutSeconds: TimeInterval) async {
            await withCheckedContinuation { checkedIn in
                lock.lock()
                self.continuation = checkedIn
                lock.unlock()

                DispatchQueue.main.asyncAfter(deadline: .now() + timeoutSeconds) { [weak self] in
                    self?.finish()
                }
            }
        }

        private func finish() {
            lock.lock()
            let pendingContinuation = continuation
            continuation = nil
            if finished {
                lock.unlock()
                return
            }
            finished = true
            lock.unlock()
            pendingContinuation?.resume()
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { finish() }
        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { finish() }
        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { finish() }
    }
}
