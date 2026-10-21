//
//  WebViewHost.swift
//  Vela
//
//  Hosts a tab's pooled `WKWebView` inside SwiftUI.
//
//  The web surface belongs to the tab, not to the view tree, so the
//  representable here is an attachment point rather than an owner — and an
//  attachment point is *all* it is. It does not start loads.
//
//  That is a correction, not a simplification. This view used to load the tab's
//  URL itself whenever the hosted web view had no committed URL, on the theory
//  that a tab could arrive on screen with a URL and no page. Two things were
//  wrong with it:
//
//    * `webView.url == nil` stays true after a *failed* provisional navigation,
//      so the guard re-armed every time a load failed. A failure sets
//      `tab.isLoading` back to false, the shell observes that, the body
//      re-evaluates, and the view issued the request again — an unbounded retry
//      loop that also cleared `lastError` on each attempt, which is why a site
//      that could not be reached showed a permanently blank page rather than an
//      error.
//    * On success it raced `TabManager.load(url:in:)`, which had already issued
//      the same request, because `isLoading` is not reliably true at the instant
//      the request is handed over.
//
//  Starting the load belongs to the tab's lifecycle, where it happens whether or
//  not the tab is on screen. `TabManager` starts it and `activateTab` re-starts
//  it for a cold tab; see `BrowserTabState.needsPageFetch`.
//
//  Why a container view rather than returning the `WKWebView` directly from
//  `makeUIView`: SwiftUI calls `makeUIView` once per representable identity, but
//  `TabManager` creates and replaces a tab's web view under memory pressure. A
//  container lets the host swap which web view is attached without SwiftUI
//  tearing the representable down, which is what keeps the page from reloading
//  every time the tab strip changes.
//

import SwiftUI
import WebKit

struct WebViewHost: UIViewRepresentable {
    /// The web view to display. May change between updates when a tab is
    /// discarded and rebuilt.
    let webView: WKWebView
    /// The top content inset: the height of the status bar the page starts
    /// below and scrolls under.
    ///
    /// Set on the scroll view rather than by shrinking the web view's frame,
    /// because the page has to extend under it for the document to read as
    /// one surface — the same arrangement Safari uses. The inset stays fixed
    /// while the chrome hides, so the page does not jump under the user's
    /// finger; hiding the bar simply reveals more of the document.
    let topContentInset: CGFloat
    /// How much of the container's top the web view may not paint in — the
    /// 全局顶部保护 strip, the height of the status bar.
    ///
    /// Zero keeps the default arrangement: the web view owns the whole
    /// container and the page scrolls under the clock with only
    /// `topContentInset` keeping its first line clear. Non-zero pulls the web
    /// view's own frame down below the strip and clips the container, so the
    /// page never renders there at all and the shell's surface colour shows —
    /// which is why the two insets travel together: a reserved strip makes the
    /// page start at its own top, so the scroll inset becomes zero.
    let topReservedInset: CGFloat
    /// The bottom content inset: the command bar's height plus the safe area,
    /// so the page's last lines stay scrollable clear of the bar.
    let bottomContentInset: CGFloat
    /// Whether 强制网页缩放 is on. It does not pick a factor; it removes the
    /// page's zoom lock so the standard pinch gesture works.
    let allowsGestureZoom: Bool
    /// Reports scroll offset changes so the toolbar can react without a message
    /// round-trip on every frame.
    let onScroll: ((Double) -> Void)?
    /// Reports load progress in 0...1.
    ///
    /// Observed from the web view rather than read off the tab, because the tab
    /// only ever learns that a load started and that it finished — so a progress
    /// line fed from the tab sits at zero and then snaps to full.
    let onProgress: ((Double) -> Void)?

    func makeUIView(context: Context) -> WebViewContainerView {
        let container = WebViewContainerView()
        container.backgroundColor = .clear
        return container
    }

