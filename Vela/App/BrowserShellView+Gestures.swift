import SwiftUI
import UIKit
import WebKit

extension BrowserShellView {
    // MARK: - Screen-edge swipe back

    /// Whether the screen-edge swipe may act.
    ///
    /// Where the web view has history, WebKit's own interactive edge-swipe is
    /// the gesture — animated and cancellable — and this one stands down so
    /// the two never fight over the same finger. It earns its keep exactly
    /// where that gesture cannot act: a page whose history is empty (the
    /// swipe falls through to the tab that opened it, then the home surface),
    /// an error surface covering the web view, and the home surface with a
    /// page behind it.
    var edgeSwipeBackEnabled: Bool {
        // The novel reader is its own layer with its own gestures; an edge
        // swipe there would pop reader mode or navigate the page underneath it.
        guard novelSession == nil else { return false }
        guard !omnibox.isEditing, !showFindBar else { return false }
        // Layers that own the screen. A swipe inside them belongs to them,
        // not to the page they cover.
        guard !showTabsOverview, !showQRScanner, !showPadSidebar else { return false }
        guard let tab = activeTab else { return false }
        if tab.isHome { return !tab.url.isEmpty }
        if tab.loadState.isFailure { return true }
        guard tabManager.webView(for: tab.id) != nil else { return false }
        // Every page has a back step — its own history, the tab that opened
        // it, or the home fallback — and WebKit's interactive gesture is off,
        // so the arrow owns the edge in all of them.
        return true
    }

    /// The swipe's progress as a fraction of the window's width. Drives the
    /// page's corner radius, scale and shadow, so the motion is one continuous
    /// value rather than a set of keyframes.
    var swipeBackProgress: CGFloat {
        guard safeRectWidth > 0 else { return 0 }
        return min(max(swipeBackTranslation / safeRectWidth, 0), 1)
    }

    /// The page does not move during an edge swipe.
    ///
    /// The gesture is drawn by its own arrow at the edge — the Android
    /// predictive-back shape — so releasing a completed swipe does not tear
    /// the document off the screen the user was reading. The wrapper stays
    /// because both layouts call it; the identity is the design.
    @ViewBuilder
    func swipeBackTransformed<V: View>(_ view: V) -> some View {
        view
    }

    func handleSwipeBackChanged(_ translation: CGFloat) {
        guard edgeSwipeBackEnabled, !isSwipeBackCompleting else { return }
        isSwipeBackTracking = true
        swipeBackTranslation = max(0, translation)
        let armed = safeRectWidth > 0 && swipeBackTranslation > safeRectWidth * 0.18
        if armed != swipeBackArmed {
            swipeBackArmed = armed
            if armed {
                UIImpactFeedbackGenerator(style: .medium).impactOccurred()
            }
        }
    }

    func handleSwipeBackEnded(_ translation: CGFloat, velocity: CGFloat) {
        guard isSwipeBackTracking, !isSwipeBackCompleting else { return }
        isSwipeBackTracking = false
        swipeBackArmed = false

        let width = max(safeRectWidth, 320)
        // A short but fast flick completes; so does a slow drag past roughly
        // a fifth of the screen. Anything else springs home.
        let shouldComplete = translation > width * 0.18 || velocity > 450

        guard shouldComplete else {
            withAnimation(BrowserMotion.settle(reduceMotion)) {
                swipeBackTranslation = 0
            }
            return
        }

        isSwipeBackCompleting = true
        let swipedTabId = activeTab?.id
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        // Nothing slides off the edge now — the arrow is the whole animation —
        // so the navigation completes on the next runloop instead of waiting
        // out a page transition.
        DispatchQueue.main.async {
            // A swipe belongs to the page it started on; do not go back on a
            // tab the user switched to between the press and the release.
            guard activeTab?.id == swipedTabId else {
                var transaction = Transaction()
                transaction.disablesAnimations = true
                withTransaction(transaction) {
                    swipeBackTranslation = 0
                }
                isSwipeBackCompleting = false
                return
            }
            handleEdgeSwipeBack()
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) {
                swipeBackTranslation = 0
            }
            isSwipeBackCompleting = false
        }
    }

    func handleSwipeBackCancelled() {
        guard isSwipeBackTracking else { return }
        isSwipeBackTracking = false
        swipeBackArmed = false
        withAnimation(BrowserMotion.settle(reduceMotion)) {
            swipeBackTranslation = 0
        }
    }

    func handleEdgeSwipeBack() {
        guard novelSession == nil else { return }
        guard !omnibox.isEditing, !showFindBar else { return }
        guard activeTab != nil else { return }
        goBack()
    }

    // MARK: - Back and forward availability

    /// Whether the back button should be live.
    ///
    /// True on any page, not only on a page with history: backing out of the
    /// first page of a tab returns to the home surface rather than doing
    /// nothing.
    ///
    /// True on the home surface too, when there is a page behind it. The home
    /// surface is not a document — it is the shell choosing to show the native
    /// surface instead of the web view, which still holds the page — so backing
    /// out of it returns to that page rather than walking WebKit's list. That
    /// distinction matters: with the old code, pressing back from the home
    /// surface called `goBack()` on the hidden web view, which stepped one
    /// entry *further* down the history and re-opened the page before the one
    /// the user had actually been reading.
    var canGoBack: Bool {
        guard let tab = activeTab else { return false }
        if tab.isHome { return !tab.url.isEmpty }
        return true
    }
}
