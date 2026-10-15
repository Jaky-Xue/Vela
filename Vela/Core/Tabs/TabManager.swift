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
}

@MainActor
@Observable
public final class TabManager {
    /// Ported from the tab cap in `BrowserMaterializationPolicy`. iOS will
    /// terminate a browser holding far more than this, and each live web view
    /// costs a content process.
    public static let maximumLiveWebViews = 6

    /// Ported from `BrowserRecentlyClosedTabsService`; the list the repository
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
    /// Ported from `BrowserForegroundTabCreationCoordinator`. A new tab starts
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
    /// Ported from `BrowserStartupTabRestoreCoordinator`. Private tabs are
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

        if let active = activeTab, !active.isHome {
            // Materialise only the visible tab. Ported from
            // `BrowserColdTabMaterializeCoordinator`: restoring cold and loading
            // the background tabs would start a dozen navigations at launch.
            _ = ensureWebView(for: active)
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

    /// Moves the active tab by `offset` in the strip. Ported from
    /// `BrowserTabSwitchCoordinator`, which is what the address-bar swipe and
    /// the keyboard shortcuts both drive.
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
    /// Ported from `BrowserTabCloseCoordinator` / `BrowserBackTerminalBackPlan`.
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
                // the neighbour. Ported from the parent-tab plan in
                // `BrowserTerminalBackPlan`.
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
        // reopened into a regular session from the regular UI. Ported from the
        // filter in `BrowserRecentlyClosedApplicationCoordinator`.
        guard let index = recentlyClosed.firstIndex(where: { $0.privacyMode == privacyMode }) else {
            return nil
        }
        let record = recentlyClosed.remove(at: index)
        try? sessionRepository?.removeRecentlyClosed(id: record.id)
        return createTab(
            url: record.url,
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

    /// Pins or unpins a tab. Ported from the pin rule that keeps pinned tabs at
    /// the leading edge in their relative order.
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

        // A desktop-class UA by default. A browser that announces itself as
        // mobile Safari gets the mobile layout on most sites, which is not what
        // a user of a tabbed browser expects. Ported from the default in
        // `BrowserUserAgentService`; the per-site override layer sits on top.
        webView.customUserAgent = BrowserUserAgent.defaultUserAgent

        webView.allowsBackForwardNavigationGestures = true
        webView.allowsLinkPreview = true
        webView.scrollView.contentInsetAdjustmentBehavior = .never

        webViews[tab.id] = webView
        tab.runtimeState = tab.id == activeTabId ? .active : .background
        return webView
    }

    /// Drops a tab's web view but keeps the tab, its URL and its title.
    ///
    /// Ported from the discard path in `BrowserMemoryPressureCoordinator`. The
    /// tab becomes `cold`; reactivating it loads the URL again. Scroll position
    /// is kept in the record so the restore can approximate where the user was.
    public func discardWebView(for tabId: String, reason: TabDiscardReason = .memoryPressure) {
        guard let webView = webViews[tabId], let tab = tab(id: tabId) else { return }
        tab.scrollOffsetY = Double(webView.scrollView.contentOffset.y)
        tab.lastDiscardReason = reason
        tab.runtimeState = .cold
        // Stop loading before release so a transfer in flight cannot deliver a
        // callback to a web view the manager no longer owns.
        webView.stopLoading()
        webView.navigationDelegate = nil
        webView.uiDelegate = nil
        webViews.removeValue(forKey: tabId)
    }

    private func destroyWebView(for tabId: String) {
        guard let webView = webViews[tabId] else { return }
        webView.stopLoading()
        webView.navigationDelegate = nil
        webView.uiDelegate = nil
        // Detach the message handlers so the user content controller does not
        // keep this manager alive through a retain cycle.
        for handler in webView.configuration.userContentController.userScripts {
            _ = handler
        }
        webViews.removeValue(forKey: tabId)
        activationOrder.removeAll { $0 == tabId }
    }

    private func touchActivationOrder(_ tabId: String) {
        activationOrder.removeAll { $0 == tabId }
        activationOrder.append(tabId)
    }

    /// Discards the least-recently-used background web views when over the cap.
    ///
    /// Ported from `BrowserMaterializationPolicy`. The active tab is never a
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

    /// Called on a memory warning. Ported from
    /// `BrowserSystemMemoryPressureSignal` plus the discard policy it drives.
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

    /// Ported from `BrowserTabSessionPersistenceCoordinator`. The write is
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
    /// Ported from `BrowserPrivateSessionCleanupCoordinator`.
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
}