    func updateUIView(_ container: WebViewContainerView, context: Context) {
        // Restart the observation whenever the hosted web view changes, which
        // happens when a tab is discarded and rebuilt.
        if context.coordinator.observedWebView !== webView {
            context.coordinator.observe(webView: webView, onScroll: onScroll, onProgress: onProgress)
        }
        container.attach(webView)
        container.reservedTop = topReservedInset
        container.clipsToBounds = topReservedInset > 0

        let scrollView = webView.scrollView
        // The page runs to the bottom edge of the screen — a reserved strip
        // above the home indicator reads as something sitting on the page. The
        // insets are managed explicitly here (`.never` stops WebKit from adding
        // its own): the command bar's height at the bottom, and whatever the
        // shell passes for the top.
        if scrollView.contentInsetAdjustmentBehavior != .never {
            scrollView.contentInsetAdjustmentBehavior = .never
        }
        if scrollView.contentInset.top != topContentInset {
            scrollView.contentInset.top = topContentInset
            scrollView.verticalScrollIndicatorInsets.top = topContentInset
        }
        if scrollView.contentInset.bottom != bottomContentInset {
            scrollView.contentInset.bottom = bottomContentInset
            scrollView.verticalScrollIndicatorInsets.bottom = bottomContentInset
        }

        // Applying the zoom is deliberately not part of this update path.
        // SwiftUI re-runs it for every shell change — opening the omnibox,
        // raising the keyboard, a tab switch — and touching the scroll view's
        // zoom on each of those was enough to keep the layout machinery
        // re-entering itself. The host configures the limits once per hosted
        // web view/switch pair; the coordinator re-establishes them after each
        // document load, when WebKit resets them.
        context.coordinator.applyGestureZoomIfNeeded(webView, enabled: allowsGestureZoom)
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

    /// Observes a hosted web view's scroll offset and load progress.
    ///
    /// KVO on `contentOffset` rather than the injected scroll script: the offset
    /// is a property of the view, so observing it directly is both simpler and
    /// immune to a page that swallows scroll events or never installs the
    /// script. Progress is observed for the same reason — `estimatedProgress` is
    /// a `WKWebView` property, so there is nothing for a page to opt out of.
    final class Coordinator {
        private(set) var observedWebView: WKWebView?
        private var offsetObservation: NSKeyValueObservation?
        private var progressObservation: NSKeyValueObservation?
        /// Progress arrives on every WebKit tick. The shell is an observable
        /// object, so writing each tick invalidates the whole view tree tens of
        /// times a second. Deliver at most ten per second, except for the two
        /// edges (start and finish) which must be immediate.
        private var latestProgress: Double = 0
        private var lastProgressDelivery: TimeInterval = 0
        private var progressDeliveryTask: Task<Void, Never>?
        private var progressHandler: ((Double) -> Void)?

        private var zoomedWebView: WKWebView?
        private var appliedGestureZoom: Bool?
        private var zoomedUrl: String?
        /// The scroll view's own limits before 强制缩放 changed them, so
        /// turning the switch off restores what the page asked for.
        private var originalZoomRange: (min: CGFloat, max: CGFloat)?

        func observe(webView: WKWebView, onScroll: ((Double) -> Void)?, onProgress: ((Double) -> Void)?) {
            stopObserving()
            observedWebView = webView
            progressHandler = onProgress
            // A different web view has its own scroll view and its own zoom.
            zoomedWebView = nil
            appliedGestureZoom = nil
            zoomedUrl = nil
            originalZoomRange = nil

            if let onScroll {
                offsetObservation = webView.scrollView.observe(\.contentOffset, options: [.new]) { scrollView, _ in
                    // Normalised against the top inset, so the number the shell
                    // sees is the distance from the document's own top rather
                    // than the raw offset — which starts at minus the inset,
                    // since the scroll view rests there when the page is at
                    // its top.
                    let offset = Double(scrollView.contentOffset.y + scrollView.contentInset.top)
                    // WebKit reports the offset on the main thread; the hop makes
                    // that explicit for the SwiftUI state write it triggers.
                    Task { @MainActor in
                        onScroll(offset)
                    }
                }
            }

            if let onProgress {
                // `initial` so a tab that is already mid-load when it becomes
                // visible reports where it actually is rather than waiting for
                // the next change.
                progressObservation = webView.observe(\.estimatedProgress, options: [.new, .initial]) { [weak self] webView, _ in
                    let progress = webView.estimatedProgress
                    // A new load resets WebKit's scroll view limits; drop the
                    // cache so the next update re-establishes them.
                    if progress <= 0.01 {
                        self?.zoomedWebView = nil
                        self?.appliedGestureZoom = nil
                        self?.zoomedUrl = nil
                    }
                    self?.receiveProgress(progress)
                }
            }
        }

        /// Configures the pinch limits once per web view/switch pair.
        ///
        /// Nothing is applied on every layout pass: opening the omnibox or
        /// raising the keyboard re-runs the host, and touching the scroll
        /// view's zoom on each of those was what made input focus unstable.
        func applyGestureZoomIfNeeded(_ webView: WKWebView, enabled: Bool) {
            let url = webView.url?.absoluteString ?? ""
            if zoomedWebView === webView,
               appliedGestureZoom == enabled,
               zoomedUrl == url {
                return
            }
            let scrollView = webView.scrollView
            guard webView.window != nil, scrollView.bounds.width > 0 else { return }

            if enabled {
                if originalZoomRange == nil {
                    originalZoomRange = (scrollView.minimumZoomScale, scrollView.maximumZoomScale)
                }
                scrollView.minimumZoomScale = 0.5
                scrollView.maximumZoomScale = 3.0
                scrollView.pinchGestureRecognizer?.isEnabled = true
            } else {
                if let original = originalZoomRange {
                    if abs(scrollView.zoomScale - 1) > 0.001 {
                        scrollView.setZoomScale(1, animated: false)
                    }
                    scrollView.minimumZoomScale = original.min
                    scrollView.maximumZoomScale = original.max
                    originalZoomRange = nil
                }
                // Never forced on this view: leave the page's own limits alone.
            }
            zoomedWebView = webView
            appliedGestureZoom = enabled
            zoomedUrl = url
        }

        func stopObserving() {
            offsetObservation?.invalidate()
            offsetObservation = nil
            progressObservation?.invalidate()
            progressObservation = nil
            progressDeliveryTask?.cancel()
            progressDeliveryTask = nil
            progressHandler = nil
            latestProgress = 0
            lastProgressDelivery = 0
            observedWebView = nil
            zoomedWebView = nil
            appliedGestureZoom = nil
            zoomedUrl = nil
            originalZoomRange = nil
        }

        private func receiveProgress(_ progress: Double) {
            guard progressHandler != nil else { return }
            latestProgress = progress
            let now = Date().timeIntervalSinceReferenceDate
            let isEdge = progress <= 0.01 || progress >= 0.999
            if isEdge || now - lastProgressDelivery >= 0.1 {
                deliverProgress()
            } else if progressDeliveryTask == nil {
                progressDeliveryTask = Task { @MainActor [weak self] in
                    try? await Task.sleep(nanoseconds: 100_000_000)
                    guard !Task.isCancelled else { return }
                    self?.progressDeliveryTask = nil
                    self?.deliverProgress()
                }
            }
        }

        private func deliverProgress() {
            progressDeliveryTask?.cancel()
            progressDeliveryTask = nil
            guard let handler = progressHandler else { return }
            lastProgressDelivery = Date().timeIntervalSinceReferenceDate
            let value = latestProgress
            Task { @MainActor in
                handler(value)
            }
        }

        deinit {
            offsetObservation?.invalidate()
            progressObservation?.invalidate()
            progressDeliveryTask?.cancel()
        }
    }
}

/// A view that hosts exactly zero or one pooled web view as a subview.
final class WebViewContainerView: UIView {
    private weak var attachedWebView: WKWebView?
    /// The top constraint's constant carries `reservedTop` across re-attaches,
    /// so a web view swapped in under memory pressure lands below the strip
    /// the previous one was held to.
    private var topConstraint: NSLayoutConstraint?

    /// How much of the container's top the web view is held below.
    var reservedTop: CGFloat = 0 {
        didSet { topConstraint?.constant = reservedTop }
    }

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
        let top = webView.topAnchor.constraint(equalTo: topAnchor, constant: reservedTop)
        NSLayoutConstraint.activate([
            top,
            webView.leadingAnchor.constraint(equalTo: leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: trailingAnchor),
            webView.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
        topConstraint = top
        attachedWebView = webView
    }

    /// Removes the web view from the hierarchy without releasing it.
    ///
    /// The removal is guarded on the web view still being *this* container's
    /// subview, because the ordering of SwiftUI teardown is not guaranteed: a
    /// tab switch builds the new host — which attaches the same pooled web view,
    /// moving it out of this one — before the old representable is dismantled.
    /// Removing unconditionally there would detach the web view from the host
    /// that just claimed it, and the tab would go blank until the next update
    /// pass happened to re-attach it.
    func detachWebView() {
        guard let webView = attachedWebView else { return }
        attachedWebView = nil
        if webView.superview === self {
            webView.removeFromSuperview()
        }
    }
}
