//
//  BrowserShellView+State.swift
//  Vela
//
//  The shell's view onto `ShellState`.
//
//  The window state itself lives in `ShellState`; these
//  accessors are the names the shell's other extensions already speak. They
//  carry no storage of their own — every read and write lands in the one
//  observable object — so a presentation can be opened from a menu action, a
//  keyboard command and a sheet binding without three owners disagreeing.
//
//  Presentation flags are kept as Bool accessors here because the shell asks
//  "is this on screen?" from a dozen places (`edgeSwipeBackEnabled`, the find
//  bar's lift, the overview's animation value). The sheets themselves bind
//  through `shell.binding(forKind:)`, which is the API new code should use.
//

import SwiftUI
import UIKit

extension BrowserShellView {
    // MARK: - Overlay presence

    var showSiteCapabilities: Bool {
        get { shell.isPresented(.siteCapabilities) }
        nonmutating set { newValue ? shell.present(.siteCapabilities) : shell.dismiss(.siteCapabilities) }
    }

    var showTabsOverview: Bool {
        get { shell.isPresented(.tabsOverview) }
        nonmutating set { newValue ? shell.present(.tabsOverview) : shell.dismiss(.tabsOverview) }
    }

    var showQRScanner: Bool {
        get { shell.isPresented(.qrScanner) }
        nonmutating set { newValue ? shell.present(.qrScanner) : shell.dismiss(.qrScanner) }
    }

    var showBookmarks: Bool {
        get { shell.isPresented(.bookmarks) }
        nonmutating set { newValue ? shell.present(.bookmarks) : shell.dismiss(.bookmarks) }
    }

    var showHistory: Bool {
        get { shell.isPresented(.history) }
        nonmutating set { newValue ? shell.present(.history) : shell.dismiss(.history) }
    }

    var showDownloads: Bool {
        get { shell.isPresented(.downloads) }
        nonmutating set { newValue ? shell.present(.downloads) : shell.dismiss(.downloads) }
    }

    var showPasswords: Bool {
        get { shell.isPresented(.passwords) }
        nonmutating set { newValue ? shell.present(.passwords) : shell.dismiss(.passwords) }
    }

    var showMenu: Bool {
        get { shell.isPresented(.menu) }
        nonmutating set { newValue ? shell.present(.menu) : shell.dismiss(.menu) }
    }

    var showAddBookmarkChoice: Bool {
        get { shell.isPresented(.addBookmarkChoice) }
        nonmutating set { newValue ? shell.present(.addBookmarkChoice) : shell.dismiss(.addBookmarkChoice) }
    }

    var showShareSheet: Bool {
        get { shell.isPresented(.share) }
        nonmutating set { newValue ? shell.present(.share) : shell.dismiss(.share) }
    }

    var showFindBar: Bool {
        get { shell.isPresented(.findBar) }
        nonmutating set { newValue ? shell.present(.findBar) : shell.dismiss(.findBar) }
    }

    var showOfflinePages: Bool {
        get { shell.isPresented(.offlinePages) }
        nonmutating set { newValue ? shell.present(.offlinePages) : shell.dismiss(.offlinePages) }
    }

    /// The settings screen the open sheet shows. Presented through
    /// `openSettings`, never assigned.
    var settingsDestination: SettingsDestination? { shell.settingsDestination }

    // MARK: - Bookshelf context

    /// Whether the open shelf belongs to a private session. The generation
    /// beside it is what closes a shelf left behind by an older one.
    var bookshelfIsPrivate: Bool { shell.bookshelfContext?.isPrivate ?? false }
    var bookshelfGeneration: Int { shell.bookshelfContext?.generation ?? 0 }

    // MARK: - iPad drawer

    var showPadSidebar: Bool {
        get { shell.showPadSidebar }
        nonmutating set { shell.showPadSidebar = newValue }
    }

    // MARK: - Notices and ephemeral readouts

    var qrCopyNotice: String? {
        get { shell.qrCopyNotice }
        nonmutating set { shell.qrCopyNotice = newValue }
    }

    var offlineNotice: String? {
        get { shell.offlineNotice }
        nonmutating set { shell.offlineNotice = newValue }
    }

    var findQuery: String {
        get { shell.findQuery }
        nonmutating set { shell.findQuery = newValue }
    }

    var findDebounceTask: Task<Void, Never>? {
        get { shell.findDebounceTask }
        nonmutating set { shell.findDebounceTask = newValue }
    }

    var novelNotice: String? {
        get { shell.novelNotice }
        nonmutating set { shell.novelNotice = newValue }
    }

    var addressNotice: String? {
        get { shell.addressNotice }
        nonmutating set { shell.addressNotice = newValue }
    }

    var rejectedInput: String {
        get { shell.rejectedInput }
        nonmutating set { shell.rejectedInput = newValue }
    }

    var homePreview: UIImage? {
        get { shell.homePreview }
        nonmutating set { shell.homePreview = newValue }
    }

