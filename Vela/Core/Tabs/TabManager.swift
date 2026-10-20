//
//  TabManager.swift
//  Vela
//
//  The open tabs: creation, closing, activation, ordering, pinning, the
//  recently-closed list, and ownership of the live web views.
//
//  Web views are pooled and capped. Holding a live `WKWebView` for every tab is
//  what actually gets an iOS browser jetsammed once a session grows, so the pool
//  keeps a bounded number live and discards the least recently used under
//  pressure — pinned tabs last — while keeping each tab's URL and title so the
//  reload is invisible to the user. A memory warning clears the backgrounded
//  ones outright.
//

import Foundation
import UIKit
import WebKit
import Observation

/// Supplies the `WKWebViewConfiguration` for a tab.
///
/// Kept as a protocol so `TabManager` does not depend on the ad-block engine or
/// the user-script store directly.
@MainActor
public protocol BrowserWebViewConfigurationProviding: AnyObject {
    func makeConfiguration(for tab: BrowserTabState) -> WKWebViewConfiguration
    /// How a tab should identify itself to sites.
    ///
    /// Part of this protocol rather than read off the settings service directly
    /// so `TabManager` keeps owning web views without owning preferences, and so
    /// there is one place that decides what a tab looks like to a site.
    ///
    /// The prefix of the identifier is set on the configuration because WebKit
    /// appends it to its own, and the override is set on the web view; that split
    /// is why this returns a recipe rather than one string.
    func webIdentity(for tab: BrowserTabState) -> BrowserWebIdentity
    /// The factor every page is drawn at, forced by 网页缩放.
    var pageZoomScale: Double { get }
    /// The delegates a tab's web view reports to.
    ///
    /// WebKit holds both weakly, so whatever this returns has to be owned
    /// somewhere else — the app environment owns it.
    var navigationDelegate: WKNavigationDelegate? { get }
    var uiDelegate: WKUIDelegate? { get }
}

@MainActor
@Observable
public final class TabManager {
    /// How many web views the pool holds before the least recently used
    /// background one is discarded.
    ///
    /// The cost of a discard is not just the reload: the tab's back/forward
    /// list lives in its web view, so a discarded tab comes back at the top
    /// of a fresh list with its history gone — which is what "back and
    /// forward sometimes stop working" is made of on sessions that open a
    /// tab per link. iOS will terminate a browser holding far more live web
    /// views than this, and each costs real memory; the number sits high
    /// enough that a normal session across tab-heavy sites keeps its
    /// history, and low enough that a parked session does not accumulate
    /// pages the system will tax.
    public static let maximumLiveWebViews = 8

    /// also caps.
    public static let recentlyClosedLimit = 25

    public private(set) var tabs: [BrowserTabState] = []
    public private(set) var activeTabId: String = ""
    public private(set) var recentlyClosed: [RecentlyClosedTabRecord] = []

    /// Live web views, keyed by tab id. A tab absent from this map is `cold`.
    private var webViews: [String: WKWebView] = [:]
    /// Least-recently-active order, used to pick a victim when the cap is hit.
    private var activationOrder: [String] = []

    private let configurationProvider: BrowserWebViewConfigurationProviding
    private let sessionRepository: TabSessionRepository?

    /// The transition a navigation is recorded under is decided by the
    /// navigation delegate, which is the only place that sees WebKit's
    /// navigation type. Nothing is threaded in here for it: the closure this
    /// used to take was passed by the environment and never read.
    public init(
        configurationProvider: BrowserWebViewConfigurationProviding,
        sessionRepository: TabSessionRepository? = nil
    ) {
        self.configurationProvider = configurationProvider
        self.sessionRepository = sessionRepository
    }

    // MARK: - Queries

    /// The privacy mode a new page opens in when its caller does not name
    /// one — 无痕模式's routing, mirrored here by the shell. Enforcing it at
    /// the two creation entry points is what makes the mode's promise
    /// ("everything new is private") hold at every button, menu tile and
    /// inbound URL at once, instead of wherever a caller remembered it.
    public var newPagePrivacyMode: BrowserSessionPrivacyMode = .regular

    /// Whether closing/backgrounding writes the tab strip to disk. Set by the
    /// environment from 不保留标签页; when false, the last saved session is
    /// cleared and no new one is written.
    public var persistsSession = true

    public var activeTab: BrowserTabState? {
        tabs.first { $0.id == activeTabId }
    }

    public var regularTabs: [BrowserTabState] {
        tabs.filter { $0.privacyMode == .regular }
    }

    public var privateTabs: [BrowserTabState] {
        tabs.filter { $0.privacyMode == .private }
    }

    /// The number of tabs one mode presents — what the overview's mode
    /// segment and the bar's tab button both show.
    ///
    /// Home tabs are the strip's filler, not its content — the overview does
    /// not list one while real tabs exist — so the count is the count of real
    /// tabs, or one when only a home tab remains, which is the one card the
    /// overview does show. There is deliberately no all-modes total: the
    /// regular and private strips are separate surfaces, and a number summing
    /// them matches none of them.
    public func displayedTabCount(privacyMode: BrowserSessionPrivacyMode) -> Int {
        let modeTabs = privacyMode == .private ? privateTabs : regularTabs
        let realTabs = modeTabs.filter { !$0.isHome }
        return realTabs.isEmpty ? (modeTabs.isEmpty ? 0 : 1) : realTabs.count
    }

    public func tab(id: String) -> BrowserTabState? {
        tabs.first { $0.id == id }
    }

    public func webView(for tabId: String) -> WKWebView? {
        webViews[tabId]
    }

