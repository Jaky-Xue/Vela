//
//  WebViewHost.swift
//  Vela
//
//  Hosts a tab's pooled `WKWebView` inside SwiftUI.
//
//  Ported in spirit from `BrowserHostedWebOwnershipCoordinator.ets` and
//  `BrowserHostedWebLayerGeometryCache.ets` (Aira Browser 3.7.4, GPL-3.0). Aira
//  has to solve the same problem for ArkWeb: the web surface is owned by the
//  tab, not by the view tree, so a "view" for it is really an attachment.
//
//  Why a container view rather than returning the `WKWebView` directly from
//  `makeUIView`: SwiftUI calls `makeUIView` once per representable identity, but
//  a tab's web view is created and replaced by `TabManager` under memory
//  pressure. A container lets the host swap which web view is attached without
//  SwiftUI tearing the representable down, which is what keeps the page from
//  reloading every time the tab strip changes.
//

import SwiftUI
import WebKit

struct WebViewHost: UIViewRepresentable {
    /// The web view to display. May change between updates when a tab is
    /// discarded and rebuilt.
    let webView: WKWebView
    /// The URL to load when the web view has no page yet.
    let initialUrl: String?
    /// True when the tab is showing the native home surface, in which case the
    /// web view is detached entirely.
    let isHome: Bool
    /// Reports scroll offset changes so the toolbar can react without a message
    /// round-trip on every frame.
    let onScroll: ((Double) -> Void)?

    func makeUIView(context: Context) -> WebViewContainerView {
        let container = WebViewContainerView()
        container.backgroundColor = .clear
        return container
    }

    func updateUIView(_ container: WebViewContainerView, context: Context) {
        // Restart the scroll observation whenever the hosted web view changes,
        // which happens when a tab is discarded and rebuilt.
        if context.coordinator.observedWebView !== webView {
            context.coordinator.observe(webView: webView, onScroll: onScroll)
        }

        if isHome {
            container.detachWebView()
            return
        }

        container.attach(webView)

        // Load only when the page has never been loaded. Checking `url == nil`
        // rather than comparing against `initialUrl` is deliberate: a redirect
        // or an in-page history change makes the web view's URL differ from the
        // one the tab holds, and reloading on that difference would fight the
        // page.
        if webView.url == nil, let initialUrl, let url = URL(string: initialUrl), !initialUrl.isEmpty {
            webView.load(URLRequest(url: url))
        } else if webView.url == nil, initialUrl == nil || initialUrl!.isEmpty {
            // A tab created empty but not flagged as home still needs something
            // to show, otherwise the surface is a blank white rectangle.
            webView.loadHTMLString(Self.blankPageHtml, baseURL: nil)
        }
    }

    static func dismantleUIView(_ container: WebViewContainerView, coordinator: Coordinator) {
        // Detach without destroying: the web view belongs to the tab pool and
        // outlives this view.
        container.detachWebView()
        coordinator.stopObserving()
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    /// Observes a hosted web view's scroll offset.
    ///
    /// KVO on `contentOffset` rather than the injected scroll script: the offset
    /// is a property of the view, so observing it directly is both simpler and
    /// immune to a page that swallows scroll events or never installs the
    /// script.
    final class Coordinator {
        private(set) var observedWebView: WKWebView?
        private var observation: NSKeyValueObservation?

        func observe(webView: WKWebView, onScroll: ((Double) -> Void)?) {
            stopObserving()
            observedWebView = webView
            guard let onScroll else { return }
            observation = webView.scrollView.observe(\.contentOffset, options: [.new]) { scrollView, _ in
                let offset = Double(scrollView.contentOffset.y)
                // WebKit reports the offset on the main thread; the hop makes
                // that explicit for the SwiftUI state write it triggers.
                Task { @MainActor in
                    onScroll(offset)
                }
            }
        }

        func stopObserving() {
            observation?.invalidate()
            observation = nil
            observedWebView = nil
        }

        deinit {
            observation?.invalidate()
        }
    }

    /// Shown for a tab that has no URL and is not on the home surface. Kept
    /// minimal and themed by the injected colour so it does not flash white in
    /// dark mode.
    private static let blankPageHtml = """
    <!doctype html>
    <html>
    <head>
      <meta name="viewport" content="width=device-width, initial-scale=1, viewport-fit=cover">
      <style>
        html, body {
          margin: 0;
          height: 100%;
          background: -apple-system-systemBackground;
        }
      </style>
    </head>
    <body></body>
    </html>
    """
}

/// A view that hosts exactly zero or one pooled web view as a subview.
final class WebViewContainerView: UIView {
    private weak var attachedWebView: WKWebView?

    /// Attaches `webView` as the sole subview, adding it only when it is not
    /// already attached.
    ///
    /// Re-adding the same instance on every SwiftUI update would reset its
    /// frame and, on a web view mid-load, can drop the current input connection.
    func attach(_ webView: WKWebView) {
        guard attachedWebView !== webView else { return }
        detachWebView()

        webView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(webView)
        NSLayoutConstraint.activate([
            webView.topAnchor.constraint(equalTo: topAnchor),
            webView.leadingAnchor.constraint(equalTo: leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: trailingAnchor),
            webView.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
        attachedWebView = webView
    }

    /// Removes the web view from the hierarchy without releasing it.
    func detachWebView() {
        guard let webView = attachedWebView else { return }
        webView.removeFromSuperview()
        attachedWebView = nil
    }
}
