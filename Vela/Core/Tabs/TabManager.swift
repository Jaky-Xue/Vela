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
import WebKit
import Observation

/// Supplies the `WKWebViewConfiguration` for a tab.
///
/// Kept as a protocol so `TabManager` does not depend on the ad-block engine or
/// the user-script store directly.
@MainActor
public protocol BrowserWebViewConfigurationProviding: AnyObject {
    func makeConfiguration(for tab: BrowserTabState) -> WKWebViewConfiguration
    /// The `User-Agent` a tab's web view should present.
    ///
    /// Part of this protocol rather than read off the settings service directly
    /// so `TabManager` keeps owning web views without owning preferences, and so
    /// there is one place that decides what a tab looks like to a site.
    func userAgent(for tab: BrowserTabState) -> String
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
    /// IOS will
    /// terminate a browser holding far more than this, and each live web view
    /// costs a content process.
    public static let maximumLiveWebViews = 6

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

    public var activeTab: BrowserTabState? {
        tabs.first { $0.id == activeTabId }
    }

    public var regularTabs: [BrowserTabState] {
        tabs.filter { $0.privacyMode == .regular }
    }

    public var privateTabs: [BrowserTabState] {
        tabs.filter { $0.privacyMode == .private }
    }

    public func tab(id: String) -> BrowserTabState? {
        tabs.first { $0.id == id }
    }

    public func webView(for tabId: String) -> WKWebView? {
        webViews[tabId]
    }

    public var liveWebViewCount: Int { webViews.count }

    // MARK: - Creation