    /// The last picture each tab's page showed, for the overview's cards.
    ///
    /// The live pool keeps eight pages; the rest are cold and have no view to
    /// ask for a picture. Without one the overview can only draw the site icon
    /// for those cards, which reads as previews never having been implemented
    /// for every tab past the eighth. A picture is taken when a page finishes
    /// loading — the moment the view is certainly live and laid out — and kept
    /// on disk as well, so a restored session's cold tabs show the page they
    /// were left on.
    private let previews = TabPreviewStore()

    public func preview(for tabId: String) -> UIImage? {
        previews.image(for: tabId)
    }

    /// Keeps a page picture for the overview, downscaled to card size.
    public func storePreview(_ image: UIImage, for tabId: String) {
        previews.store(image, for: tabId)
    }

    /// Takes a picture of a live tab's page and keeps it for the overview.
    ///
    /// Only a web view in a window can be asked: an off-screen view answers
    /// with a blank frame on this WebKit, and a stored blank would be worse
    /// than the icon placeholder it replaced.
    public func capturePreview(for tabId: String) {
        guard let webView = webViews[tabId], webView.window != nil else { return }
        webView.takeSnapshot(with: nil) { [weak self] image, _ in
            guard let image else { return }
            Task { @MainActor in
                self?.previews.store(image, for: tabId)
            }
        }
    }

    public var liveWebViewCount: Int { webViews.count }

    // MARK: - Creation

    /// Creates a tab and makes it active.
    ///
    /// A new tab starts on the home surface (`isHome == true`) rather than
    /// loading a blank document, which is what lets the native new-tab page
    /// render without a web view existing at all.
    ///
    /// The home tab is the strip's filler and there is one per privacy mode: a
    /// "new tab" while one exists means go to it, not stack another. A tab
    /// that is meant to show a page goes through `openTab(url:...)`, which is
    /// the one place that pairs "the tab exists" with "the request is issued"
    /// — the pairing that used to be reconstructed by the view layer and got
    /// it wrong for every tab that was not on screen — and which always
    /// builds a fresh tab, because loading into the filler would turn it into
    /// a page and leave the strip without one.
    @discardableResult
    public func createTab(
        privacyMode: BrowserSessionPrivacyMode? = nil,
        openerTabId: String = "",
        openSource: BrowserTabOpenSource = .user,
        activate: Bool = true
    ) -> BrowserTabState {
        // A caller that names a mode asked for that mode; one that does not
        // gets 无痕模式's routing.
        let resolvedMode = privacyMode ?? newPagePrivacyMode
        if let existing = tabs.first(where: { $0.isHome && $0.privacyMode == resolvedMode }) {
            if activate {
                activateTab(id: existing.id)
            }
            return existing
        }

        let tab = appendHomeTab(
            privacyMode: resolvedMode,
            openerTabId: openerTabId,
            openSource: openSource
        )

        if activate {
            activateTab(id: tab.id)
        }
        persistSession()
        return tab
    }

    /// Appends a fresh home tab, honouring the pinned block's leading edge.
    private func appendHomeTab(
        privacyMode: BrowserSessionPrivacyMode,
        openerTabId: String = "",
        openSource: BrowserTabOpenSource = .user
    ) -> BrowserTabState {
        let tab = BrowserTabState(
            isHome: true,
            runtimeState: .cold,
            privacyMode: privacyMode,
            dataScope: privacyMode == .private ? .sessionEphemeral : .profilePersistent,
            openerTabId: openerTabId,
            openSource: openSource
        )

        // A pinned tab stays at the leading edge; a new tab lands after the
        // pinned block, before the rest.
        if let lastPinnedIndex = tabs.lastIndex(where: { $0.pinned }) {
            tabs.insert(tab, at: lastPinnedIndex + 1)
        } else {
            tabs.append(tab)
        }
        return tab
    }

    /// The mode's single home tab: the one that exists, or a fresh one.
    private func availableHomeTab(privacyMode: BrowserSessionPrivacyMode) -> BrowserTabState {
        if let existing = tabs.first(where: { $0.isHome && $0.privacyMode == privacyMode }) {
            return existing
        }
        return appendHomeTab(privacyMode: privacyMode)
    }

    /// Creates a tab and points it at a URL, in one step.
    ///
    /// The single entry point for "open this in a new tab", from a bookmark, a
    /// history row, a home-screen shortcut, a `target="_blank"` link, an inbound
    /// URL from another app or a reopened record. It exists so no caller has to
    /// remember to follow `createTab` with a load: a tab opened in the background
    /// whose load was left to the view layer was never fetched at all.
    @discardableResult
    public func openTab(
        url: URL,
        privacyMode: BrowserSessionPrivacyMode? = nil,
        openerTabId: String = "",
        openSource: BrowserTabOpenSource = .user,
        activate: Bool = true
    ) -> BrowserTabState {
        // Always a fresh tab, never the reused home one: loading into the
        // filler would turn it into a page and leave the mode without one.
        // The mode resolves the same way createTab's does.
        let tab = appendHomeTab(
            privacyMode: privacyMode ?? newPagePrivacyMode,
            openerTabId: openerTabId,
            openSource: openSource
        )
        load(url: url, in: tab)
        if activate {
            activateTab(id: tab.id)
        }
        return tab
    }

