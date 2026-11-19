//
//  ShellState.swift
//  Vela
//
//  The browser window's one state machine.
//
//  Before this type the shell kept its presentation flags, its chrome drag
//  offsets, its safe-area measurements and its session notices in thirty-odd
//  separate `@State` properties. Nothing tied them together: the menu could be
//  closed while its destination was already presenting, a tab switch could
//  leave a find bar over the new document, and every new screen added another
//  boolean to keep in step by hand.
//
//  `ShellState` is the single owner of that half of the shell. It is not a
//  view model for the page — `OmniboxViewModel`, `TabManager` and the
//  coordinator keep their own state, and the omnibox deliberately stays out of
//  here. What lives here is exactly what belongs to the window rather than to a
//  document:
//
//    * which main surface is showing (`BrowserSurface`);
//    * which overlays are on screen (`ShellOverlay`);
//    * the menu's one deferred request;
//    * the chrome's transient geometry (hidden, dragged, sampled);
//    * the keyboard, safe-area and window measurements;
//    * the edge swipe's in-flight values;
//    * one-line notices the shell shows above everything else.
//
//  Views read it through the shell's forwarding accessors, and present or
//  dismiss overlays through the small API at the bottom of this file rather
//  than assigning booleans.
//

import Foundation
import Observation
import SwiftUI
import UIKit

@MainActor
@Observable
final class ShellState {
    // MARK: - Surface

    /// The main surface the shell is showing.
    ///
    /// Opened and closed through the shell; a tab change refreshes the
    /// non-novel half through `syncBaseSurface`. While a reader is open the
    /// surface is `.novel` and tab changes do not replace it — the reader owns
    /// the screen until it closes.
    var surface: BrowserSurface = .home

    // MARK: - Overlays

    /// The layers on screen. Private so every mutation goes through
    /// `present`/`dismiss`, which is what keeps two overlays of the same kind
    /// from stacking.
    private(set) var overlays: Set<ShellOverlay> = []

    /// A destination the menu asked for, waiting for the menu sheet to finish
    /// dismissing.
    ///
    /// Presenting a second sheet in the same update as `dismiss(.menu)` is a
    /// UIKit presentation race — it is what made 添加书签 and 书签 occasionally
    /// read as dead or wedge. `handleMenuAction` only writes here; the menu
    /// sheet's `onDismiss` runs `performPendingMenuPresentation`.
    var pendingMenuPresentation: MenuPresentation?

    /// How the shell opens a bookshelf on a deferred request.
    ///
    /// The state machine cannot capture the shelf itself: opening one means
    /// asking the environment for the private or regular library asynchronously
    /// and recording the privacy generation at that moment. The shell owns that
    /// sequence, so it supplies it here once, in `onAppear`.
    var onBookshelfRequested: (() -> Void)?

    // MARK: - Notices

    /// Why 小说模式 could not open the page.
    var novelNotice: String?
    /// A one-line result from saving a page: "已保存" or the reason it failed.
    var offlineNotice: String?
    /// Set when an omnibox submission was refused, so the shell can say why
    /// instead of closing the field as if nothing had happened.
    var addressNotice: String?
    /// The input that was refused, kept so the alert can offer to search for it.
    var rejectedInput = ""
    /// A scanned payload that was copied rather than opened.
    var qrCopyNotice: String?

    // MARK: - Tab overview

    /// A print of the real home surface taken before the overview covers it.
    /// The home is native SwiftUI, so it has no web view to photograph; this is
    /// what the home tab's card shows instead of an invented miniature.
    var homePreview: UIImage?
    /// The home tab the print belongs to. A preview taken in 无痕 mode must
    /// never appear on a regular home card after a mode switch.
    var homePreviewTabId: String?

    // MARK: - Find

    var findQuery = ""
    /// The debounce behind the find field. Typing is what runs the search.
    var findDebounceTask: Task<Void, Never>?

    // MARK: - iPad drawer

    /// Whether the iPad layout's sidebar drawer is open.
    var showPadSidebar = false

    // MARK: - Chrome

    /// Whether the command bar has slid out of the way.
    ///
    /// Written through `setChromeHidden` when the user scrolls or drags, which
    /// is also where the scroll tracker learns that the page's layout is about
    /// to move with the bar. A `didSet` here would not do: `@Observable`
    /// rewrites stored properties into computed ones, and an observer on one
    /// is not a place to hang behaviour.
    var chromeHidden = false
    /// How far the user has dragged the bar downward, mid-gesture.
    var chromeDragOffset: CGFloat = 0
    /// How far the user has dragged the bar upward, mid-gesture — the gesture
    /// that returns to the home surface.
    var chromeLiftOffset: CGFloat = 0
    /// Whether that upward drag has passed the distance that opens the home
    /// surface. Drives the hint's filled state and its haptic.
    var chromeHomeArmed = false
    /// Whether the command bar's drag has committed to its vertical axis.
    var chromeDragIsVertical = false
    /// The iPad top bar's vertical drag and the release it is heading for.
    var padChromeDragTranslation: CGFloat = 0
    var padChromeHomeArmed = false
    var padChromeHideArmed = false

    /// Per-frame scroll bookkeeping, kept out of the observation graph.
    ///
    /// `scrollTracker` is a reference box whose *fields* change every scroll
    /// message. Those writes never touch this property, so SwiftUI is not
    /// invalidated per frame; only the `chromeHidden` threshold transition
    /// re-renders. Do not turn this into a value type stored directly.
    var scrollTracker = ShellScrollTracker()

    // MARK: - Keyboard and window geometry

