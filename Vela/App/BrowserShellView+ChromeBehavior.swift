import QuartzCore
import SwiftUI
import UIKit
import WebKit

extension BrowserShellView {
    func resetChromeDrag() {
        chromeDragOffset = 0
        chromeLiftOffset = 0
        chromeHomeArmed = false
        chromeDragIsVertical = false
        // Whatever reset this was belongs with a move of the chrome, and the
        // page's layout settles after one (see `handleScroll`).
        scrollTracker.chromeChangedAt = CACurrentMediaTime()
    }

    /// Reacts to the bar's drag starting and finishing, including the finish
    /// SwiftUI never reports through `onEnded`.
    ///
    /// A cancelled drag — a tab switch, a call banner, another recogniser
    /// taking the finger — never reaches `onEnded`. Without this the bar kept
    /// the distance it had followed, or the fade it had reached, and read as
    /// having gone missing or drifted off its edge; the next drag also skipped
    /// its axis test, because the interrupted one had already decided the axis.
    /// A fresh drag starts clean, and one that ends without `onEnded` springs
    /// home here.
    func handleChromeDragFlight(_ inFlight: Bool) {
        if inFlight {
            chromeDragIsVertical = false
            return
        }
        // `onEnded` springs the offsets back itself; only a drag that never
        // got there still has anything left to put away.
        if chromeDragOffset != 0 || chromeLiftOffset != 0 || chromeHomeArmed {
            withAnimation(BrowserMotion.settle(reduceMotion)) {
                resetChromeDrag()
            }
        }
    }

    // MARK: - Scrolling

    /// Collapses the chrome as the page scrolls down and restores it when the
    /// user turns back.
    ///
    /// The decision itself lives in `ShellScrollTracker.consume`, where both
    /// sides are thresholds on travel: a deliberate downward distance to hide,
    /// and an upward reversal that holds for a couple of frames to show. The
    /// asymmetry still favours the return — getting the controls back is the
    /// user's intent far more often than hiding them again — but "upward" has
    /// to mean the user, not the page: bounce and scroll anchoring are what
    /// used to flip the bar back and forth on busy pages.
    func handleScroll(offset: Double) {
        // An open omnibox or an active find pins the chrome: the user is
        // working in it, and sliding it away mid-sentence would be hostile.
        // The offset is still tracked while pinned — the search page can move
        // the page under it, and a stale reading here would make the first
        // scroll after closing it jump by that distance.
        guard !omnibox.isEditing, !showFindBar else {
            scrollTracker.lastOffset = offset
            scrollTracker.resetTravel()
            return
        }

        // The page is still settling from a chrome move. The bar's strip
        // changes the page's layout viewport on iOS 26, and a document resting
        // at its end clamps as the viewport grows or shrinks; those samples
        // are the layout moving, not the finger. Reading them as a gesture is
        // what would throw the bar straight back out and in — the occasional
        // bar that reappeared on its own while the page was still reflowing.
        // The window outlasts WebKit's layout pass rather than just the bar's
        // animation, because the clamp arrives with the former.
        if CACurrentMediaTime() - scrollTracker.chromeChangedAt < 0.9 {
            scrollTracker.lastOffset = offset
            scrollTracker.resetTravel()
            return
        }

        switch scrollTracker.consume(offset: offset, now: CACurrentMediaTime()) {
        case .hide:
            setChromeHidden(true)
        case .show:
            setChromeHidden(false)
        case .none:
            break
        }
    }

    func setChromeHidden(_ hidden: Bool) {
        guard chromeHidden != hidden else { return }
        // Whatever distance was being counted belonged to the state that just
        // ended; carrying it into the next one would let a few stray points
        // flip the bar straight back.
        scrollTracker.resetTravel()
        // The page's layout viewport moves with the bar on iOS 26, and the
        // samples that follow a move are the layout settling rather than the
        // finger. `handleScroll` ignores them for a moment.
        scrollTracker.chromeChangedAt = CACurrentMediaTime()
        if !hidden {
            // A drag that was interrupted (an edge swipe, a tab switch, a
            // call banner) never reaches `onEnded`. Leaving its offset behind
            // parks the bar displaced or fully transparent, which reads as the
            // bar having gone missing rather than as having come back.
            chromeDragOffset = 0
            chromeLiftOffset = 0
            chromeHomeArmed = false
            chromeDragIsVertical = false
            padChromeDragTranslation = 0
            padChromeHomeArmed = false
            padChromeHideArmed = false
        }
        withAnimation(BrowserMotion.chrome(reduceMotion)) {
            chromeHidden = hidden
        }
    }
}
