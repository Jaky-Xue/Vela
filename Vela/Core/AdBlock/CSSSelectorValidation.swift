import Foundation
import WebKit

/// WebKit accepts malformed selectors when compiling a content rule list.
/// Validate with the DOM parser before publishing, in an empty private document.
@MainActor
final class CSSSelectorValidation: NSObject, WKNavigationDelegate {
    private static var accepted = Set<String>()
    private let web: WKWebView
    private var continuation: CheckedContinuation<Void, Error>?
    private var timeout: Task<Void, Never>?

    private override init() {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        web = WKWebView(frame: .zero, configuration: config)
        super.init()
        web.navigationDelegate = self
    }

    static func validate(_ selectors: [String]) async throws {
        let pending = Set(selectors).subtracting(accepted).sorted()
        guard !pending.isEmpty else { return }
        let validator = CSSSelectorValidation()
        try await validator.load()
        let invalid: [String] = try await withCheckedThrowingContinuation { continuation in
            validator.web.callAsyncJavaScript("""
                var invalid = [];
                for (var selector of selectors) {
                    try { document.querySelector(selector); }
                    catch (_) { invalid.push(selector); if (invalid.length >= 10) { break; } }
                }
                return invalid;
                """, arguments: ["selectors": pending], in: nil, in: .defaultClient) { result in
                    switch result {
                    case let .success(value): continuation.resume(returning: value as? [String] ?? ["无法验证选择器"])
                    case let .failure(error): continuation.resume(throwing: error)
                    }
                }
        }
        guard invalid.isEmpty else { throw FilterError.invalid("CSS 选择器无效：" + invalid.joined(separator: "、")) }
        if accepted.count + pending.count > 4_096 { accepted.removeAll() }
        accepted.formUnion(pending.prefix(4_096))
    }

    private func load() async throws {
        try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            timeout = Task { [weak self] in
                do { try await Task.sleep(nanoseconds: 5_000_000_000) } catch { return }
                self?.finish(URLError(.timedOut))
            }
            web.loadHTMLString("<!doctype html><html><body></body></html>", baseURL: nil)
        }
    }
    private func finish(_ error: Error?) {
        guard let continuation else { return }
        self.continuation = nil
        timeout?.cancel(); timeout = nil
        if let error { web.stopLoading(); continuation.resume(throwing: error) }
        else { continuation.resume() }
    }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { finish(nil) }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { finish(error) }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { finish(error) }
}