    var homePreviewTabId: String? {
        get { shell.homePreviewTabId }
        nonmutating set { shell.homePreviewTabId = newValue }
    }

    // MARK: - Chrome

    var chromeHidden: Bool {
        get { shell.chromeHidden }
        nonmutating set { shell.chromeHidden = newValue }
    }

    var chromeDragOffset: CGFloat {
        get { shell.chromeDragOffset }
        nonmutating set { shell.chromeDragOffset = newValue }
    }

    var chromeLiftOffset: CGFloat {
        get { shell.chromeLiftOffset }
        nonmutating set { shell.chromeLiftOffset = newValue }
    }

    var chromeHomeArmed: Bool {
        get { shell.chromeHomeArmed }
        nonmutating set { shell.chromeHomeArmed = newValue }
    }

    var chromeDragIsVertical: Bool {
        get { shell.chromeDragIsVertical }
        nonmutating set { shell.chromeDragIsVertical = newValue }
    }

    var padChromeDragTranslation: CGFloat {
        get { shell.padChromeDragTranslation }
        nonmutating set { shell.padChromeDragTranslation = newValue }
    }

    var padChromeHomeArmed: Bool {
        get { shell.padChromeHomeArmed }
        nonmutating set { shell.padChromeHomeArmed = newValue }
    }

    var padChromeHideArmed: Bool {
        get { shell.padChromeHideArmed }
        nonmutating set { shell.padChromeHideArmed = newValue }
    }

    var scrollTracker: ShellScrollTracker {
        get { shell.scrollTracker }
        nonmutating set { shell.scrollTracker = newValue }
    }

    // MARK: - Keyboard and window geometry

    var keyboardHeight: CGFloat {
        get { shell.keyboardHeight }
        nonmutating set { shell.keyboardHeight = newValue }
    }

    var safeTop: CGFloat {
        get { shell.safeTop }
        nonmutating set { shell.safeTop = newValue }
    }

    var safeBottom: CGFloat {
        get { shell.safeBottom }
        nonmutating set { shell.safeBottom = newValue }
    }

    var safeRectHeight: CGFloat {
        get { shell.safeRectHeight }
        nonmutating set { shell.safeRectHeight = newValue }
    }

    var safeRectWidth: CGFloat {
        get { shell.safeRectWidth }
        nonmutating set { shell.safeRectWidth = newValue }
    }

    var shellOriginY: CGFloat {
        get { shell.shellOriginY }
        nonmutating set { shell.shellOriginY = newValue }
    }

    var windowHeight: CGFloat {
        get { shell.windowHeight }
        nonmutating set { shell.windowHeight = newValue }
    }

    // MARK: - Edge swipe back

    var swipeBackTranslation: CGFloat {
        get { shell.swipeBackTranslation }
        nonmutating set { shell.swipeBackTranslation = newValue }
    }

    var isSwipeBackTracking: Bool {
        get { shell.isSwipeBackTracking }
        nonmutating set { shell.isSwipeBackTracking = newValue }
    }

    var isSwipeBackCompleting: Bool {
        get { shell.isSwipeBackCompleting }
        nonmutating set { shell.isSwipeBackCompleting = newValue }
    }

    var swipeBackArmed: Bool {
        get { shell.swipeBackArmed }
        nonmutating set { shell.swipeBackArmed = newValue }
    }

    // MARK: - Surface

    /// The novel reader's layer, when one is open.
    ///
    /// Reading and writing this is reading and writing `shell.surface`: the
    /// reader is a surface, not a boolean beside one. Closing it returns the
    /// shell to whatever the active tab shows.
    var novelSession: NovelSession? {
        get { shell.surface.novelSession }
        nonmutating set {
            if let newValue {
                shell.surface = .novel(newValue)
            } else {
                shell.clearNovel(
                    isHome: activeTab?.isHome ?? true,
                    hasFailure: activeFailure
                )
            }
        }
    }

    /// Whether the active tab has a failure worth showing as the error surface.
    var activeFailure: Bool {
        guard let tab = activeTab else { return false }
        return tab.lastFailure != nil && tab.loadState.isFailure
    }

    /// The tab-derived half of the surface, ignoring any reader.
    var baseSurface: BrowserSurface {
        guard let tab = activeTab else { return .home }
        if tab.isHome { return .home }
        return activeFailure ? .error : .page
    }

    /// What the shell is actually showing, including the reader.
    ///
    /// This is the value the surface transition animates on. It is derived
    /// rather than stored so a tab whose state changed a frame before the
    /// observer ran can never leave the wrong surface on screen.
    var displayedSurface: BrowserSurface {
        if let session = shell.surface.novelSession { return .novel(session) }
        return baseSurface
    }

    /// Re-reads the tab's surface into the state machine.
    ///
    /// Called from the tab observers; the view itself renders `baseSurface`,
    /// so a missed call degrades to a stale animation value, never a stale
    /// screen.
    func syncSurface() {
        shell.syncBaseSurface(isHome: activeTab?.isHome ?? true, hasFailure: activeFailure)
    }
}