    /// Restores a saved session.
    ///
    /// Private tabs are
    /// restored alongside regular ones; a private session that was open when the
    /// app was killed is reopened, and its data is cleared when the user leaves
    /// private mode rather than at launch.
    ///
    /// Only the records are restored here — no web view is built and no page is
    /// fetched. This runs during app initialisation, before SwiftUI has a
    /// window, and a `WKWebView` created there starts its life without a window
    /// for the whole first layout pass; the shell materialises the active tab
    /// through `activateTab` once it is on screen, which is the path every
    /// other cold tab already takes. Restoring the records is the one part that
    /// has to happen now: the tab strip the user is about to see is built from
    /// them.
    public func restoreSession(_ snapshot: BrowserSessionSnapshot) {
        tabs = snapshot.tabs.map { record in
            let tab = BrowserTabState(
                id: record.id,
                profileId: record.profileId,
                title: record.title,
                url: record.url,
                isHome: record.isHome,
                runtimeState: .cold,
                privacyMode: record.privacyMode,
                dataScope: record.dataScope,
                openerTabId: "",
                openSource: .restore,
                pinned: record.pinned
            )
            tab.apply(record, restoreReason: .sessionRestore)
            return tab
        }

        activeTabId = tabs.contains { $0.id == snapshot.activeTabId }
            ? snapshot.activeTabId
            : (tabs.first?.id ?? "")
    }

    // MARK: - Activation

    /// Makes a tab active and materialises its web view.
    ///
    /// A tab that has a URL but no document — one restored from a saved session,
    /// or whose web view was discarded under memory pressure, or which was opened
    /// in the background before this call — has its page fetched here. That is
    /// what makes activation the point at which a cold tab comes back to life,
    /// and it is why `WebViewHost` no longer starts loads: the fetch belongs to
    /// the tab's lifecycle, not to a view that may never appear.
    ///
    /// The fetch is skipped while a navigation is in flight and while a failure
    /// is on screen — the error surface offers its own retry, and re-fetching
    /// behind it would replace a page the user can read with a spinner.
    public func activateTab(id: String) {
        guard let index = tabs.firstIndex(where: { $0.id == id }) else { return }
        // The page being left is the one the user was looking at, and this is
        // the last moment its view is in a window — the moment its card
        // picture can be taken.
        if activeTabId != id {
            capturePreview(for: activeTabId)
        }
        activeTabId = id
        let tab = tabs[index]
        tab.lastActiveAt = Date()
        // Selecting a private tab is the point at which its data store is
        // created; a private web view is never built for a tab the user has not
        // opened, so the ephemeral store's lifetime tracks real use.
        if !tab.isHome {
            let webView = ensureWebView(for: tab)
            if shouldFetchPage(for: tab, webView: webView) {
                if let url = URL(string: tab.url) {
                    load(url: url, in: tab)
                } else {
                    // A tab claiming to show a page whose URL will not parse has
                    // nothing to fetch. Falling back to the home surface is the
                    // only honest thing left, and it keeps a permanently blank
                    // web view off the screen.
                    tab.isHome = true
                    tab.loadState = .idle
                }
            }
        }
        touchActivationOrder(id)
        enforceLiveWebViewCap()
    }

    /// Whether activating a tab should issue a request for its page.
    ///
    /// `needsPageFetch` answers the half that is a property of the tab: it has a
    /// URL, nothing is in flight, and no failure is waiting to be acknowledged.
    /// The web view answers the other half, which the tab's state cannot — is a
    /// document already on screen?
    ///
    /// That second half is what stops a page that is *displayed* from being
    /// reloaded. A page navigates itself without being asked: Bing fires a
    /// click-tracking beacon as a main-frame navigation, and WebKit can then
    /// abandon it and report it as cancelled — which leaves the tab's state at
    /// `cancelled` while the search results are still displayed and finished.
    /// Without this check, switching away from those results and back reloads
    /// them, and the user loses their place because a hidden beacon was
    /// interrupted.
    private func shouldFetchPage(for tab: BrowserTabState, webView: WKWebView) -> Bool {
        guard tab.needsPageFetch else { return false }
        // `webView.url` cannot answer this: it reports the navigation in flight,
        // so a stopped or cancelled navigation leaves it naming the page that was
        // never shown. `committedUrl` names the document that actually arrived.
        return tab.committedUrl.isEmpty
    }

    /// Moves the active tab by `offset` in the strip.
    public func switchTab(by offset: Int) {
        guard tabs.count > 1, let index = tabs.firstIndex(where: { $0.id == activeTabId }) else { return }
        let next = (index + offset + tabs.count) % tabs.count
        activateTab(id: tabs[next].id)
    }

    /// Drops one entry from the recently-closed list.
    ///
    /// Used by the home surface after a record has been reopened, so the list
    /// does not keep offering a page that is already open again.
    public func removeRecentlyClosedRecord(id: String) {
        recentlyClosed.removeAll { $0.id == id }
        try? sessionRepository?.removeRecentlyClosed(id: id)
    }

    // MARK: - Closing

    /// Closes a tab, recording it in the recently-closed list.
    ///
    /// What the strip is left with follows the home tab's one rule: it is the
    /// filler, present exactly when no real tab is. Closing a tab while real
    /// ones remain lands on a neighbour as before; closing the mode's last
    /// real tab — or the home tab when it is already the only one — leaves
    /// exactly one home tab, activated, which is the surface an emptied strip
    /// shows.
    public func closeTab(id: String) {
        guard let index = tabs.firstIndex(where: { $0.id == id }) else { return }
        let closing = tabs[index]
        let mode = closing.privacyMode

        if !closing.isHome {
            let record = RecentlyClosedTabRecord(
                title: closing.displayTitle,
                url: closing.url,
                privacyMode: closing.privacyMode
            )
            recentlyClosed.insert(record, at: 0)
            if recentlyClosed.count > Self.recentlyClosedLimit {
                recentlyClosed.removeLast(recentlyClosed.count - Self.recentlyClosedLimit)
            }
            try? sessionRepository?.recordClosed(record)
        }

        previews.remove(id)
        destroyWebView(for: id)
        tabs.remove(at: index)

        if tabs.contains(where: { $0.privacyMode == mode && !$0.isHome }) {
            if activeTabId == id {
                // Prefer the tab that was opened by the one being closed, else
                // the neighbour.
                let parentId = closing.openerTabId
                let nextId = tabs.contains(where: { $0.id == parentId })
                    ? parentId
                    : tabs[min(index, tabs.count - 1)].id
                activateTab(id: nextId)
            }
        } else {
            activateTab(id: availableHomeTab(privacyMode: mode).id)
        }
        persistSession()
    }

