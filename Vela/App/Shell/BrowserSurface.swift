//
//  BrowserSurface.swift
//  Vela
//
//  The main surface the shell is showing.
//
//  The shell has exactly one main surface at a time, and the novel reader is
//  one of them rather than a layer beside the page: while a reader is open it
//  owns the screen, and every chrome decision — the command bar, the edge
//  swipe, the tabs button — is made from that fact. Modelling it here makes
//  "a reader over the error page over the home" impossible to write, because
//  there is only ever one value.
//
//  Overlays are the other half of the model and live in `ShellOverlay`: things
//  that cover the surface without replacing it (the menu, the overview, the
//  find bar, a settings sheet).
//

import Foundation

/// What the shell's content column is showing.
enum BrowserSurface: Equatable {
    /// The native start page. A destination of its own, not a mode: the tab
    /// keeps its page underneath and can be returned to it.
    case home
    /// The page the active tab holds.
    case page
    /// The novel reader. Its session carries the shelf, the source tab and the
    /// privacy generation, so the surface itself is enough to reconstruct
    /// every decision the reader makes.
    case novel(NovelSession)
    /// The navigation error surface, shown instead of the page it replaced.
    case error

    /// The reader's session, when this surface is one.
    var novelSession: NovelSession? {
        if case let .novel(session) = self { return session }
        return nil
    }

    /// Whether a reader owns the screen.
    var isNovel: Bool { novelSession != nil }
}
