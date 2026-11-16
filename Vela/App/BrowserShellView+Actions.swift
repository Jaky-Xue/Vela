import SwiftUI
import UIKit
import WebKit

extension BrowserShellView {
    // MARK: - Actions

    func goBack() {
        guard let tab = activeTab else { return }
        switch navigationActions.backStep(for: tab) {
        case .none, .webView:
            return
        case let .opener(openerId):
            tabManager.activateTab(id: openerId)
        case .returnToPage:
            // Coming back out of the home surface, which is not a page.
            returnToPage(tab)
        case .home:
            goHome(tab)
        }
    }

    /// Opens the start page as its own tab.
    ///
    /// The counterpart to dragging the bar upward and the menu's 主页 tile:
    /// going to the start page is a *destination*, not a mode the current tab
    /// is switched into. Overwriting the tab in place is what it used to do —
    /// the page the user was reading stayed alive underneath but the tab
    /// became a start page, its address bar empty and its identity swapped —
    /// and returning to browsing from there loaded the next page into that
    /// same tab. Now the reading tab keeps its place in the strip, and the
    /// start page opens beside it under the name 主页.
    func openHomeTab() {
        _ = navigationActions.openHomeTab(from: activeTab)
    }

    /// Takes the reader (and its loaders) down before dropping the session.
    /// The runtime cancel is synchronous, so the database can be released even
    /// if SwiftUI has not removed the view yet.
    func closeNovelSession() {
        novelSession?.runtime.cancel()
        novelSession = nil
    }

    /// Returns a tab to the native home surface.
    ///
    /// The page is stopped before it is left: a home surface over a document
    /// still fetching is a document the user has stopped looking at, and its
    /// callbacks would keep arriving into hidden state.
    ///
    /// The tab keeps its URL, its title and its web view. That is what makes the
    /// surface a place the user can come back from — the address bar already
    /// shows nothing while `isHome` is set, so there is no reason to throw the
    /// page away, and throwing it away is what made the old home button a
    /// one-way door.
    func goHome(_ tab: BrowserTabState) {
        tabManager.webView(for: tab.id)?.stopLoading()
        showFindBar = false
        findQuery = ""
        env.webCoordinator.clearFindInPage()
        tabManager.showHome(tab)
        chromeHidden = false
        resetChromeDrag()
        scrollTracker.lastOffset = 0
        scrollTracker.accumulation = 0
        scrollTracker.upwardTravel = 0
        syncAddressText()
    }

    /// Shows the page a tab is already holding, without navigating.
    ///
    /// The counterpart to `goHome`. The URL is taken from the web view when it
    /// has one, because an in-page history change updates the web view before
    /// anything else knows about it, and the tab's copy would otherwise restore
    /// the address of an earlier document.
    func returnToPage(_ tab: BrowserTabState) {
        let current = tabManager.webView(for: tab.id)?.url?.absoluteString
        guard tabManager.showPage(tab, currentURL: current) else { return }
        // The flags were last written when the tab was on this page, but the web
        // view may have been rebuilt since; re-reading them is what keeps the
        // forward button honest the moment the page reappears.
        env.webCoordinator.refreshNavigationAvailability()
        syncAddressText()
    }

    /// Acts on a scanned QR payload. A web address opens in a new tab —
    /// routed through 无痕模式 like every other new page; anything else is
    /// copied, with the payload named in the notice so the copy is
    /// confirmed rather than assumed.
    func handleScannedText(_ raw: String) {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }

        let looksLikeAddress: Bool = {
            if text.contains("://") {
                return URL(string: text)?.host?.isEmpty == false
            }
            // A bare domain: ASCII, dotted, no whitespace, and it parses
            // once the scheme is supplied.
            return !text.contains(" ")
                && text.contains(".")
                && text.allSatisfy(\.isASCII)
                && URL(string: "https://\(text)")?.host?.isEmpty == false
        }()

