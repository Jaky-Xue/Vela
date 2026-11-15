//
//  BrowserShellView.swift
//  Vela
//
//  The browser screen: the web surface, the top command bar, and every overlay
//  the shell can present.
//
//  The shell owns scene-local presentation state. Composition, content,
//  observers and actions live in focused extensions; navigation and WebKit
//  lifecycle remain owned by their existing services.
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
//  being three pieces of state that have to be kept in step by hand.
//

import QuartzCore
import SwiftUI
import UIKit
import WebKit
import UniformTypeIdentifiers

/// A presentation requested from the menu panel.
///
/// The menu is itself a sheet; a destination it opens is a second one. They
/// are two steps now — close, then present — rather than one update that asks
/// UIKit to do both at once.
enum MenuPresentation: Equatable {
    case addBookmark
    case share
    case bookmarks
    case history
    case downloads
    case offlinePages
    case settings
    case bookshelf
    case passwords
    case qrScanner
}

struct BrowserShellView: View {
    @Environment(AppEnvironment.self) var env
    @Environment(\.browserPalette) var palette
    @Environment(\.colorScheme) var colorScheme
    @Environment(\.scenePhase) var scenePhase
    @Environment(\.horizontalSizeClass) var horizontalSizeClass

    /// The omnibox session. Created here rather than inside the view body
    /// because it is long-lived: it survives every tab switch, and rebuilding it
    /// would throw away the user's collapsed-section choices on each one.
    @State var omnibox: OmniboxViewModel

    @Environment(\.accessibilityReduceMotion) var reduceMotion
    @State var showSiteCapabilities = false
    @State var showTabsOverview = false
    /// A print of the real home surface taken before the overview covers it.
    /// The home is native SwiftUI, so it has no web view to photograph; this
    /// is what the home tab's card shows instead of an invented miniature.
    @State var homePreview: UIImage?
    /// The home tab the print belongs to. A preview taken in 无痕 mode must
    /// never appear on a regular home card after a mode switch.
    @State var homePreviewTabId: String?
    @State var showQRScanner = false
    @State var qrCopyNotice: String?
    @State var showBookmarks = false
    @State var showHistory = false
    @State var showDownloads = false
    @State var showSettings = false
    /// The screen the settings sheet should open above its root.
    @State var settingsDestination: SettingsDestination?
    @State var showPasswords = false
    @State var showBookshelf = false
    /// The service the presented shelf belongs to. Captured when the sheet
    /// opens, so a tab switch behind it cannot swap the shelf's database.
    @State var bookshelfLibrary: NovelLibraryService?
    @State var bookshelfIsPrivate = false
    @State var bookshelfGeneration = 0
    /// The tab the shelf was opened from. A private shelf's reader uses it as
    /// the source for "open in browser"; it is never inferred from the active
    /// tab later.
    @State var bookshelfSourceTabId = ""
    @State var showMenu = false
    /// A screen the menu asked for. Presenting it is deferred until the menu
    /// sheet's dismissal has completed: showing a second sheet in the same
    /// update as `showMenu = false` is a UIKit presentation race, and it is
    /// what made 添加书签 and 书签 occasionally read as dead or wedge. The
    /// menu sheet's `onDismiss` runs the request.
    @State var pendingMenuPresentation: MenuPresentation?
    /// Whether the iPad layout's sidebar drawer is open.
    @State var showPadSidebar = false
    @State var showAddBookmarkChoice = false
    @State var showShareSheet = false
    @State var showFindBar = false
    /// The shelf of saved offline pages.
    @State var showOfflinePages = false
    /// A one-line result from saving a page: "已保存" or the reason it failed.
    @State var offlineNotice: String?
    @State var findQuery = ""
    /// The debounce behind the find field. Typing is what runs the search.
    @State var findDebounceTask: Task<Void, Never>?

    /// The novel reader's layer, when one is open.
    ///
    /// It is a value rather than two optionals so opening a different book or
    /// chapter is one assignment; the reader itself owns the loading that
    /// follows.
    @State var novelSession: NovelSession?
    /// Why 小说模式 could not open the page.
    @State var novelNotice: String?

    /// Set when an omnibox submission was refused, so the shell can say why
    /// instead of closing the field as if nothing had happened.
    @State var addressNotice: String?
    /// The input that was refused, kept so the alert can offer to search for it.
    @State var rejectedInput = ""

