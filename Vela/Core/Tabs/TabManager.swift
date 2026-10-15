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
    func recordVisit(url: URL, title: String, boundary: BrowserDataBoundary, transition: HistoryTransition)
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
    private let historyTransitionProvider: (BrowserTabState) -> HistoryTransition

    public init(
        configurationProvider: BrowserWebViewConfigurationProviding,
        sessionRepository: TabSessionRepository? = nil,
        historyTransitionProvider: @escaping (BrowserTabState) -> HistoryTransition = { _ in .link }
    ) {
        self.configurationProvider = configurationProvider
        self.sessionRepository = sessionRepository
        self.historyTransitionProvider = historyTransitionProvider
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
    /// A new tab starts
    /// on the home surface (`isHome == true`) rather than loading a blank
    /// document, which is what lets the native new-tab page render without a web
    /// view existing at all.
    @discardableResult
    public func createTab(
        url: String = "",
        privacyMode: BrowserSessionPrivacyMode = .regular,
        openerTabId: String = "",
        openSource: BrowserTabOpenSource = .user,
        activate: Bool = true
    ) -> BrowserTabState {
        let tab = BrowserTabState(
            url: url,
            isHome: url.isEmpty,
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
    public func activateTab(id: String) {
        guard let index = tabs.firstIndex(where: { $0.id == id }) else { return }
        activeTabId = id
        let tab = tabs[index]
        tab.lastActiveAt = Date()
        // Selecting a private tab is the point at which its data store is
        // created; a private web view is never built for a tab the user has not
        // opened, so the ephemeral store's lifetime tracks real use.
        if !tab.isHome {
            _ = ensureWebView(for: tab)
        }
        touchActivationOrder(id)
        enforceLiveWebViewCap()
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
        let tab = createTab(
            url: record.url,
            privacyMode: record.privacyMode,
            openSource: .restore
        )
        // Reopening is a request to see the page again, so it is fetched now
        // rather than when its web view happens to be built.
        if let url = URL(string: record.url) {
            load(url: url, in: tab)
        }
        return tab
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
    /// The single path for "this tab should now be showing this page". Every
    /// call site that used to pair `createTab(url:)` with `ensureWebView` was
    /// relying on `WebViewHost` to notice that the tab had a URL and no page and
    /// start the load itself — which worked for a tab that was on screen and
    /// silently did nothing for one opened in the background, because a view
    /// that never appears never runs its update. Loading here means the tab is
    /// fetched when it is opened, whether or not it is the one being looked at.
    @discardableResult
    public func load(url: URL, in tab: BrowserTabState) -> WKWebView {
        tab.isHome = false
        tab.url = url.absoluteString
        tab.pendingUrl = url.absoluteString
        let webView = ensureWebView(for: tab)
        webView.load(URLRequest(url: url))
        return webView
    }

    /// Re-applies the `User-Agent` to every live web view.    ///
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
    /// The
    /// tab becomes `cold`; reactivating it loads the URL again. Scroll position
    /// is kept in the record so the restore can approximate where the user was.
    public func discardWebView(for tabId: String, reason: TabDiscardReason = .memoryPressure) {
        guard let webView = webViews[tabId], let tab = tab(id: tabId) else { return }
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
        // Stop loading before release so a transfer in flight cannot deliver a
        // callback to a web view the manager no longer owns.
        webView.stopLoading()
        detachDelegates(from: webView)
        webViews.removeValue(forKey: tabId)
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
    /// The active tab is never a
    /// victim, and pinned tabs are spared until nothing else is left, because a
    /// pinned tab is an explicit statement that the user wants it kept.
    private func enforceLiveWebViewCap() {
        guard webViews.count > Self.maximumLiveWebViews else { return }

        let candidates = activationOrder.filter { $0 != activeTabId }
        let orderedVictims = candidates.filter { tab(id: $0)?.pinned != true }
            + candidates.filter { tab(id: $0)?.pinned == true }

        var excess = webViews.count - Self.maximumLiveWebViews
        for victim in orderedVictims where excess > 0 {
            discardWebView(for: victim)
            excess -= 1
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
/// iOS reports a fixed `Safari/605.1.15` token, so the desktop string below is
/// what actually negotiates a desktop layout. The mobile string is used when the
/// user asks a specific site for the mobile version.
public enum BrowserUserAgent {
    /// The desktop string. It claims a Mac because that is what gets a desktop
    /// layout out of the sites that branch on the identifier.
    public static var defaultUserAgent: String {
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 "
            + "(KHTML, like Gecko) Version/17.0 Safari/605.1.15"
    }

    public static var mobileUserAgent: String {
        let systemVersion = ProcessInfo.processInfo.operatingSystemVersion
        let version = "\(systemVersion.majorVersion)_\(systemVersion.minorVersion)"
        return "Mozilla/5.0 (iPhone; CPU iPhone OS \(version) like Mac OS X) "
            + "AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1"
    }

    /// The identifier a tab presents, given the user's settings.
    ///
    /// A custom string wins outright. Someone who typed one asked for that exact
    /// value, and letting the desktop toggle override it would make the field
    /// look broken — which is what it was before this was wired up.
    public static func resolve(custom: String, prefersDesktop: Bool) -> String {
        let trimmed = custom.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { return trimmed }
        return prefersDesktop ? defaultUserAgent : mobileUserAgent
    }
}
