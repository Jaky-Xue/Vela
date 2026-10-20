//
//  NovelTOCLoader.swift
//  Vela
//
//  Loads a table-of-contents page off-screen and extracts its chapter list.
//
//  Kept separate from `NovelChapterLoader` because the two parse different
//  documents and a TOC load should never interfere with the chapter the reader
//  is showing. Both use a non-persistent web view, so neither writes cookies.
//

import Foundation
import WebKit

final class NovelTOCLoader: NSObject, WKNavigationDelegate {
    private var webView: WKWebView?
    private var continuation: CheckedContinuation<[NovelTOCEntry]?, Never>?
    private var timeoutTask: Task<Void, Never>?

    func load(urlString: String) async -> [NovelTOCEntry]? {
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

        return await withCheckedContinuation { continuation in
            self.continuation = continuation
            webView.load(URLRequest(url: url))
            self.timeoutTask = Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: 25_000_000_000)
                guard !Task.isCancelled else { return }
                self?.finish(nil)
            }
        }
    }

    func cancel() {
        finish(nil)
    }

    private func finish(_ entries: [NovelTOCEntry]?) {
        timeoutTask?.cancel()
        timeoutTask = nil
        guard let continuation else { return }
        self.continuation = nil
        webView?.navigationDelegate = nil
        webView?.stopLoading()
        webView = nil
        continuation.resume(returning: entries)
    }

    // MARK: - WKNavigationDelegate

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard webView === self.webView else { return }
        Task { @MainActor [weak self] in
            // A catalog on a hash-routed site is usually built from an API
            // response after the shell loads. Poll, and give the list time to
            // populate, rather than reading an empty `#app` once.
            let delays: [UInt64] = [800_000_000, 1_200_000_000, 1_600_000_000]
            for delay in delays {
                try? await Task.sleep(nanoseconds: delay)
                guard !Task.isCancelled else { return }
                if let entries = await NovelModeService.extractTOC(from: webView), !entries.isEmpty {
                    self?.finish(entries)
                    return
                }
            }
            self?.finish(nil)
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