    /// Whether the command bar has slid out of the way under the status bar.
    @State var chromeHidden = false
    /// How far the user has dragged the bar downward, mid-gesture.
    ///
    /// The bar follows the finger while the drag is in progress and either
    /// commits to hiding or springs back when the finger lifts. Never read in
    /// `body` except through the two modifiers below, so the per-frame writes
    /// cost nothing beyond the offset itself.
    @State var chromeDragOffset: CGFloat = 0
    /// How far the user has dragged the bar upward, mid-gesture — the gesture
    /// that returns to the home surface. The bar lifts a little with the
    /// finger as the promise of what releasing will do.
    @State var chromeLiftOffset: CGFloat = 0
    /// Whether that upward drag has passed the distance that opens the home
    /// surface. Drives the hint's filled state and its haptic.
    @State var chromeHomeArmed = false
    /// Whether the command bar's drag has committed to its vertical axis.
    ///
    /// Decided once per gesture rather than re-derived from the running
    /// translation: a thumb drag is never perfectly straight, and judging it
    /// by the total at release is what let a clear downward swipe read as a
    /// sideways one.
    @State var chromeDragIsVertical = false
    /// The iPad top bar's vertical drag: how far the finger has moved and
    /// which of its two releases is armed.
    @State var padChromeDragTranslation: CGFloat = 0
    @State var padChromeHomeArmed = false
    @State var padChromeHideArmed = false

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
    /// Per-frame scroll bookkeeping, kept out of `@State`.
    ///
    /// Writing `@State` on every scroll message invalidates the shell's body
    /// each frame — exactly the layout work that shows up as dropped frames
    /// while a page scrolls. The box changes without touching SwiftUI; only
    /// the `chromeHidden` threshold transition re-renders.
    @State var scrollTracker = ShellScrollTracker()

    /// The keyboard's height while visible, from the frame-change notifications.
    ///
    /// The suggestion card's height budget is measured down to the keyboard's
    /// top edge — a card that ignores the keyboard is a card whose last rows
    /// can never be reached.
    @State var keyboardHeight: CGFloat = 0
    /// The safe-area insets and the height of the safe-area rectangle, measured
    /// once the view is in the hierarchy and again on rotation.
    @State var safeTop: CGFloat = 0
    @State var safeBottom: CGFloat = 0
    @State var safeRectHeight: CGFloat = 0
    @State var safeRectWidth: CGFloat = 0
    /// Where the shell itself begins in the window. SwiftUI lays the shell
    /// inside the safe area, so this is the status-bar height; a search page
    /// overlay inherits that origin and must not add the inset again.
    @State var shellOriginY: CGFloat = 0
    /// The window's height, which is the only height an overlay-origin offset
    /// and a keyboard occlusion can be compared against.
    @State var windowHeight: CGFloat = 0

    /// The page's horizontal offset while an edge swipe is tracking, and the
    /// two flags that keep the interactive gesture from overlapping itself.
    @State var swipeBackTranslation: CGFloat = 0
    @State var isSwipeBackTracking = false
    @State var isSwipeBackCompleting = false
    /// Whether the drag has passed the distance that commits the back action.
    /// Drives the filled state of the arrow and its one haptic.
    @State var swipeBackArmed = false

    /// The one animation the chrome uses.
    ///
    /// A spring rather than an ease: the bar leaves and returns along a path
    /// the user's own scroll is also moving, and an ease-out over a fixed
    /// duration reads as a separate, laggier movement next to the page.
    static let chromeAnimation = Animation.spring(response: 0.32, dampingFraction: 0.86)

    /// The tab drawer's motion: a spring with a little overshoot, so the
    /// floating panel arrives like a physical sheet rather than a rectangle
    /// travelling on rails.
    static let sidebarAnimation = Animation.spring(response: 0.44, dampingFraction: 0.72)

    /// The edge swipe's settle: a spring soft enough that a released page
    /// glides home instead of snapping, and quick enough that a completed
    /// swipe does not wait on it.
    static let swipeBackSettle = Animation.spring(response: 0.36, dampingFraction: 0.84)

    @MainActor
    init(environment: AppEnvironment) {
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
