//
//  NovelChapterLoader.swift
//  Vela
//
//  Loads a chapter URL off-screen, for the next-chapter and resume paths.
//
//  The browser tab's own web view cannot be used for this: navigating it would
//  move the page behind the reader and overwrite the tab's history. A private,
//  non-persistent web view fetches the chapter, runs the extractor, and is
//  released — no cookies are written, and the reader keeps its own position.
//
//  The view is small and never added to the hierarchy; WebKit still lays out
//  and executes a detached view, which is all the extractor needs.
//

import Foundation
import WebKit

final class NovelChapterLoader: NSObject, WKNavigationDelegate {    private var webView: WKWebView?
    private var continuation: CheckedContinuation<NovelExtraction?, Never>?
    private var timeoutTask: Task<Void, Never>?
    private var targetUrl = ""

    /// Loads and extracts one chapter. Resolves to `nil` on a bad URL, a
    /// navigation failure, or a page that does not look like a chapter.
    func load(urlString: String) async -> NovelExtraction? {
        finish(nil)

        let trimmed = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https" else {
            return nil
        }

        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true

        let webView = WKWebView(
            frame: CGRect(x: 0, y: 0, width: 1024, height: 2048),
            configuration: configuration
        )
        webView.navigationDelegate = self
        self.webView = webView
        self.targetUrl = url.absoluteString

        return await withCheckedContinuation { continuation in
            self.continuation = continuation
            webView.load(URLRequest(url: url))

            // A chapter page that hangs must not leave the reader on a spinner
            // forever. The timeout resolves the same way a failure does.
            self.timeoutTask = Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: 20_000_000_000)
                guard !Task.isCancelled else { return }
                self?.finish(nil)
            }
        }
    }

    /// Abandons the load in flight, resolving it as a failure.
    func cancel() {
        finish(nil)
    }

    private func finish(_ extraction: NovelExtraction?) {
        timeoutTask?.cancel()
        timeoutTask = nil
        guard let continuation else { return }
        self.continuation = nil
        webView?.navigationDelegate = nil
        webView?.stopLoading()
        webView = nil
        continuation.resume(returning: extraction)
    }

    // MARK: - WKNavigationDelegate

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard webView === self.webView else { return }
        let url = targetUrl
        Task { @MainActor [weak self] in
            let extraction = await NovelModeService.extract(from: webView, url: url)
            self?.finish(extraction)
        }
    }

    func webView(
        _ webView: WKWebView,
        didFail navigation: WKNavigation!,
        withError error: Error
    ) {
        guard webView === self.webView else { return }
        finish(nil)
    }

    func webView(
        _ webView: WKWebView,
        didFailProvisionalNavigation navigation: WKNavigation!,
        withError error: Error
    ) {
        guard webView === self.webView else { return }
        finish(nil)
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        guard webView === self.webView else { return }
        finish(nil)
    }
}