    /// Closes every tab of one privacy mode.
    ///
    /// The sweep leaves the mode's one home tab standing — created here when
    /// the sweep took everything, because a strip with no tab at all is not a
    /// state this browser shows. `endPrivateSession` is the one caller that
    /// declines the filler: ending private mode means no private tab remains,
    /// not even a pristine one.
    public func closeAllTabs(
        privacyMode: BrowserSessionPrivacyMode,
        fillingWithHomeTab: Bool = true
    ) {
        let doomed = tabs.filter { $0.privacyMode == privacyMode }.map(\.id)
        for id in doomed {
            previews.remove(id)
            destroyWebView(for: id)
        }
        tabs.removeAll { $0.privacyMode == privacyMode }

        if fillingWithHomeTab {
            _ = availableHomeTab(privacyMode: privacyMode)
        }

        if tabs.contains(where: { $0.id == activeTabId }) {
            // The active tab survived the sweep.
        } else if let home = tabs.first(where: { $0.isHome && $0.privacyMode == privacyMode }) {
            activateTab(id: home.id)
        } else if let first = tabs.first {
            activateTab(id: first.id)
        } else {
            activeTabId = ""
        }
        persistSession()
    }

    /// Reopens the most recently closed tab.
    public func reopenLastClosedTab(privacyMode: BrowserSessionPrivacyMode) -> BrowserTabState? {
        // Only the matching privacy mode is eligible; a private tab must not be
        // reopened into a regular session from the regular UI.
        guard let index = recentlyClosed.firstIndex(where: { $0.privacyMode == privacyMode }) else {
            return nil
        }
        let record = recentlyClosed.remove(at: index)
        try? sessionRepository?.removeRecentlyClosed(id: record.id)
        guard let url = URL(string: record.url) else {
            // A recorded URL that no longer parses cannot be fetched; the tab is
            // still worth reopening, on the home surface, rather than silently
            // dropping the user's action.
            return createTab(privacyMode: record.privacyMode, openSource: .restore)
        }
        // Reopening is a request to see the page again, so it is fetched now
        // rather than when its web view happens to be built.
        return openTab(
            url: url,
            privacyMode: record.privacyMode,
            openSource: .restore
        )
    }

    // MARK: - Ordering

    public func move(fromIndex: Int, toIndex: Int) {
        guard tabs.indices.contains(fromIndex), tabs.indices.contains(toIndex) else { return }
        let tab = tabs.remove(at: fromIndex)
        tabs.insert(tab, at: min(toIndex, tabs.count))
        persistSession()
    }

    /// Pins or unpins a tab.
    public func setPinned(_ pinned: Bool, id: String) {
        guard let tab = tab(id: id) else { return }
        tab.pinned = pinned
        // Re-sort: pinned block first, preserving relative order within each
        // block.
        let pinnedTabs = tabs.filter(\.pinned)
        let unpinnedTabs = tabs.filter { !$0.pinned }
        tabs = pinnedTabs + unpinnedTabs
        persistSession()
    }

    // MARK: - Web view ownership

    /// Returns a tab's web view, creating it when the tab is cold.
    @discardableResult
    public func ensureWebView(for tab: BrowserTabState) -> WKWebView {
        if let existing = webViews[tab.id] {
            tab.runtimeState = tab.id == activeTabId ? .active : .background
            return existing
        }

        let configuration = configurationProvider.makeConfiguration(for: tab)
        let webView = WKWebView(frame: .zero, configuration: configuration)

        webView.customUserAgent = configurationProvider.webIdentity(for: tab).customUserAgent
        webView.pageZoom = CGFloat(configurationProvider.pageZoomScale)

        // Without these the web view reports nothing: no `didFinish`, so back
        // and forward never become available; no title, URL or progress; no
        // navigation policy, so an external scheme is never intercepted. The
        // message handlers are registered separately in the configuration, so
        // script traffic worked while all of this silently did not.
        webView.navigationDelegate = configurationProvider.navigationDelegate
        webView.uiDelegate = configurationProvider.uiDelegate

        webView.allowsBackForwardNavigationGestures = true
        webView.allowsLinkPreview = true
        webView.scrollView.contentInsetAdjustmentBehavior = .never

        webViews[tab.id] = webView
        tab.runtimeState = tab.id == activeTabId ? .active : .background
        return webView
    }

    /// Points a tab at a URL and starts the load, creating its web view if it
    /// does not have one.
    ///
    /// The single path for "this tab should now be showing this page". Loading
    /// here rather than in the view layer means the tab is fetched when it is
    /// opened, whether or not it is the one being looked at — a view that never
    /// appears never runs its update, which is how a tab opened in the
    /// background used to be left with no request at all.
    ///
    /// A navigation already in flight is superseded by this one, and the tab's
    /// state says so immediately: `requested` is written before WebKit is handed
    /// the request, so a late callback from the navigation this replaced is
    /// recognisable as stale rather than being mistaken for the new one's.
    @discardableResult
    public func load(url: URL, in tab: BrowserTabState) -> WKWebView {
        tab.isHome = false
        tab.url = url.absoluteString
        tab.pendingUrl = url.absoluteString
        tab.lastFailure = nil
        tab.serverStatus = 0
        tab.loadState = .requested
        tab.isLoading = true
        tab.estimatedProgress = 0
        let webView = ensureWebView(for: tab)
        webView.load(URLRequest(url: url))
        return webView
    }

