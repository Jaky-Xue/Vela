//
//  NovelTOCLoader.swift
//  Vela
//
//  Loads a table-of-contents page off-screen and extracts its chapter list.
//
//  Kept separate from `NovelChapterLoader` because the two parse different
//  documents and a TOC load should never interfere with the chapter the reader
//  is showing. Their data store is injected: ordinary reading shares the
//  browser's session, while a private reader uses the window's private store.
//

import Foundation
import UIKit
import WebKit

final class NovelTOCLoader: NSObject, WKNavigationDelegate {
    private var webView: WKWebView?
    private var continuation: CheckedContinuation<[NovelTOCEntry]?, Never>?
    private var timeoutTask: Task<Void, Never>?
    /// The extraction poll started by `didFinish`; `finish` cancels it so a
    /// reader that closes does not leave a loop running against a released view.
    private var pollingTask: Task<Void, Never>?
    /// The off-window container the web view is parked in while it renders.
    private weak var renderingHost: UIView?

    func load(
        urlString: String,
        dataStore: WKWebsiteDataStore = .default()
    ) async -> [NovelTOCEntry]? {
        finish(nil)

        let trimmed = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https" else {
            return nil
        }

        // The store is injected: ordinary reading shares the default session,
        // while a private reader passes the window's private store so loading
        // the catalog cannot write into the regular profile.
        let configuration = NovelLoaderConfiguration.make(dataStore: dataStore)

        let webView = WKWebView(
            frame: CGRect(x: 0, y: 0, width: 1024, height: 2048),
            configuration: configuration
        )
        webView.navigationDelegate = self
        self.webView = webView

        return await withCheckedContinuation { continuation in
            self.continuation = continuation
            attachOffscreen(webView)
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
        pollingTask?.cancel()
        pollingTask = nil
        guard let continuation else { return }
        self.continuation = nil
        detachOffscreen()
        webView?.navigationDelegate = nil
        webView?.stopLoading()
        webView = nil
        continuation.resume(returning: entries)
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
        pollingTask?.cancel()
        pollingTask = Task { @MainActor [weak self] in
            // A catalog on a hash-routed site is usually built from an API
            // response after the shell loads. Poll, and give the list time to
            // populate, rather than reading an empty `#app` once.
            let delays: [UInt64] = [1_000_000_000, 2_000_000_000, 3_000_000_000]
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
