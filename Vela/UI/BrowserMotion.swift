//
//  BrowserMotion.swift
//  Vela
//
//  The app's motion language, in one place.
//
//  Motion in Vela is not decoration laid over the interface; it is how the
//  shell explains what just happened. A surface that is replaced, a panel that
//  arrives, a bar that yields to the page — each has one curve, chosen for the
//  size of the thing moving and the weight it should carry.
//
//  The rules, in order:
//
//    1. Restraint over bounce. Nothing here overshoots by more than a couple of
//       points; a browser that boings reads as a toy.
//    2. Large surfaces move slowly, small feedback moves quickly. An overview
//       rising from the bottom edge earns a longer curve than a press.
//    3. One protagonist at a time. When two things animate together — the
//       reader arriving as the command bar leaves — they share a curve, so the
//       eye follows one movement rather than two.
//    4. Reduce Motion is not an afterthought. Every public entry point either
//       returns a short ease or no animation at all; the caller never has to
//       remember the check.
//
//  Callers pass the environment's `accessibilityReduceMotion` value in. Keeping
//  the decision here rather than at each call site is what stops one forgotten
//  animation from ignoring the system setting.
//

import SwiftUI

enum BrowserMotion {
    // MARK: - Curves

    // The constants below are the raw curves. Prefer the named functions in
    // the next section: those are the ones that know about Reduce Motion.

    /// Press feedback and other acknowledgements that must feel immediate.
    static let crisp = Animation.spring(response: 0.26, dampingFraction: 0.9)

    /// The command bar, the search page and the chrome that moves with the
    /// page. Tuned to the scroll it accompanies: the bar leaves on the same
    /// beat as the finger, not a fixed ease behind it.
    static let standard = Animation.spring(response: 0.32, dampingFraction: 0.86)

    /// Layout changes inside a surface — a shelf reflowing, a tile settling
    /// into its slot. Softer than `standard`, because nothing is leaving.
    static let gentle = Animation.spring(response: 0.38, dampingFraction: 0.92)

    /// Panels with physical weight: the iPad sidebar drawer, the menu's grid.
    /// A little overshoot is the point; it is what makes them read as objects.
    static let expressive = Animation.spring(response: 0.44, dampingFraction: 0.72)

    /// A released gesture returning home: the edge swipe's settle, the drag of
    /// a tile that did not move. Quick enough that the completed action never
    /// waits on it.
    static let tracking = Animation.spring(response: 0.36, dampingFraction: 0.84)

    /// The surface swap — home to page — is the largest thing that changes in
    /// the shell, so it gets the longest curve in the set.
    private static let surfaceCurve = Animation.spring(response: 0.46, dampingFraction: 0.92)

    /// The tab overview rises from the bottom edge; a spring with a little
    /// give reads as a layer being lifted into place.
    private static let overviewCurve = Animation.spring(response: 0.42, dampingFraction: 0.9)

    /// A secondary sheet's own content, when it animates a change of state.
    /// Softer than the system's presentation so the two do not fight.
    private static let sheetCurve = Animation.spring(response: 0.38, dampingFraction: 0.92)

    /// The reader's arrival. Ceremonial but not slow: it covers the page, so it
    /// must not make the user wait for it.
    private static let novelCurve = Animation.spring(response: 0.44, dampingFraction: 0.9)

    /// One-line results and banners. Fast, lightly damped, gone by the time
    /// the eye has read the text.
    private static let noticeCurve = Animation.spring(response: 0.34, dampingFraction: 0.92)

    /// The background and material are full-screen and always present, so they
    /// cross-fade rather than move: a slow, symmetric ease is what makes a
    /// change of field read as the choice taking effect.
    private static let backdropCurve = Animation.easeInOut(duration: 0.38)

    /// The reduced-motion replacement. Short enough to be perceived as a cut,
    /// with a fade so nothing blinks into place.
    private static let quiet = Animation.easeOut(duration: 0.12)

    // MARK: - Named transitions

    /// The command bar, the search page and the find bar.
    static func chrome(_ reduced: Bool) -> Animation { reduced ? quiet : standard }

    /// The tab overview rising from the bottom, and the drawer that follows
    /// the same rule.
    static func overview(_ reduced: Bool) -> Animation { reduced ? quiet : overviewCurve }

    /// The main surface changing: home ↔ page, page ↔ error, and the page
    /// yielding to the reader.
    static func surface(_ reduced: Bool) -> Animation { reduced ? quiet : surfaceCurve }

    /// A secondary sheet's content changing state behind its system
    /// presentation.
    static func sheet(_ reduced: Bool) -> Animation { reduced ? quiet : sheetCurve }

    /// A menu or home tile being carried. Optional because a carried tile must
    /// track the finger exactly — with Reduce Motion there is no animation at
    /// all, and the grid reflows in place.
    static func tileDrag(_ reduced: Bool) -> Animation? {
        reduced ? nil : .spring(response: 0.32, dampingFraction: 0.82)
    }

    /// The background field, the material, and the transition between them.
    static func backdrop(_ reduced: Bool) -> Animation { reduced ? quiet : backdropCurve }

    /// The novel reader taking the screen.
    static func novelEnter(_ reduced: Bool) -> Animation { reduced ? quiet : novelCurve }

    /// A notice, a banner, or any one-line answer the shell shows the user.
    static func notice(_ reduced: Bool) -> Animation { reduced ? quiet : noticeCurve }

    // MARK: - Companions

    /// Layout changes inside a surface (shelf reflow, list insertion). Kept
    /// optional to match the call sites that switch animation off entirely.
    static func layout(_ reduced: Bool) -> Animation? { reduced ? nil : gentle }

    /// The iPad sidebar drawer: weight, a little overshoot.
    static func sidebar(_ reduced: Bool) -> Animation { reduced ? quiet : expressive }

    /// A released edge-swipe returning to rest.
    static func settle(_ reduced: Bool) -> Animation { reduced ? quiet : tracking }

    /// A control's press feedback.
    static func press(_ reduced: Bool) -> Animation? { reduced ? nil : crisp }

    /// A drag hint filling in, or a small state label changing.
    static func hint(_ reduced: Bool) -> Animation? {
        reduced ? nil : .easeOut(duration: 0.15)
    }

    /// Switching tabs cross-fades two documents; it is the one transition
    /// deliberately shorter than the rest, because it happens under the
    /// finger's own timing.
    static func tabSwitch(_ reduced: Bool) -> Animation {
        reduced ? quiet : .easeInOut(duration: 0.18)
    }
}