    /// Reloads a tab's current document.
    ///
    /// Routed through here rather than calling `reload()` on the web view from
    /// the shell so that the state write and the request stay in one place: a
    /// reload is a new navigation, and a tab left showing `finished` while a
    /// fresh request was in flight is exactly the desync the state machine
    /// exists to prevent.
    ///
    /// Only a committed, non-placeholder document can be re-displayed by
    /// WebKit's own `reload()`. Everything else — a web view that was just
    /// rebuilt, a provisional navigation that never committed, the empty
    /// document a failed connection leaves behind — has nothing to re-show,
    /// and handing it to `reload()` is a silent no-op: the button reads as
    /// dead. Those cases issue the request fresh from the tab's URL.
    @discardableResult
    public func reload(tab: BrowserTabState) -> Bool {
        guard !tab.isHome else { return false }
        if let webView = webViews[tab.id],
           let url = webView.url,
           !url.absoluteString.lowercased().hasPrefix("about:") {
            tab.loadState = .requested
            tab.isLoading = true
            tab.lastFailure = nil
            tab.serverStatus = 0
            webView.reload()
            return true
        }
        guard let url = URL(string: tab.url) else { return false }
        load(url: url, in: tab)
        return true
    }

    /// Stops the active load, moving the tab to `cancelled` rather than leaving
    /// it looking like it is still fetching.
    public func stopLoading(tab: BrowserTabState) {
        webViews[tab.id]?.stopLoading()
        if tab.loadState.isInFlight {
            tab.loadState = .cancelled
        }
        tab.isLoading = false
        tab.pendingUrl = ""
    }

    /// Re-applies the forced page zoom to every live web view.
    ///
    /// `pageZoom` belongs to the web view rather than to the document, so a
    /// view that is open keeps the factor across navigations. Setting it here
    /// makes a change visible on the page in front of the user without a
    /// reload, and on backgrounded tabs before they are switched back to.
    public func applyPageZoomToAllWebViews() {
        let scale = CGFloat(configurationProvider.pageZoomScale)
        for tab in tabs {
            guard let webView = webViews[tab.id] else { continue }
            if abs(webView.pageZoom - scale) > 0.001 {
                webView.pageZoom = scale
            }
        }
    }

    /// Re-applies the `User-Agent` to every live web view.
    ///
    /// Called when the appearance of a tab to a site changes — the desktop-site
    /// toggle or the custom identifier — because `customUserAgent` only takes
    /// effect on the next request. Backgrounded tabs are updated too: a tab the
    /// user switches back to must already be presenting the right identity, or
    /// the change looks like it did not apply until a reload.
    public func applyUserAgentToAllWebViews() {
        for tab in tabs {
            guard let webView = webViews[tab.id] else { continue }
            let identity = configurationProvider.webIdentity(for: tab)
            guard webView.customUserAgent != identity.customUserAgent else { continue }
            webView.customUserAgent = identity.customUserAgent
        }
    }

    /// Drops a tab's web view but keeps the tab, its URL and its title.
    ///
    /// The tab becomes `cold`; reactivating it loads the URL again. The scroll
    /// offset is written to the tab first, so the information survives the
    /// discard — nothing reads it back yet, so a reactivated tab currently
    /// returns to the top of the document.
    ///
    /// Returns whether there was a web view to release. The cap needs the
    /// answer: `activationOrder` records tabs in the order they were *activated*,
    /// not the order they were given a web view, so a tab in it can already be
    /// cold — and counting a no-op as one of the victims means the cap stops
    /// after freeing nothing, leaving more web views alive than it allows.
    @discardableResult
    public func discardWebView(
        for tabId: String,
        reason: TabDiscardReason = .memoryPressure
    ) -> Bool {
        guard let webView = webViews[tabId], let tab = tab(id: tabId) else { return false }
        tab.scrollOffsetY = Double(webView.scrollView.contentOffset.y)
        tab.lastDiscardReason = reason
        tab.runtimeState = .cold
        // The back/forward list lives in the web view, so it is discarded with
        // it. Leaving the flags set would leave the toolbar's back and forward
        // buttons enabled on a tab that can no longer do either — a button that
        // looks live and does nothing when pressed.
        tab.canGoBack = false
        tab.canGoForward = false
        tab.isLoading = false
        tab.estimatedProgress = 0
        // The navigation went with the web view. Returning the tab to `idle`
        // rather than leaving the outcome on it is what lets reactivation fetch
        // the URL again — and what stops a failure that happened ten minutes ago
        // from being shown over a page that has not been requested yet.
        tab.loadState = .idle
        tab.lastFailure = nil
        tab.serverStatus = 0
        tab.committedUrl = ""
        tab.pendingUrl = ""
        // Stop loading before release so a transfer in flight cannot deliver a
        // callback to a web view the manager no longer owns.
        webView.stopLoading()
        detachDelegates(from: webView)
        webViews.removeValue(forKey: tabId)
        return true
    }

    private func destroyWebView(for tabId: String) {
        guard let webView = webViews[tabId] else { return }
        webView.stopLoading()
        detachDelegates(from: webView)
        if let tab = tab(id: tabId) {
            tab.canGoBack = false
            tab.canGoForward = false
            tab.isLoading = false
        }
        webViews.removeValue(forKey: tabId)
        activationOrder.removeAll { $0 == tabId }
    }

