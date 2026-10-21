//
//  NovelChapterLoader.swift
//  Vela
//
//  Loads a chapter URL off-screen, for the next-chapter and resume paths.
//
//  The browser tab's own web view cannot be used for this: navigating it would
//  move the page behind the reader and overwrite the tab's history. An
//  off-screen web view fetches the chapter, runs the extractor, and is
//  released. Its data store is injected: the default session for ordinary
//  reading, the window's private store for private reading.
//
//  The view is small and never added to the hierarchy; WebKit still lays out
//  and executes a detached view, which is all the extractor needs.
//

import Foundation
import UIKit
import WebKit

final class NovelChapterLoader: NSObject, WKNavigationDelegate {
    private var webView: WKWebView?
    private var continuation: CheckedContinuation<NovelExtraction?, Never>?
    private var timeoutTask: Task<Void, Never>?
    /// The extraction poll started by `didFinish`; `finish` cancels it so a
    /// reader that closes does not leave a loop running against a released view.
    private var pollingTask: Task<Void, Never>?
    /// The off-window container the web view is parked in while it renders.
    private weak var renderingHost: UIView?
    private var targetUrl = ""

    /// Loads and extracts one chapter. Resolves to `nil` on a bad URL, a
    /// navigation failure, or a page that does not look like a chapter.
    func load(
        urlString: String,
        dataStore: WKWebsiteDataStore = .default()
    ) async -> NovelExtraction? {
        finish(nil)

        let trimmed = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https" else {
            return nil
        }

        // The store is injected: ordinary reading shares the default session,
        // while a private reader passes the window's private store so the
        // chapter request cannot write into the regular profile.
        let configuration = NovelLoaderConfiguration.make(dataStore: dataStore)

        let webView = WKWebView(
            frame: CGRect(x: 0, y: 0, width: 1024, height: 2048),
            configuration: configuration
        )
        webView.navigationDelegate = self
        self.webView = webView
        self.targetUrl = url.absoluteString

        return await withCheckedContinuation { continuation in
            self.continuation = continuation
            attachOffscreen(webView)
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
        pollingTask?.cancel()
        pollingTask = nil
        guard let continuation else { return }
        self.continuation = nil
        detachOffscreen()
        webView?.navigationDelegate = nil
        webView?.stopLoading()
        webView = nil
        continuation.resume(returning: extraction)
    }

    // MARK: - Off-screen rendering

    /// A detached web view loads, but a single-page reader often holds its
    /// first paint until it believes it is visible. Parking the view just
    /// outside the window keeps it rendering the way it does in a tab without
    /// showing a pixel.
    private func attachOffscreen(_ webView: WKWebView) {
        guard let scene = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .first(where: { $0.activationState == .foregroundActive })
            ?? UIApplication.shared.connectedScenes
                .compactMap({ $0 as? UIWindowScene })
                .first,
            let window = scene.windows.first(where: { $0.isKeyWindow }) ?? scene.windows.first else {
            return
        }
        let host = UIView(frame: CGRect(x: -12_000, y: -12_000, width: 1024, height: 2048))
        host.alpha = 0.01
        host.isUserInteractionEnabled = false
        webView.frame = host.bounds
        host.addSubview(webView)
        window.addSubview(host)
        renderingHost = host
    }

    private func detachOffscreen() {
        webView?.removeFromSuperview()
        renderingHost?.removeFromSuperview()
        renderingHost = nil
    }

// MARK: - WKNavigationDelegate

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard webView === self.webView else { return }
        // A chapter URL often redirects to the site's canonical form; the
        // extraction and the shelf should both use the page that actually
        // loaded, or a return visit would re-run the redirect every time.
        let url = webView.url?.absoluteString ?? targetUrl
        pollingTask?.cancel()
        pollingTask = Task { @MainActor [weak self] in
            // Hash-routed sites paint the chapter after didFinish — and some
            // paint it behind two or three network round-trips. Poll for the
            // extraction instead of trusting a single delay.
            let delays: [UInt64] = [1_000_000_000, 1_500_000_000, 2_000_000_000, 2_500_000_000]
            for delay in delays {
                try? await Task.sleep(nanoseconds: delay)
                guard !Task.isCancelled else { return }
                if let extraction = await NovelModeService.extract(from: webView, url: url) {
                    self?.finish(extraction)
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