        showQRScanner = false
        if looksLikeAddress, let url = BrowserUrlResolver.storedUrl(text) {
            tabManager.openTab(url: url, openSource: .user)
        } else {
            UIPasteboard.general.string = text
            qrCopyNotice = text
        }
    }

    /// The live web view of the active tab, when it has one.
    var activeWebView: WKWebView? {
        guard let tab = activeTab else { return nil }
        return tabManager.webView(for: tab.id)
    }

    /// Saves the picked selector for this host and reloads so the cosmetic
    /// style that hides it is attached to a new document.
    func applyElementHide(_ pick: ElementPickResult) {
        env.settings.addManualElementHide(selector: pick.selector, host: pick.host)
        env.overlays.elementPick = nil
        guard let tab = activeTab, !tab.isHome else { return }
        // Hiding one element is a stylesheet update, not a navigation. The old
        // reload discarded the page's scroll position and running state; the
        // rule is already stored, so the same document can apply it now and
        // every later load gets it at document start.
        env.webCoordinator.applyManualElementHides(
            to: tabManager.webView(for: tab.id),
            host: pick.host
        )
    }

    /// Whether the menu's page-bound actions have something to act on.
    var canActOnPage: Bool {
        guard let tab = activeTab, !tab.isHome else { return false }
        return tabManager.webView(for: tab.id) != nil
    }

    /// What the menu panel's header names as its subject.
    var menuPanelTitle: String {
        guard let tab = activeTab, !tab.isHome else { return "菜单" }
        if !tab.title.isEmpty { return tab.title }
        return tab.url.isEmpty ? "菜单" : tab.url
    }

    /// Runs one tile from the menu panel.
    ///
    /// The menu closes first. A destination that is itself a sheet is queued
    /// and presented from the menu sheet's `onDismiss` — the same update cannot
    /// both dismiss one sheet and present another without racing UIKit's
    /// presentation machinery.
    func handleMenuAction(_ action: VelaMenuAction) {
        showMenu = false
        guard let tab = activeTab else {
            switch action {
            case .bookmarks: queueMenuPresentation(.bookmarks)
            case .history: queueMenuPresentation(.history)
            case .downloads: queueMenuPresentation(.downloads)
            case .offlinePages: queueMenuPresentation(.offlinePages)
            case .settings: queueMenuPresentation(.settings)
            case .bookshelf: queueMenuPresentation(.bookshelf)
            case .passwords: queueMenuPresentation(.passwords)
            case .scanQRCode: queueMenuPresentation(.qrScanner)
            case .privateTab:
                // No tab on screen does not make the switch a tab factory:
                // turning 无痕模式 on here materialises the private home it
                // routes to, which is exactly what an empty browser needs.
                Task { await env.requestPrivateBrowsingToggle() }
            case .leavePrivate: break
            default: break
            }
            return
        }

        switch action {
        case .addBookmark:
            queueMenuPresentation(.addBookmark)
        case .share:
            queueMenuPresentation(.share)
        case .findInPage:
            showFindBar = true
        case .saveOfflinePage:
            saveOfflinePage()
        case .offlinePages:
            queueMenuPresentation(.offlinePages)
        case .novel:
            activateNovelMode()
        case .bookshelf:
            queueMenuPresentation(.bookshelf)
        case .passwords:
            queueMenuPresentation(.passwords)
        case .hideElements:
            guard let webView = tabManager.webView(for: tab.id) else { return }
            // The script goes into the current document; no reload, so the
            // page and its scroll position stay put.
            env.webCoordinator.armElementPicker(in: webView)
        case .desktopSite:
            toggleDesktopSite(for: tab)
        case .home:
            openHomeTab()
        case .bookmarks:
            queueMenuPresentation(.bookmarks)
        case .history:
            queueMenuPresentation(.history)
        case .downloads:
            queueMenuPresentation(.downloads)
        case .scanQRCode:
            queueMenuPresentation(.qrScanner)
        case .privateTab:
            // The tile is 无痕模式's switch: on, everything new routes private
            // and the browser lands on the private home; off, routing returns
            // to regular and a private page yields the screen to the regular
            // home. The private tabs themselves stay either way — ending the
            // session is the 离开无痕模式 action, not this one.
            Task { await env.requestPrivateBrowsingToggle() }
        case .leavePrivate:
            let expectedGeneration = env.privateNovelSessionGeneration
            // Close the private reader (and shelf) before the session's data
            // is torn down. The generation guard also stops a late callback
            // from writing after the environment invalidates the session.
            if novelSession?.isPrivateSession == true {
                closeNovelSession()
            }
            if bookshelfIsPrivate {
                shell.dismiss(kind: .bookshelf)
            }
            Task { await env.endPrivateSession(expectedGeneration: expectedGeneration) }
        case .reload:
            reloadActiveTab()
        case .settings:
            queueMenuPresentation(.settings)
        }
    }

    /// Queues a destination behind the menu sheet's dismissal.
    ///
    /// The request is recorded on the state machine and opened by
    /// `ShellState.performPendingMenuPresentation` from the menu sheet's
    /// `onDismiss`. Nothing here may present a sheet: the menu is still on
    /// screen at this point.
    func queueMenuPresentation(_ presentation: MenuPresentation) {
        shell.queueMenu(presentation)
    }

    /// Searches the page as the find field is typed.
    ///
    /// A short pause keeps one document walk off every keystroke; an empty
    /// query clears the highlights instead. `reset` starts a changed query at
    /// its first match rather than carrying the previous query's position.
    func scheduleFind(for query: String) {
        findDebounceTask?.cancel()
        findDebounceTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 180_000_000)
            guard !Task.isCancelled else { return }
            if query.isEmpty {
                env.webCoordinator.clearFindInPage()
            } else {
                env.webCoordinator.findInPage(query, forward: true, reset: true)
            }
        }
    }

    /// Opens a user-defined URL shortcut from the menu panel.
    ///
    /// The shortcut's text is treated the way the omnibox treats a bare host:
    /// a missing scheme becomes https, and anything that is not http(s) is
    /// refused rather than handed to the system.
    func handleMenuShortcut(_ shortcut: MenuShortcut) {
        showMenu = false
        let raw = shortcut.url.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { return }
        let candidate = raw.contains("://") ? raw : "https://" + raw
        guard let url = URL(string: candidate),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              url.host != nil else {
            return
        }
        navigate(to: url, in: submissionTab)
    }

    /// Runs one hardware-keyboard command from the app's menu bar.
    func handleBrowserCommand(_ command: BrowserCommand) {
        switch command {
        case .newTab:
            tabManager.createTab(openSource: .user)
        case .closeTab:
            if let tab = activeTab {
                tabManager.closeTab(id: tab.id)
            }
        case .reopenClosedTab:
            let mode = activeTab?.privacyMode ?? .regular
            _ = tabManager.reopenLastClosedTab(privacyMode: mode)
        case .focusAddressBar:
            closeNovelSession()
            omnibox.beginEditing()
        case .reload:
            reloadActiveTab()
        case .back:
            goBack()
        case .findInPage:
            if canActOnPage { showFindBar = true }
        case .togglePrivate:
            Task { await env.requestPrivateBrowsingToggle() }
        case .nextTab:
            tabManager.switchTab(by: 1)
        case .previousTab:
            tabManager.switchTab(by: -1)
        case .bookmarks:
            showBookmarks = true
        case .history:
            showHistory = true
        case .downloads:
            showDownloads = true
        case .settings:
            openSettings()
        }
    }

    /// Flips the site under the tab between the desktop and the phone page.
    ///
    /// The choice belongs to the site, not to the browser: a site that only
    /// works in one layout should keep its answer on the next visit without
    /// dragging every other site with it. The switch is decided from the
    /// identity in force, so an iPad whose automatic identity is desktop is
    /// told "手机版" on the first tap, and the entry overrides the automatic
    /// rule on later visits.
    func toggleDesktopSite(for tab: BrowserTabState) {
        guard let host = pageHost(for: tab) else { return }
        let isDesktopNow = env.webCoordinator.webIdentity(for: tab).isDesktop
        env.settings.setSiteDisplayMode(isDesktopNow ? .mobile : .desktop, forPageHost: host)
        tabManager.applyUserAgentToAllWebViews()
        _ = tabManager.reload(tab: tab)
    }

    /// Returns the site under the tab to the automatic identity.
    func resetSiteDisplayMode(for tab: BrowserTabState) {
        guard let host = pageHost(for: tab) else { return }
        env.settings.setSiteDisplayMode(nil, forPageHost: host)
        tabManager.applyUserAgentToAllWebViews()
        _ = tabManager.reload(tab: tab)
    }

    /// The host a site preference belongs to: the tab's committed URL, or the
    /// web view's when the tab is between navigations.
    func pageHost(for tab: BrowserTabState) -> String? {
        if let host = URL(string: tab.url)?.host, !host.isEmpty { return host }
        if let host = tabManager.webView(for: tab.id)?.url?.host, !host.isEmpty { return host }
        return nil
    }

    func reloadActiveTab() {
        _ = navigationActions.reload(activeTab)
    }
}