    /// Creates a tab and makes it active.
    ///
    /// A new tab starts on the home surface (`isHome == true`) rather than
    /// loading a blank document, which is what lets the native new-tab page
    /// render without a web view existing at all.
    ///
    /// There is deliberately no `url:` parameter. A tab that is meant to show a
    /// page goes through `openTab(url:...)`, which is the one place that pairs
    /// "the tab exists" with "the request is issued" — the pairing that used to
    /// be reconstructed by the view layer and got it wrong for every tab that
    /// was not on screen.
    @discardableResult
    public func createTab(
        privacyMode: BrowserSessionPrivacyMode = .regular,
        openerTabId: String = "",
        openSource: BrowserTabOpenSource = .user,
        activate: Bool = true
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

        if activate {
            activateTab(id: tab.id)
        }
        persistSession()
        return tab
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
        privacyMode: BrowserSessionPrivacyMode = .regular,
        openerTabId: String = "",
        openSource: BrowserTabOpenSource = .user,
        activate: Bool = true
    ) -> BrowserTabState {
        let tab = createTab(
            privacyMode: privacyMode,
            openerTabId: openerTabId,
            openSource: openSource,
            activate: false
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

        let restoredActive = tabs.contains { $0.id == snapshot.activeTabId }
            ? snapshot.activeTabId
            : (tabs.first?.id ?? "")
        activeTabId = restoredActive

        if let active = activeTab, !active.isHome, let url = URL(string: active.url) {
            // Only the visible tab is fetched. The rest stay cold and load when
            // they are first activated, which is what keeps a restore of twenty
            // tabs from starting twenty page loads at launch.
            load(url: url, in: active)
        }
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
    /// Closing the last tab does not leave an empty strip: a fresh home tab is
    /// created, which is the behaviour `BrowserHomeTerminalBackPlan` describes.
    public func closeTab(id: String) {
        guard let index = tabs.firstIndex(where: { $0.id == id }) else { return }
        let closing = tabs[index]

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

        destroyWebView(for: id)
        tabs.remove(at: index)

        if activeTabId == id {
            if tabs.isEmpty {
                let replacement = BrowserTabState(
                    privacyMode: closing.privacyMode,
                    dataScope: closing.dataScope
                )
                tabs.append(replacement)
                activeTabId = replacement.id
            } else {
                // Prefer the tab that was opened by the one being closed, else
                // the neighbour.
                let parentId = closing.openerTabId
                let nextId = tabs.contains(where: { $0.id == parentId })
                    ? parentId
                    : tabs[min(index, tabs.count - 1)].id
                activateTab(id: nextId)
            }
        }
        persistSession()
    }

    public func closeAllTabs(privacyMode: BrowserSessionPrivacyMode) {
        let doomed = tabs.filter { $0.privacyMode == privacyMode }.map(\.id)
        for id in doomed {
            destroyWebView(for: id)
        }
        tabs.removeAll { $0.privacyMode == privacyMode }
        if tabs.isEmpty {
            let replacement = BrowserTabState(
                privacyMode: privacyMode,
                dataScope: privacyMode == .private ? .sessionEphemeral : .profilePersistent
            )
            tabs.append(replacement)
            activeTabId = replacement.id
        } else if !tabs.contains(where: { $0.id == activeTabId }) {
            activateTab(id: tabs[0].id)
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

        webView.customUserAgent = configurationProvider.userAgent(for: tab)

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
    @discardableResult
    public func reload(tab: BrowserTabState) -> Bool {
        guard !tab.isHome, let webView = webViews[tab.id] else { return false }
        if webView.url == nil, let url = URL(string: tab.url) {
            // Nothing committed to reload — a page that failed, or a web view
            // that was just rebuilt. This is a fresh request, not a re-display.
            load(url: url, in: tab)
            return true
        }
        tab.loadState = .requested
        tab.isLoading = true
        tab.lastFailure = nil
        tab.serverStatus = 0
        webView.reload()
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
            let userAgent = configurationProvider.userAgent(for: tab)
            guard webView.customUserAgent != userAgent else { continue }
            webView.customUserAgent = userAgent
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
        guard let sessionRepository else { return }
        let snapshot = BrowserSessionSnapshot(
            tabs: tabs.map(\.record),
            activeTabId: activeTabId,
            tabSequence: tabs.count
        )
        try? sessionRepository.saveSession(snapshot)
    }

    /// Clears private tabs and their records at the end of a private session.
    ///
    public func endPrivateSession() {
        closeAllTabs(privacyMode: .private)
        recentlyClosed.removeAll { $0.privacyMode == .private }
        try? sessionRepository?.clearRecentlyClosed(privacyMode: .private)
        persistSession()
    }
}

/// The User-Agent values presented to pages.
///
/// The identifier is built from the running system's version numbers, which is
/// the correction that matters: the previous implementation hardcoded
/// `Version/17.0` and `Mobile/15E148`, so on a device running a later iOS every
/// site was told the browser was Safari 17 — years old — and the ones that check
/// answered 「浏览器版本太低」. The engine was current; only the label was stale,
/// and the label is the entire basis of the site's judgement.
///
/// The *shape* of the string is not incidental either. A bare `WKWebView` does
/// not present Safari's identifier: measured in the simulator, it sends
///
///     Mozilla/5.0 (iPhone; CPU iPhone OS 18_7 like Mac OS X) AppleWebKit/605.1.15
///     (KHTML, like Gecko) Mobile/15E148
///
/// — no `Version/`, no `Safari/`, because those two tokens are ones Safari adds
/// for itself. Handing that to a site is how a browser gets told to open the page
/// in Safari instead, so the identifier below adds them, with the same version
/// number the system reports. Everything else is byte-identical to what WebKit
/// would have sent.
///
/// Desktop mode is a deliberate approximation on top of that: the only way to get
/// a desktop layout out of a site that branches on the platform token is to claim
/// a desktop platform, so the platform token and the `Mobile/` marker are the
/// lie the user asked for. The version tokens stay real.
public enum BrowserUserAgent {
    /// The identifier a tab should present.
    public static func resolved(custom: String, prefersDesktop: Bool) -> String {
        let trimmed = custom.trimmingCharacters(in: .whitespacesAndNewlines)
        // Someone who typed a string asked for that exact value. Letting the
        // desktop toggle override it is what made the field look broken.
        if !trimmed.isEmpty { return trimmed }
        return prefersDesktop ? desktopIdentifier : mobileIdentifier
    }

    /// A desktop identifier, for the "请求桌面网站" toggle.
    public static var desktopIdentifier: String {
        desktopForm(of: mobileIdentifier)
    }

    /// The identifier a phone-sized tab presents.
    ///
    /// Built from the running system's version numbers rather than from a fixed
    /// string, so it cannot claim to be older than the device it runs on.
    public static var mobileIdentifier: String {
        let version = ProcessInfo.processInfo.operatingSystemVersion
        let os = "\(version.majorVersion)_\(version.minorVersion)"
        return "Mozilla/5.0 (iPhone; CPU iPhone OS \(os) like Mac OS X) "
            + "AppleWebKit/605.1.15 (KHTML, like Gecko) "
            + "Version/\(version.majorVersion).\(version.minorVersion) Mobile/15E148 Safari/604.1"
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