    /// Severs every link from a web view the manager is letting go.
    ///
    /// Both delegates are held weakly by WebKit, so clearing them is about not
    /// delivering a late callback into the coordinator for a tab that no longer
    /// has a web view. The message handlers are the half that *is* retained: the
    /// content controller owns each `MessageBridge`, and each bridge holds the
    /// coordinator weakly, so the handler objects themselves are released with
    /// the configuration — which is why nothing has to be unregistered here.
    private func detachDelegates(from webView: WKWebView) {
        webView.navigationDelegate = nil
        webView.uiDelegate = nil
    }

    private func touchActivationOrder(_ tabId: String) {
        activationOrder.removeAll { $0 == tabId }
        activationOrder.append(tabId)
    }

    /// Discards the least-recently-used background web views when over the cap.
    ///
    /// The active tab is never a victim, and pinned tabs are spared until
    /// nothing else is left, because a pinned tab is an explicit statement that
    /// the user wants it kept.
    ///
    /// The loop counts only the discards that actually released a web view.
    /// `activationOrder` records tabs in the order they were activated, and a
    /// tab in it can already be cold, so a victim list built from it may contain
    /// entries with nothing to release — and crediting one of those as a freed
    /// web view is what let the pool stay over the cap.
    private func enforceLiveWebViewCap() {
        guard webViews.count > Self.maximumLiveWebViews else { return }

        let candidates = activationOrder.filter { $0 != activeTabId }
        let orderedVictims = candidates.filter { tab(id: $0)?.pinned != true }
            + candidates.filter { tab(id: $0)?.pinned == true }

        var excess = webViews.count - Self.maximumLiveWebViews
        for victim in orderedVictims {
            guard excess > 0 else { return }
            if discardWebView(for: victim) {
                excess -= 1
            }
        }
    }

    /// Called on a memory warning.
    public func handleMemoryPressure() {
        let backgroundTabs = activationOrder.filter { $0 != activeTabId }
        let victims = backgroundTabs.filter { tab(id: $0)?.pinned != true }
        for victim in victims {
            discardWebView(for: victim)
        }
        // WebKit's own caches are the other half of the same response.
        WKWebsiteDataStore.default().removeData(
            ofTypes: [WKWebsiteDataTypeMemoryCache],
            modifiedSince: Date(timeIntervalSince1970: 0)
        ) {}
    }

    // MARK: - Audio state

    public func setAudible(_ audible: Bool, id: String) {
        tab(id: id)?.audible = audible
    }

    public func setMuted(_ muted: Bool, id: String) {
        guard let tab = tab(id: id) else { return }
        tab.muted = muted

        guard let webView = webViews[id] else { return }
        if muted {
            // `WKWebView` has no per-view mute API; the public options are
            // inline playback and the audio session, neither of which is
            // per-tab. Muting is therefore done in the page, which is also what
            // makes it reversible and what keeps a second tab's audio playing.
            webView.evaluateJavaScript(Self.muteAllMediaScript)
        } else {
            webView.evaluateJavaScript(Self.unmuteAllMediaScript)
        }
    }

    /// Silences every media element and keeps new ones silenced.
    private static let muteAllMediaScript = """
    (function () {
      if (window.__velaMediaMuteInstalled) { return; }
      window.__velaMediaMuteInstalled = true;
      var elements = document.querySelectorAll('video, audio');
      for (var i = 0; i < elements.length; i++) { elements[i].muted = true; }
      // A site can attach media after load, so the property is also overridden
      // rather than only applied to what exists now.
      var nativePlay = HTMLMediaElement.prototype.play;
      HTMLMediaElement.prototype.play = function () {
        try { this.muted = true; } catch (_error) {}
        return nativePlay.apply(this, arguments);
      };
    })();
    """

    private static let unmuteAllMediaScript = """
    (function () {
      var elements = document.querySelectorAll('video, audio');
      for (var i = 0; i < elements.length; i++) { elements[i].muted = false; }
    })();
    """

    // MARK: - Persistence

    /// The write is
    /// fire-and-forget: a session save must never block a navigation.
    public func persistSession() {
        guard persistsSession, let sessionRepository else { return }
        let snapshot = BrowserSessionSnapshot(
            tabs: tabs.map(\.record),
            activeTabId: activeTabId,
            tabSequence: tabs.count
        )
        try? sessionRepository.saveSession(snapshot)
    }

    /// Enters 无痕模式's browsing surface: the private home tab, created when
    /// the mode has none. The visible half of turning the mode on.
    public func enterPrivateBrowsing() {
        activateTab(id: availableHomeTab(privacyMode: .private).id)
    }

    /// Leaves 无痕模式 for the regular surface. The mode's exit is a routing
    /// change, not the wipe `endPrivateSession` performs — the private tabs
    /// stay until their own rule ends the session.
    public func exitPrivateBrowsing() {
        activateTab(id: availableHomeTab(privacyMode: .regular).id)
    }

    /// Clears private tabs and their records at the end of a private session.
    public func endPrivateSession() {
        closeAllTabs(privacyMode: .private, fillingWithHomeTab: false)
        recentlyClosed.removeAll { $0.privacyMode == .private }
        try? sessionRepository?.clearRecentlyClosed(privacyMode: .private)
        persistSession()
    }
}

/// How a tab identifies itself to sites.
///
/// Expressed as a recipe rather than a finished string, because the whole prefix
/// of the identifier belongs to WebKit and only its tail belongs to Vela. That
/// split is the point: it is what makes the identifier adapt to a new iOS without
/// a code change, which the previous implementation did not.
public struct BrowserWebIdentity: Equatable, Sendable {
    /// Appended to the identifier WebKit builds for itself.
    ///
    /// WebKit's own template is
    /// `Mozilla/5.0 (<platform>) AppleWebKit/<version> (KHTML, like Gecko) <this>`,
    /// so supplying the tail is enough to present a complete Safari identifier
    /// while the platform token and the WebKit version token come from the
    /// system that is actually running.
    public var applicationNameForUserAgent: String

