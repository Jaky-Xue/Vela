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
import UIKit
import WebKit

struct WebViewHost: UIViewRepresentable {
    /// The web view to display. May change between updates when a tab is
    /// discarded and rebuilt.
    let webView: WKWebView
    /// Where the page's content should start, measured from the *window's*
    /// top edge.
    ///
    /// Absolute rather than a scroll inset because the host cannot assume
    /// where SwiftUI places it: the shell asks for an edge-to-edge host, but
    /// whether the representable actually starts at the window's top edge or
    /// at the safe-area rectangle is a layout detail. The container subtracts
    /// its own position from this value, so the same number produces the
    /// right inset in either arrangement — and, together with the reserved
    /// strip, never double-counts the status bar.
    let topContentOffset: CGFloat
    /// Whether 全局顶部保护 is on: the page starts below the status bar and
    /// never paints under the clock.
    ///
    /// The strip is measured from the *window*, and from the container's own
    /// position in it: the shell is laid out inside the safe area, so a
    /// `GeometryReader` placed in it reports zero insets, and a host that is
    /// already below the status bar must not reserve the strip a second time.
    ///
    /// Off, the web view owns the whole container and the page scrolls under
    /// the clock with only the scroll inset keeping its first line clear.
    /// On, the web view's own frame is pulled below the uncovered part of the
    /// strip and the container clips, so the page never renders there at all
    /// and the shell's surface colour shows.
    let protectsStatusBar: Bool
    /// The status-bar strip, measured from the window's top edge.
    ///
    /// Passed by the shell as well as read from the window: the two come from
    /// different measurements, and a first layout pass can see either one as
    /// zero. Taking the larger of the two is what keeps 全局顶部保护 from
    /// deciding there is no strip to reserve and leaving the page under the
    /// clock.
    let statusBarStrip: CGFloat
    /// The command bar's height plus its gap, or zero when the page owns the
    /// whole bottom edge.
    ///
    /// The page keeps its full layout and stays full bleed: it paints to the
    /// bottom edge, and the bar floats translucently over it, so the document
    /// is visible through the glass rather than ending above a reserved band.
    /// The container adds the window's home-indicator inset, so the number
    /// stays right on the first layout pass and through a rotation. Only the
    /// scroll view's bottom inset is reserved — enough for the document's own
    /// last lines to be scrolled clear of the bar while it is up.
    let bottomChromeHeight: CGFloat
    /// The colour the page paints behind itself, used behind the document
    /// while it bounces. The page itself covers the screen, so the bar samples
    /// the document rather than a painted strip.
    let pageColor: Color
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
        container.topContentOffset = topContentOffset
        container.protectsStatusBar = protectsStatusBar
        container.statusBarStrip = statusBarStrip

        let pageColour = UIColor(pageColor)
        // Overscroll shows the colour WebKit paints behind the document;
        // matching it to the page keeps a dark site from flashing white at
        // either end of a bounce.
        if webView.underPageBackgroundColor != pageColour {
            webView.underPageBackgroundColor = pageColour
        }
        // The view's own background is the second place white comes from: a
        // page's composited layer that is transparent in the wrong spot — a
        // rounded card, an embedded frame, a dialog's backdrop — shows this
        // colour, and it is white until someone says otherwise. It is the
        // app's canvas, not the page's: a page's own sample can name a white
        // surface it paints in a corner, and painting that behind the whole
        // document is exactly how a dark page grows a pale rectangle. The
        // web view's forced appearance resolves this colour, so the canvas is
        // black in dark mode and white in light.
        let canvasColour = UIColor.systemBackground
        if webView.backgroundColor != canvasColour {
            webView.backgroundColor = canvasColour
        }

        let scrollView = webView.scrollView
        // WebKit's own inset adjustment is off: the container owns the top,
        // because it is the only view that knows where it sits relative to the
        // window's status bar.
        if scrollView.contentInsetAdjustmentBehavior != .never {
            scrollView.contentInsetAdjustmentBehavior = .never
        }

        // The container owns the bottom geometry: it adds the window's
        // home-indicator inset and applies the scroll inset that keeps the
        // document's last lines reachable above the bar.
        container.bottomChromeHeight = bottomChromeHeight

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

    /// Where the page's content should start, from the window's top edge.
    var topContentOffset: CGFloat = 0 {
        didSet { updateTopLayout() }
    }

    /// Whether the page is held below the status bar.
    var protectsStatusBar: Bool = false {
        didSet { updateTopLayout() }
    }

    /// The status-bar strip as the shell measured it. The window's own inset is
    /// used as well; the larger of the two wins, so a first pass that reads
    /// either as zero cannot leave the page under the clock.
    var statusBarStrip: CGFloat = 0 {
        didSet { updateTopLayout() }
    }

    /// The command bar's height plus its gap, or zero when the page owns the
    /// whole bottom edge.
    var bottomChromeHeight: CGFloat = 0 {
        didSet {
            guard abs(bottomChromeHeight - oldValue) > 0.5 else { return }
            updateBottomLayout()
        }
    }

    /// The part of the web view's bottom the command bar and the home
    /// indicator cover.
    private var resolvedBottomInset: CGFloat = 0