    /// The keyboard's height while visible, from the frame-change notifications.
    var keyboardHeight: CGFloat = 0
    /// The safe-area insets and the height of the safe-area rectangle, measured
    /// once the view is in the hierarchy and again on rotation.
    var safeTop: CGFloat = 0
    var safeBottom: CGFloat = 0
    var safeRectHeight: CGFloat = 0
    var safeRectWidth: CGFloat = 0
    /// Where the shell itself begins in the window. SwiftUI lays the shell
    /// inside the safe area, so this is the status-bar height; a search-page
    /// overlay inherits that origin and must not add the inset again.
    var shellOriginY: CGFloat = 0
    /// The window's height, which is the only height an overlay-origin offset
    /// and a keyboard occlusion can be compared against.
    var windowHeight: CGFloat = 0
    var windowFrameOnScreen: CGRect = .zero

    // MARK: - Edge swipe back

    /// The page's horizontal offset while an edge swipe is tracking, and the
    /// two flags that keep the interactive gesture from overlapping itself.
    var swipeBackTranslation: CGFloat = 0
    var isSwipeBackTracking = false
    var isSwipeBackCompleting = false
    /// Whether the drag has passed the distance that commits the back action.
    var swipeBackArmed = false

    init() {}

    // MARK: - Surface

    /// The reader's session, as a property of the surface.
    ///
    /// Assigning a session opens it; assigning nil closes it and returns the
    /// surface to whatever the active tab shows, which the shell supplies
    /// through `clearNovel`.
    var novelSession: NovelSession? {
        get { surface.novelSession }
        set {
            if let newValue {
                surface = .novel(newValue)
            } else if surface.novelSession != nil {
                surface = .page
            }
        }
    }

    /// Returns the surface to the tab's own state after the reader closes.
    func clearNovel(isHome: Bool, hasFailure: Bool) {
        guard surface.novelSession != nil else { return }
        surface = isHome ? .home : (hasFailure ? .error : .page)
    }

    /// Refreshes the non-novel half of the surface from the active tab.
    ///
    /// A reader is never replaced by a tab change: it covers whatever tab is
    /// active, and closing it is what restores the tab's surface.
    func syncBaseSurface(isHome: Bool, hasFailure: Bool) {
        guard surface.novelSession == nil else { return }
        surface = isHome ? .home : (hasFailure ? .error : .page)
    }

    // MARK: - Overlays

    func present(_ overlay: ShellOverlay) {
        // Build the next set with `filter` and assign once: Set has no
        // closure-taking `removeAll` here, and one assignment also means one
        // change notification.
        var next = Set(overlays.filter { $0.kind != overlay.kind })
        next.insert(overlay)
        overlays = next
    }

    func dismiss(_ overlay: ShellOverlay) { dismiss(kind: overlay.kind) }

    /// Dismisses by identity. Named with a label rather than overloaded on
    /// `ShellOverlay`: both enums have cases called `menu` and `bookshelf`, and
    /// an unlabelled overload would make every one of those calls ambiguous.
    func dismiss(kind: ShellOverlay.Kind) {
        overlays = Set(overlays.filter { $0.kind != kind })
    }

    func isPresented(_ overlay: ShellOverlay) -> Bool { isPresented(kind: overlay.kind) }

    func isPresented(kind: ShellOverlay.Kind) -> Bool {
        overlays.contains { $0.kind == kind }
    }

    /// A sheet binding for an overlay kind.
    ///
    /// Only dismissal travels back through the binding: sheets are opened by
    /// `present`, which is what carries a destination or a shelf context. The
    /// setter still opens the payload-free kinds so the binding is honest if
    /// anything ever flips it.
    func binding(forKind kind: ShellOverlay.Kind) -> Binding<Bool> {
        Binding(
            get: { [weak self] in self?.isPresented(kind: kind) ?? false },
            set: { [weak self] presented in
                guard let self else { return }
                if presented {
                    if let overlay = ShellOverlay(kind: kind) {
                        self.present(overlay)
                    }
                } else {
                    self.dismiss(kind: kind)
                }
            }
        )
    }

    func binding(for overlay: ShellOverlay) -> Binding<Bool> {
        binding(forKind: overlay.kind)
    }

    /// The menu sheet's binding, named for the one call site that needs it.
    var menuBinding: Binding<Bool> { binding(forKind: .menu) }

    /// The settings screen the open sheet was asked to show.
    var settingsDestination: SettingsDestination? {
        for overlay in overlays {
            if case let .settings(destination) = overlay { return destination }
        }
        return nil
    }

    /// The shelf context of the open bookshelf sheet.
    var bookshelfContext: BookshelfContext? {
        for overlay in overlays {
            if case let .bookshelf(context) = overlay { return context }
        }
        return nil
    }

    // MARK: - Menu's deferred presentation

    /// Records a destination for after the menu has finished dismissing.
    func queueMenu(_ presentation: MenuPresentation) {
        pendingMenuPresentation = presentation
    }

    /// Opens the screen a menu tile asked for, now that the menu is gone.
    ///
    /// The shelf is the one destination whose presentation needs more than an
    /// overlay: it must capture the active tab's privacy mode and the current
    /// private generation before the library is fetched. The shell supplies
    /// that sequence through `onBookshelfRequested`.
    func performPendingMenuPresentation() {
        guard let presentation = pendingMenuPresentation else { return }
        pendingMenuPresentation = nil
        switch presentation {
        case .addBookmark: present(.addBookmarkChoice)
        case .share: present(.share)
        case .bookmarks: present(.bookmarks)
        case .history: present(.history)
        case .downloads: present(.downloads)
        case .offlinePages: present(.offlinePages)
        case .settings: present(.settings(nil))
        case .bookshelf: onBookshelfRequested?()
        case .passwords: present(.passwords)
        case .qrScanner: present(.qrScanner)
        }
    }
}