    /// A complete identifier to present instead of WebKit's, or nil to let
    /// WebKit build the rest.
    ///
    /// Set when the tab has to claim something WebKit will not claim on its own:
    /// a desktop platform, or a string the user typed.
    public var customUserAgent: String?

    public init(applicationNameForUserAgent: String, customUserAgent: String? = nil) {
        self.applicationNameForUserAgent = applicationNameForUserAgent
        self.customUserAgent = customUserAgent
    }
}

/// The User-Agent values presented to pages.
///
/// The identifier presented is Safari's, built from the running system's version
/// numbers, and the previous implementation got this wrong in two separate ways
/// that both produced the same complaint from sites — 「浏览器版本太低」:
///
/// * It hardcoded `Version/17.0`, so on any later iOS every site was told the
///   browser was Safari 17. The engine was current; only the label was stale, and
///   the label is the entire basis of the site's judgement.
/// * It wrote the whole string, including `AppleWebKit/605.1.15`. That token is
///   WebKit's, and writing it down is the same mistake one layer down — it would
///   go stale the day the engine's version token moves.
///
/// So only the tail is written here, and it is handed to WebKit through
/// `applicationNameForUserAgent`, which appends it to the identifier WebKit
/// builds for itself. On iOS 27 the platform token says `CPU iPhone OS 27_…` and
/// the WebKit token is whatever iOS 27 ships, without Vela knowing either.
///
/// Two tokens in the tail are fixed rather than derived, and both are
/// observations of what the system itself sends rather than version guesses:
/// `Mobile/15E148` appears verbatim in the identifier a bare `WKWebView` reports
/// on this platform (measured), and `Safari/604.1` is the token iOS Safari
/// appends. Neither is compared against a version by sites; `Version/` is, and
/// that one is derived.
///
/// A bare `WKWebView` sends neither `Version/` nor `Safari/` — they are tokens
/// Safari adds for itself — and a site that looks for them treats their absence
/// as an embedded browser and tells the user to go and open Safari. That is why
/// the tail cannot simply be omitted.
public enum BrowserUserAgent {
    /// The tail WebKit should append to its own identifier.
    public static var safariTail: String {
        "Version/\(operatingSystemVersion) Mobile/15E148 Safari/604.1"
    }

    /// How a tab should identify itself, given the user's settings — and the
    /// host it is about to open, which one family of sites branches on.
    public static func identity(
        custom: String,
        prefersDesktop: Bool,
        host: String? = nil
    ) -> BrowserWebIdentity {
        let trimmed = custom.trimmingCharacters(in: .whitespacesAndNewlines)
        // Someone who typed a string asked for that exact value. Letting the
        // desktop toggle override it is what made the field look broken.
        if !trimmed.isEmpty {
            return BrowserWebIdentity(applicationNameForUserAgent: safariTail, customUserAgent: trimmed)
        }
        if prefersDesktop {
            return BrowserWebIdentity(
                applicationNameForUserAgent: safariTail,
                customUserAgent: desktopIdentifier
            )
        }
        // YouTube is the one host that gets an answer of its own. The iPad
        // identifier WebKit builds by default hands YouTube its desktop site,
        // and the desktop site is where its bot wall lives: a client with no
        // Google session, arriving from a VPN-shaped IP, is told to sign in
        // 「以确认你不是聊天机器人」 before the first video plays. The mobile
        // site an iPhone identifier receives is the shape that plays without a
        // login. The string is written out whole — WebKit will not rewrite its
        // own platform token, so claiming a phone from an iPad needs the
        // complete value, the way the desktop form does; everything beyond the
        // platform token is still the running system's own.
        if let host, isVideoSiteHost(host) {
            return BrowserWebIdentity(
                applicationNameForUserAgent: safariTail,
                customUserAgent: mobileIdentifier
            )
        }
        // The default: no custom identifier at all, so WebKit appends the tail to
        // its own prefix and the result is what Safari would have sent on this
        // device.
        return BrowserWebIdentity(applicationNameForUserAgent: safariTail)
    }

    /// The video-site hosts that receive the mobile identifier.
    ///
    /// Domain-or-subdomain matching, the same shape the page scripts apply
    /// when they stand down for a site's own player.
    public static func isVideoSiteHost(_ host: String) -> Bool {
        let lowered = host.lowercased()
        let domains = ["youtube.com", "youtube-nocookie.com", "youtubekids.com", "youtu.be"]
        return domains.contains { lowered == $0 || lowered.hasSuffix(".\($0)") }
    }

    /// A complete desktop identifier, for the "请求桌面网站" toggle.
    ///
    /// The whole string is written out here, unlike the mobile case, because a web
    /// view cannot be told to claim a different platform — the platform token is
    /// the one part of the identifier WebKit will not rewrite for us. So this one
    /// does contain written-down tokens: the Mac platform token (which is the lie
    /// the user asked for) and `AppleWebKit/605.1.15`, which is an approximation.
    ///
    /// That approximation is acceptable and the default path does not share it:
    /// sites compare the `Version/` token against a minimum, and that one is
    /// derived from the running system. If WebKit's own version token ever moves,
    /// desktop mode would be presenting the old one while the default path — the
    /// mobile identifier, assembled by WebKit from its own prefix — stays correct
    /// without a change here.
    public static var desktopIdentifier: String {
        desktopForm(of: mobileIdentifier)
    }