    /// How much of the container's top the web view is held below.
    private var reservedTop: CGFloat = 0 {
        didSet { topConstraint?.constant = reservedTop }
    }

    /// Observes the window's safe area, so a pass that ran before the insets
    /// resolved is corrected even if no frame change follows.
    private var safeAreaObservation: NSKeyValueObservation?

    override func didMoveToWindow() {
        super.didMoveToWindow()
        safeAreaObservation?.invalidate()
        safeAreaObservation = window?.observe(\.safeAreaInsets, options: [.new]) { [weak self] _, _ in
            DispatchQueue.main.async {
                self?.setNeedsLayout()
            }
        }
        updateTopLayout()
        updateBottomLayout()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        // The container's position and the window's safe area can change
        // without a window change: rotation, a call banner, the status bar
        // coming back from a fullscreen video, a Stage Manager resize.
        updateTopLayout()
        updateBottomLayout()
    }

    /// Resolves how much of the web view's bottom the chrome covers.
    ///
    /// The bar's top edge is `safeBottom + chromeHeight` above the window's
    /// bottom — the shell lays the floating bar out inside the safe area and
    /// owes only its gap from there. Measuring against the container's own
    /// frame keeps either arrangement honest and stops the home indicator
    /// being counted twice.
    private func updateBottomLayout() {
        guard let window else {
            if resolvedBottomInset != 0 {
                resolvedBottomInset = 0
                applyBottomInsets()
            }
            return
        }
        // Zero means the page owns the whole bottom edge — the bar is hidden,
        // or this is the iPad layout — so the home indicator is not an
        // obstruction to reserve for.
        let barTopFromWindow = bottomChromeHeight > 0
            ? window.safeAreaInsets.bottom + bottomChromeHeight
            : 0
        let frameInWindow = convert(bounds, to: window)
        let containerBottomFromWindow = max(0, window.bounds.maxY - frameInWindow.maxY)
        let resolved = max(0, barTopFromWindow - containerBottomFromWindow)
        if abs(resolvedBottomInset - resolved) > 0.5 {
            resolvedBottomInset = resolved
            applyBottomInsets()
        }
    }

    /// The scroll inset that makes the document's end reachable above the bar.
    /// The page's layout is deliberately not shrunk: the bar floats over it,
    /// and the document's own content is what shows through the glass.
    private func applyBottomInsets() {
        guard let scrollView = attachedWebView?.scrollView,
              abs(scrollView.contentInset.bottom - resolvedBottomInset) > 0.5 else { return }
        scrollView.contentInset.bottom = resolvedBottomInset
        scrollView.verticalScrollIndicatorInsets.bottom = resolvedBottomInset
    }

    /// Resolves both halves of the top layout from the window.
    ///
    /// * The **reserved strip** is the part of the status bar this container
    ///   does not already sit below. A host SwiftUI placed edge to edge needs
    ///   the full inset; one already laid out inside the safe area needs
    ///   nothing. Reserving the full inset without this subtraction doubled
    ///   the gap.
    /// * The **scroll inset** is whatever remains between the web view's top
    ///   and the requested content offset. It is applied only when it changes,
    ///   so a layout pass cannot chase itself.
    private func updateTopLayout() {
        guard let window else { return }

        let originY = convert(CGPoint.zero, to: window).y
        let resolved = Self.topLayout(
            originY: originY,
            safeTop: window.safeAreaInsets.top,
            statusBarStrip: statusBarStrip,
            desiredContentTop: topContentOffset,
            protectsStatusBar: protectsStatusBar
        )
        if abs(reservedTop - resolved.reserved) > 0.5 {
            reservedTop = resolved.reserved
        }
        clipsToBounds = resolved.reserved > 0.5

        if let scrollView = attachedWebView?.scrollView,
           abs(scrollView.contentInset.top - resolved.inset) > 0.5 {
            scrollView.contentInset.top = resolved.inset
            scrollView.verticalScrollIndicatorInsets.top = resolved.inset
        }
    }

    /// The pure arithmetic behind the top layout.
    ///
    /// Split out so the four arrangements — edge-to-edge or already inside the
    /// safe area, protection on or off — are pinned by tests rather than only
    /// by trying them on a device.
    nonisolated static func topLayout(
        originY: CGFloat,
        safeTop: CGFloat,
        statusBarStrip: CGFloat? = nil,
        desiredContentTop: CGFloat,
        protectsStatusBar: Bool
    ) -> (reserved: CGFloat, inset: CGFloat) {
        // Two measurements of the same strip, taken in different places. The
        // larger one wins: a zero from either source is a timing artefact, not
        // an answer.
        let strip = max(0, max(safeTop, statusBarStrip ?? 0))
        let reserved = protectsStatusBar ? max(0, strip - originY) : 0
        let desired = max(0, desiredContentTop)
        let inset = max(0, desired - (originY + reserved))
        return (reserved, inset)
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
        // A re-attached web view inherits this container's current strip and
        // scroll insets rather than whatever its previous container left.
        updateTopLayout()
        updateBottomLayout()
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
