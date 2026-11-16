//
//  BrowserShellView.swift
//  Vela
//
//  The browser screen: the web surface, the top command bar, and every overlay
//  the shell can present.
//
//  This file is the entry point and the environment host. The window's
//  presentation and chrome state lives in `ShellState` (App/Shell/); the
//  composition, content, chrome, gestures, observers and actions live in
//  focused extensions. Navigation and WebKit lifecycle remain owned by their
//  existing services.
//
//  The chrome is one command bar at the bottom of the screen — back and
//  forward, the omnibox, tabs and the menu — floating on Liquid Glass above
//  the page. There is no other bar: every secondary action (bookmarks,
//  history, find, reader, desktop site, share) lives in the menu, which is
//  what keeps the bar down to five controls. The page runs full-bleed, the
//  way Safari's does, so the glass has content to refract; the web view's
//  top content inset holds the page's own start point below the status bar,
//  the bottom inset keeps its tail clear of the bar, and the whole bar
//  slides away when the user scrolls down and returns on any upward
//  movement. The keyboard never moves it: a site's own input field raising
//  the keyboard is no reason for the browser's controls to leave the edge
//  they live on.
//
//  The omnibox session — the debounced suggestion list, the highlighted row,
//  the disclosure state — lives in `OmniboxViewModel` rather than here, which
//  is what keeps the suggestion list, the field text and the editing flag from
//  being three pieces of state that have to be kept in step by hand. It is
//  deliberately not part of `ShellState`: that object owns what the window
//  shows, not what a text field is doing.
//

import QuartzCore
import SwiftUI
import UIKit
import WebKit
import UniformTypeIdentifiers

struct BrowserShellView: View {
    @Environment(AppEnvironment.self) var env
    @Environment(\.browserPalette) var palette
    @Environment(\.colorScheme) var colorScheme
    @Environment(\.scenePhase) var scenePhase
    @Environment(\.horizontalSizeClass) var horizontalSizeClass

    /// The window's presentation, overlay, chrome and geometry state. One
    /// object, so no two booleans can disagree about what is on screen.
    ///
    /// Internal rather than private: the shell's own extension files read it
    /// through the forwarding accessors in `BrowserShellView+State.swift`.
    @State var shell: ShellState

    /// The omnibox session. Created here rather than inside the view body
    /// because it is long-lived: it survives every tab switch, and rebuilding it
    /// would throw away the user's collapsed-section choices on each one.
    @State var omnibox: OmniboxViewModel

    @Environment(\.accessibilityReduceMotion) var reduceMotion

    @MainActor
    init(environment: AppEnvironment) {
        _shell = State(initialValue: ShellState())
        _omnibox = State(initialValue: OmniboxViewModel(
            settings: environment.settings,
            history: environment.history,
            bookmarks: environment.bookmarks,
            searchHistory: environment.searchHistory,
            tabManager: environment.tabManager
        ))
    }

    var tabManager: TabManager { env.tabManager }

    /// The shared navigation decisions; one value so the toolbar, menu and
    /// hardware commands cannot drift apart.
    var navigationActions: BrowserNavigationActions {
        BrowserNavigationActions(
            tabManager: env.tabManager,
            webCoordinator: env.webCoordinator
        )
    }

    var activeTab: BrowserTabState? { tabManager.activeTab }

    /// Whether the drag-to-hide gesture may act.
    ///
    /// The one state that refuses it is the open omnibox session, where a
    /// downward drag means dismissing the keyboard. Every surface — the home
    /// one included — hides the bar the same way: the bar is the page's
    /// controls, and a page the user is pushing out of the way takes its
    /// controls with it.
    var canDragChromeAway: Bool {
        guard !omnibox.isEditing else { return false }
        return activeTab != nil
    }

    static let padSidebarWidth: CGFloat = 286
    /// The top bar's laid-out height: 46 for the glass row plus its 8/6 gaps.
    static var padTopBarHeight: CGFloat { 8 + BrowserChrome.barHeight + 6 }

    /// Whether the shell draws the iPad layout.
    ///
    /// 自动 follows the device and the window: an iPad in a regular-width
    /// window gets the two-column chrome, a phone or a narrow iPad Split View
    /// window keeps the single column.
    var usesPadLayout: Bool {
        switch env.settings.interfaceLayout {
        case .phone:
            return false
        case .pad:
            return true
        case .automatic:
            return UIDevice.current.userInterfaceIdiom == .pad && horizontalSizeClass == .regular
        }
    }

    /// What the bottom chrome takes from a surface's tail.
    ///
    /// In the phone layout the home indicator's inset is part of the
    /// clearance: the native surfaces — home, reader and the error page —
    /// reserve this much so their last row stays above the floating bar. The
    /// web view is cleared by the host itself, which ends its frame at the
    /// bar's top edge and adds the inset from the window. In the iPad layout
    /// the content column already ends at the safe area, and only the
    /// floating bar overlaps it.
    var bottomChromeClearance: CGFloat {
        // The iPad layout puts the navigation in a top bar, so the page can run
        // to the bottom edge of its column.
        usesPadLayout
            ? 0
            : safeBottom + BrowserChrome.barHeight + BrowserChrome.barGap
    }

    var body: some View {
        presentations()
    }
}