    /// The identifier a phone-sized tab presents, reconstructed.
    ///
    /// WebKit assembles the real one from its own prefix plus `safariTail`; this
    /// is that string written out. It is used as the base for the desktop form
    /// above, and the settings screen compares it against the identifier a real
    /// page reports so the two can be seen to agree.
    public static var mobileIdentifier: String {
        "Mozilla/5.0 (iPhone; CPU iPhone OS "
            + "\(operatingSystemVersion.replacingOccurrences(of: ".", with: "_")) like Mac OS X) "
            + "AppleWebKit/605.1.15 (KHTML, like Gecko) \(safariTail)"
    }

    /// `26.1`, as the system reports it.
    static var operatingSystemVersion: String {
        let version = ProcessInfo.processInfo.operatingSystemVersion
        return "\(version.majorVersion).\(version.minorVersion)"
    }

    /// Rewrites a mobile Safari identifier into a desktop one.
    ///
    /// Only the platform token and the `Mobile/` marker change. Rewriting the
    /// version tokens as well is how the identifier goes stale, so they are left
    /// describing the engine that is actually running.
    static func desktopForm(of identifier: String) -> String {
        var text = identifier

        // `(iPhone; CPU iPhone OS 26_1 like Mac OS X)` → a Mac platform token.
        // The group is what a site branches on to choose a layout; everything
        // after it describes WebKit, which is the same either way.
        if let start = text.range(of: "(iPhone;"),
           let end = text.range(of: ") ", range: start.upperBound..<text.endIndex) {
            text.replaceSubrange(start.lowerBound..<end.lowerBound, with: "(Macintosh; Intel Mac OS X 10_15_7")
        }

        // ` Mobile/15E148` is the marker that makes a string read as mobile, and
        // macOS Safari does not send it.
        if let start = text.range(of: " Mobile/"),
           let end = text.range(of: " ", range: start.upperBound..<text.endIndex) {
            text.removeSubrange(start.lowerBound..<end.lowerBound)
        }

        return text
    }
}

/// The last picture each tab's page showed, for the overview's cards.
///
/// Kept in memory for the cards on screen and on disk so a restored session's
/// cold tabs still show the page they were left on — a tab whose web view the
/// live pool has let go has no view to ask. The picture is stored downscaled:
/// a card is a few hundred points wide, and a full-resolution print per tab is
/// tens of megabytes of decoded bitmap for a strip nobody is looking at.
@MainActor
final class TabPreviewStore {
    /// The long edge kept. A card at its widest is a few hundred points; 720
    /// pixels covers it even at 3x with room for the cover-crop.
    private static let maximumEdge: CGFloat = 720
    /// How many pictures the folder keeps across sessions. Closed tabs delete
    /// theirs; this is the bound for tabs that vanished without a close.
    private static let maximumFiles = 80

    private let cache = NSCache<NSString, UIImage>()
    private let directory: URL?

    init() {
        cache.countLimit = 32
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        if let base {
            let folder = base.appendingPathComponent("Vela/TabPreviews", isDirectory: true)
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            directory = folder
        } else {
            directory = nil
        }
        pruneIfNeeded()
    }

    func image(for tabId: String) -> UIImage? {
        if let cached = cache.object(forKey: tabId as NSString) { return cached }
        guard let directory else { return nil }
        let url = directory.appendingPathComponent(Self.fileName(for: tabId))
        guard let image = UIImage(contentsOfFile: url.path) else { return nil }
        cache.setObject(image, forKey: tabId as NSString)
        return image
    }

    func store(_ image: UIImage, for tabId: String) {
        let prepared = Self.downscaled(image)
        cache.setObject(prepared, forKey: tabId as NSString)
        guard let directory,
              let data = prepared.jpegData(compressionQuality: 0.72) else { return }
        let url = directory.appendingPathComponent(Self.fileName(for: tabId))
        Task.detached(priority: .utility) {
            try? data.write(to: url, options: .atomic)
        }
    }

    func remove(_ tabId: String) {
        cache.removeObject(forKey: tabId as NSString)
        guard let directory else { return }
        let url = directory.appendingPathComponent(Self.fileName(for: tabId))
        try? FileManager.default.removeItem(at: url)
    }

    /// Keeps the folder from growing without bound across sessions. The newest
    /// files are the ones a restored session is most likely to name.
    private func pruneIfNeeded() {
        guard let directory,
              let files = try? FileManager.default.contentsOfDirectory(
                  at: directory,
                  includingPropertiesForKeys: [.contentModificationDateKey],
                  options: [.skipsHiddenFiles]
              ),
              files.count > Self.maximumFiles else { return }
        let ordered = files.sorted { left, right in
            let leftDate = (try? left.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate ?? .distantPast
            let rightDate = (try? right.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate ?? .distantPast
            return leftDate > rightDate
        }
        for url in ordered.dropFirst(Self.maximumFiles) {
            try? FileManager.default.removeItem(at: url)
        }
    }

    /// Tab ids are UUID strings; anything else is rewritten so an id can never
    /// escape the folder.
    private static func fileName(for tabId: String) -> String {
        let safe = tabId.map { character -> Character in
            character.isLetter || character.isNumber || character == "-" || character == "_"
                ? character
                : "_"
        }
        return String(safe) + ".jpg"
    }

    private static func downscaled(_ image: UIImage) -> UIImage {
        let longEdge = max(image.size.width, image.size.height)
        guard longEdge > maximumEdge, longEdge > 0 else { return image }
        let scale = maximumEdge / longEdge
        let size = CGSize(width: image.size.width * scale, height: image.size.height * scale)
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        format.opaque = true
        return UIGraphicsImageRenderer(size: size, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: size))
        }
    }
}
