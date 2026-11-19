import QuartzCore
import SwiftUI
import UIKit
import WebKit

/// What a scroll sample asks the chrome to do.
enum ChromeScrollAction: Equatable {
    case none
    case hide
    case show
}

/// Mutable scroll bookkeeping for the shell. A reference box so per-frame
/// writes do not invalidate the view tree.
///
/// The whole decision lives here rather than in the shell so it can be pinned
/// by tests: collapsing the chrome is a small state machine with thresholds on
/// both sides, and the two failures that matter — a bar that will not stay
/// hidden and a bar that flickers with a page that jiggles — are both decided
/// by these numbers.
final class ShellScrollTracker {
    var lastOffset: Double = 0
    /// Downward distance accumulated toward the next hide.
    var accumulation: CGFloat = 0
    /// Upward distance since the last downward step. Kept separate so a
    /// bounce's small negative steps do not zero the hide in progress.
    var upwardTravel: CGFloat = 0
    /// When the current upward run began, in `CACurrentMediaTime` seconds, or
    /// -1 when no run is in progress. A reversal has to hold for a moment —
    /// one frame of drift must not bring the bar back.
    var upwardBeganAt: CFTimeInterval = -1
    /// When the chrome last changed state, in `CACurrentMediaTime` seconds.
    ///
    /// The page's layout viewport changes with the bar on iOS 26: the strip the
    /// bar covered is handed back to the page, and a document resting at its
    /// end clamps to the new range. Those samples are the layout settling, not
    /// the finger — reading them as a gesture is what would throw the bar
    /// straight back out and in.
    var chromeChangedAt: CFTimeInterval = -1

    /// Downward travel that commits a hide. Small enough that a flick hides
    /// the bar in a couple of frames, large enough that a single jiggle does
    /// not.
    static let hideDistance: CGFloat = 44
    /// Upward travel that asks for the controls back.
    static let showDistance: CGFloat = 20
    /// How long that upward travel has to hold. Two frames at 60 Hz; a
    /// deliberate swipe crosses it without noticing, a one-frame page shift
    /// does not.
    static let showSustain: CFTimeInterval = 0.045
    /// Movement in a single sample beyond this is the document re-laying
    /// itself out rather than a finger.
    static let jumpDistance: Double = 140

    func resetTravel() {
        accumulation = 0
        upwardTravel = 0
        upwardBeganAt = -1
    }

    /// Folds one scroll offset into the state and says what the chrome should
    /// do about it.
    func consume(offset: Double, now: CFTimeInterval) -> ChromeScrollAction {
        let previous = lastOffset
        lastOffset = offset
        let delta = offset - previous

        // At the top of the document the bar is always back; there is nothing
        // above the page start to hide it for.
        if offset <= 2 {
            resetTravel()
            return .show
        }

        // More movement in one sample than a finger can produce — a lazy image
        // landing above the viewport, a script scrolling to an anchor, the
        // page restoring its own position — is the document moving under the
        // user, not the user scrolling. Re-baseline on it rather than count it
        // toward either threshold.
        if abs(delta) > Self.jumpDistance {
            resetTravel()
            return .none
        }

        guard abs(delta) > 0.25 else { return .none }

        if delta > 0 {
            // Downward travel accumulates toward a hide. A flick reports
            // smaller steps than a slow drag, so the threshold is measured in
            // distance travelled rather than in any single step.
            upwardTravel = 0
            upwardBeganAt = -1
            accumulation = max(0, accumulation + CGFloat(delta))
            if accumulation > Self.hideDistance {
                resetTravel()
                return .hide
            }
            return .none
        }

        // An upward flick is a request for the controls, but it has to be a
        // *reversal*: a page that oscillates by a few points — bounce at the
        // end of a fling, scroll anchoring as lazy content arrives, a sticky
        // header pushed back into place — was flipping the bar on every frame
        // of its jiggle. Asking for a little distance and a little time costs
        // a deliberate swipe two frames and ignores the jitter entirely. Small
        // negative steps still must not erase the distance already travelled
        // toward a hide.
        if upwardBeganAt < 0 { upwardBeganAt = now }
        upwardTravel -= CGFloat(delta)
        if upwardTravel > Self.showDistance, now - upwardBeganAt >= Self.showSustain {
            resetTravel()
            return .show
        }
        return .none
    }
}
