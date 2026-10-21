//
//  TabManagerTests.swift
//  VelaTests
//
//  The tab model: creation, closing, ordering, the live-web-view pool and the
//  navigation state that hangs off it.
//
//  The pool tests are the reason this target exists. Discarding a web view is
//  what the memory-pressure path does to a background tab, and the bug that
//  motivated these tests was a discarded tab keeping the back/forward flags of
//  the web view that had just been thrown away — leaving the toolbar offering
//  two buttons that did nothing when pressed. Nothing about that is visible in
//  a type signature, so it is asserted here instead.
//

import XCTest
import WebKit
@testable import Vela

/// A configuration provider that builds a plain `WKWebView`.
///
/// `TabManager` depends on the protocol rather than on the coordinator so it can
/// own web views without owning the ad-block engine, the user-script store or
/// the settings service — which is exactly what makes it testable here.
@MainActor
private final class StubConfigurationProvider: BrowserWebViewConfigurationProviding {
    func makeConfiguration(for tab: BrowserTabState) -> WKWebViewConfiguration {
        WKWebViewConfiguration()
    }

    func webIdentity(for tab: BrowserTabState) -> BrowserWebIdentity {
        BrowserWebIdentity(applicationNameForUserAgent: "VelaTests/1.0")
    }

    var navigationDelegate: WKNavigationDelegate? { nil }
    var uiDelegate: WKUIDelegate? { nil }
}

@MainActor
final class TabManagerTests: XCTestCase {
    private func makeManager() -> TabManager {
        TabManager(configurationProvider: StubConfigurationProvider())
    }

    // MARK: - Creation

    func testFirstTabStartsOnTheHomeSurface() {
        let manager = makeManager()
        let tab = manager.createTab()

        XCTAssertTrue(tab.isHome)
        XCTAssertTrue(tab.url.isEmpty)
        XCTAssertEqual(manager.activeTabId, tab.id)
        XCTAssertEqual(manager.tabs.count, 1)
    }

    func testCreateTabReusesTheSingleHomeTab() {
        let manager = makeManager()
        let first = manager.createTab()
        let second = manager.createTab()

        // The home tab is the strip's filler: one per mode, however many
        // times "new tab" is asked for.
        XCTAssertEqual(manager.tabs.count, 1)
        XCTAssertEqual(second.id, first.id)
    }

    func testOpeningAUrlAlwaysBuildsAFreshTab() {
        let manager = makeManager()
        _ = manager.createTab()
        let page = manager.openTab(url: URL(string: "https://example.com")!)

        // Loading into the filler would turn it into a page and leave the
        // strip without one, so a URL always gets its own tab.
        XCTAssertEqual(manager.tabs.count, 2)
        XCTAssertFalse(page.isHome)
    }

    func testCreateTabInTheBackgroundLeavesTheActiveTabAlone() {
        let manager = makeManager()
        let first = manager.createTab()
        let second = manager.openTab(url: URL(string: "https://example.com")!, activate: false)

        XCTAssertEqual(manager.activeTabId, first.id)
        XCTAssertNotEqual(manager.activeTabId, second.id)
    }

    // MARK: - Loading

    func testLoadPointsTheTabAtTheUrlAndCreatesItsWebView() {
        let manager = makeManager()
        let tab = manager.createTab()
        XCTAssertTrue(tab.isHome)

        let url = URL(string: "https://example.com/page")!
        let webView = manager.load(url: url, in: tab)

        XCTAssertFalse(tab.isHome)
        XCTAssertEqual(tab.url, "https://example.com/page")
        XCTAssertEqual(tab.pendingUrl, "https://example.com/page")
        XCTAssertTrue(manager.webView(for: tab.id) === webView)
    }

    func testLoadInABackgroundTabStillCreatesTheWebView() {
        // The bug this guards: every call site used to pair `createTab(url:)`
        // with `ensureWebView` and leave the fetch to the view layer, so a tab
        // opened in the background was never fetched at all — a view that never
        // appears never runs its update.
        let manager = makeManager()
        let foreground = manager.createTab()
        let background = manager.openTab(url: URL(string: "https://example.com")!, activate: false)

        manager.load(url: URL(string: "https://example.com/article")!, in: background)

        XCTAssertNotNil(manager.webView(for: background.id))
        XCTAssertEqual(manager.activeTabId, foreground.id)
    }

    // MARK: - The live web view pool

    func testDiscardingAWebViewClearsBackAndForward() {
        let manager = makeManager()
        let tab = manager.openTab(url: URL(string: "https://example.com")!)
        _ = manager.ensureWebView(for: tab)
        tab.canGoBack = true
        tab.canGoForward = true
        tab.isLoading = true
        tab.estimatedProgress = 0.5

        manager.discardWebView(for: tab.id)

        // The history lives in the web view, so it went with it. Leaving the
        // flags set is what made the toolbar offer a live-looking button that
        // did nothing.
        XCTAssertFalse(tab.canGoBack)
        XCTAssertFalse(tab.canGoForward)
        XCTAssertFalse(tab.isLoading)
        XCTAssertEqual(tab.estimatedProgress, 0)
        XCTAssertEqual(tab.runtimeState, .cold)
        XCTAssertNil(manager.webView(for: tab.id))
    }

    func testDiscardingRecordsTheReasonAndKeepsTheUrl() {
        let manager = makeManager()
        let tab = manager.openTab(url: URL(string: "https://example.com")!)
        _ = manager.ensureWebView(for: tab)

        manager.discardWebView(for: tab.id, reason: .idleTimeout)

        XCTAssertEqual(tab.lastDiscardReason, .idleTimeout)
        // The URL survives so reactivating the tab reloads it.
        XCTAssertEqual(tab.url, "https://example.com")
    }

    func testLiveWebViewPoolIsCapped() {
        let manager = makeManager()
        var tabs: [BrowserTabState] = []
        for index in 0..<(TabManager.maximumLiveWebViews + 2) {
            tabs.append(manager.openTab(url: URL(string: "https://site\(index).example")!))
        }

        XCTAssertEqual(manager.liveWebViewCount, TabManager.maximumLiveWebViews)
        // The two oldest background tabs are the victims, and the active tab is
        // never one of them.
        XCTAssertNil(manager.webView(for: tabs[0].id))
        XCTAssertNil(manager.webView(for: tabs[1].id))
        XCTAssertNotNil(manager.webView(for: manager.activeTabId))
    }

    func testTheCapStillEnforcesWhenAVictimHasNoWebView() {
        // `activationOrder` follows activation, not web-view creation, so the
        // victim list can contain a tab that has nothing to release. Crediting
        // that as a freed web view is what let the pool sit above the cap
        // indefinitely: the loop spent its one discard on a no-op and stopped.
        let manager = makeManager()
        let home = manager.createTab()
        XCTAssertTrue(home.isHome)
        manager.activateTab(id: home.id)

        for index in 0..<(TabManager.maximumLiveWebViews + 2) {
            manager.openTab(url: URL(string: "https://site\(index).example")!)
        }

        XCTAssertEqual(manager.liveWebViewCount, TabManager.maximumLiveWebViews)
    }

    func testPinnedTabOutlivesAnUnpinnedOneUnderPressure() {
        let manager = makeManager()
        let pinned = manager.openTab(url: URL(string: "https://pinned.example")!, activate: false)
        manager.setPinned(true, id: pinned.id)
        _ = manager.ensureWebView(for: pinned)
        manager.activateTab(id: pinned.id)

        for index in 0..<(TabManager.maximumLiveWebViews + 1) {
            manager.openTab(url: URL(string: "https://filler\(index).example")!)
        }

        XCTAssertNotNil(manager.webView(for: pinned.id))
    }

    // MARK: - Closing

    func testClosingTheLastTabLeavesExactlyOneHomeTab() {
        let manager = makeManager()
        let tab = manager.createTab()
        manager.closeTab(id: tab.id)

        // An emptied strip is not a state the browser shows: exactly one home
        // tab fills it, and that tab is the surface the user lands on.
        XCTAssertEqual(manager.tabs.count, 1)
        XCTAssertTrue(manager.tabs[0].isHome)
        XCTAssertEqual(manager.activeTabId, manager.tabs[0].id)
    }

    func testClosingTheLastRealTabActivatesTheHomeTab() {
        let manager = makeManager()
        let home = manager.createTab()
        let page = manager.openTab(url: URL(string: "https://example.com")!)
        manager.closeTab(id: page.id)

        XCTAssertEqual(manager.tabs.map(\.id), [home.id])
        XCTAssertEqual(manager.activeTabId, home.id)
    }

    func testCloseAllTabsLeavesOneHomeTab() {
        let manager = makeManager()
        _ = manager.createTab()
        _ = manager.openTab(url: URL(string: "https://one.example")!)
        _ = manager.openTab(url: URL(string: "https://two.example")!)

        manager.closeAllTabs(privacyMode: .regular)

        XCTAssertEqual(manager.tabs.count, 1)
        XCTAssertTrue(manager.tabs[0].isHome)
        XCTAssertEqual(manager.activeTabId, manager.tabs[0].id)
    }

    func testClosingATabRecordsItAsRecentlyClosed() {
        let manager = makeManager()
        manager.createTab()
        let page = manager.openTab(url: URL(string: "https://example.com/article")!)
        manager.closeTab(id: page.id)

        XCTAssertEqual(manager.recentlyClosed.count, 1)
        XCTAssertEqual(manager.recentlyClosed[0].url, "https://example.com/article")
    }

    func testClosingAHomeTabIsNotRecorded() {
        let manager = makeManager()
        let page = manager.openTab(url: URL(string: "https://example.com")!)
        let home = manager.createTab()
        manager.closeTab(id: home.id)

        XCTAssertTrue(manager.recentlyClosed.isEmpty)
        XCTAssertNotNil(manager.tab(id: page.id))
    }

    func testReopeningTheLastClosedTabRestoresItsUrl() {
        let manager = makeManager()
        manager.createTab()
        let page = manager.openTab(url: URL(string: "https://example.com/article")!)
        manager.closeTab(id: page.id)

        let reopened = manager.reopenLastClosedTab(privacyMode: .regular)

        XCTAssertEqual(reopened?.url, "https://example.com/article")
        XCTAssertEqual(reopened?.openSource, .restore)
        XCTAssertTrue(manager.recentlyClosed.isEmpty)
        // Reopening is a request to see the page, so its web view exists.
        if let reopened {
            XCTAssertNotNil(manager.webView(for: reopened.id))
        }
    }

    func testReopeningIsScopedToThePrivacyMode() {
        let manager = makeManager()
        let page = manager.openTab(url: URL(string: "https://example.com")!)
        manager.closeTab(id: page.id)

        // A private session must not be able to reopen a regular tab.
        XCTAssertNil(manager.reopenLastClosedTab(privacyMode: .private))
        XCTAssertEqual(manager.recentlyClosed.count, 1)
    }

    func testClosingATabWithAnOpenerReturnsToIt() {
        let manager = makeManager()
        let opener = manager.createTab()
        let child = manager.openTab(
            url: URL(string: "https://example.com")!,
            openerTabId: opener.id
        )
        manager.closeTab(id: child.id)

        XCTAssertEqual(manager.activeTabId, opener.id)
    }

    // MARK: - Ordering

    func testPinningMovesATabToTheLeadingEdge() {
        let manager = makeManager()
        let first = manager.createTab()
        let second = manager.openTab(url: URL(string: "https://one.example")!)
        let third = manager.openTab(url: URL(string: "https://two.example")!)

        manager.setPinned(true, id: third.id)

        XCTAssertEqual(manager.tabs.map(\.id), [third.id, first.id, second.id])

        // Unpinning keeps the tab where it is rather than teleporting it back
        // to where it sat before it was pinned. It was at the front, so it stays
        // at the front — now as the leading unpinned tab.
        manager.setPinned(false, id: third.id)
        XCTAssertEqual(manager.tabs.map(\.id), [third.id, first.id, second.id])
    }

    func testPinnedTabsKeepTheirRelativeOrder() {
        let manager = makeManager()
        let first = manager.createTab()
        let second = manager.openTab(url: URL(string: "https://one.example")!)
        let third = manager.openTab(url: URL(string: "https://two.example")!)

        manager.setPinned(true, id: third.id)
        manager.setPinned(true, id: second.id)

        XCTAssertEqual(manager.tabs.map(\.id), [third.id, second.id, first.id])
    }

    func testSwitchTabWrapsInBothDirections() {
        let manager = makeManager()
        let first = manager.createTab()
        _ = manager.openTab(url: URL(string: "https://one.example")!)
        let last = manager.openTab(url: URL(string: "https://two.example")!)
        XCTAssertEqual(manager.activeTabId, last.id)

        manager.switchTab(by: 1)
        XCTAssertEqual(manager.activeTabId, first.id)

        manager.switchTab(by: -1)
        XCTAssertEqual(manager.activeTabId, last.id)
    }

    func testMoveReordersTheStrip() {
        let manager = makeManager()
        let first = manager.createTab()
        let second = manager.openTab(url: URL(string: "https://one.example")!)
        let third = manager.openTab(url: URL(string: "https://two.example")!)

        manager.move(fromIndex: 0, toIndex: 1)

        XCTAssertEqual(manager.tabs.map(\.id), [second.id, first.id, third.id])
    }

    // MARK: - Privacy

    func testPrivacyModeDecidesTheDataStore() {
        let manager = makeManager()
        let privateTab = manager.createTab(privacyMode: .private)
        let regularTab = manager.createTab(privacyMode: .regular)

        XCTAssertEqual(privateTab.dataScope, .sessionEphemeral)
        XCTAssertEqual(regularTab.dataScope, .profilePersistent)
        XCTAssertEqual(manager.privateTabs.map(\.id), [privateTab.id])
        XCTAssertEqual(manager.regularTabs.count, 1)
    }

    func testEndingAPrivateSessionClosesItsTabsAndItsRecords() {
        let manager = makeManager()
        manager.createTab(privacyMode: .private)
        let regular = manager.createTab(privacyMode: .regular)

        manager.endPrivateSession()

        XCTAssertTrue(manager.privateTabs.isEmpty)
        XCTAssertEqual(manager.tabs.map(\.id), [regular.id])
    }

    // MARK: - Recently closed / pool creation

    func testRestoringRecentlyClosedSortsAndCaps() {
        let manager = makeManager()
        let base = Date()
        let records = (0..<30).map { index in
            RecentlyClosedTabRecord(
                title: "Tab \(index)",
                url: "https://example.com/\(index)",
                closedAt: base.addingTimeInterval(Double(index)),
                privacyMode: .regular
            )
        }
        manager.restoreRecentlyClosed(records)
        XCTAssertEqual(manager.recentlyClosed.count, TabManager.recentlyClosedLimit)
        XCTAssertEqual(manager.recentlyClosed.first?.title, "Tab 29")
        XCTAssertEqual(manager.recentlyClosed.last?.title, "Tab 5")
    }

    func testBackgroundOpenedTabsRespectTheLiveWebViewCap() {
        let manager = makeManager()
        _ = manager.createTab()
        var newest: BrowserTabState?
        for index in 0..<(TabManager.maximumLiveWebViews + 3) {
            newest = manager.openTab(
                url: URL(string: "https://bg\(index).example")!,
                activate: false
            )
        }
        XCTAssertLessThanOrEqual(manager.liveWebViewCount, TabManager.maximumLiveWebViews)
        if let newest {
            XCTAssertNotNil(
                manager.webView(for: newest.id),
                "the tab just opened must not be the view the cap discards"
            )
        }
    }

    // MARK: - Session

    func testSessionRoundTripsTheTabsAndTheActiveOne() {
        let manager = makeManager()
        manager.openTab(url: URL(string: "https://one.example")!)
        let second = manager.openTab(url: URL(string: "https://two.example")!)
        manager.activateTab(id: second.id)

        let snapshot = BrowserSessionSnapshot(
            tabs: manager.tabs.map(\.record),
            activeTabId: manager.activeTabId,
            tabSequence: manager.tabs.count
        )

        let restored = makeManager()
        restored.restoreSession(snapshot)

        XCTAssertEqual(restored.tabs.count, 2)
        XCTAssertEqual(restored.activeTabId, second.id)
        // Restore writes no web views at all — the shell fetches the active
        // tab when it first appears, through the same cold-tab path every
        // other tab takes. Activation is what materialises one.
        XCTAssertNil(restored.webView(for: second.id))
        XCTAssertNil(restored.webView(for: manager.tabs[0].id))
        restored.activateTab(id: second.id)
        XCTAssertNotNil(restored.webView(for: second.id))
        XCTAssertNil(restored.webView(for: manager.tabs[0].id))
    }
}

// MARK: - Tab state

@MainActor
final class BrowserTabStateTests: XCTestCase {
    func testDisplayTitleFallsBackToTheHostThenToTheStartPage() {
        let tab = BrowserTabState(url: "https://www.example.com/a/b", isHome: false)
        XCTAssertEqual(tab.displayTitle, "www.example.com")

        tab.title = "  An article  "
        XCTAssertEqual(tab.displayTitle, "An article")

        let home = BrowserTabState()
        XCTAssertEqual(home.displayTitle, "主页")
    }

    func testDisplayHostDropsTheWwwPrefix() {
        let tab = BrowserTabState(url: "https://www.example.com/a", isHome: false)
        XCTAssertEqual(tab.displayHost, "example.com")
    }

    func testRestoringARecordResetsTheRuntimeState() {
        let tab = BrowserTabState(url: "https://example.com", isHome: false)
        tab.lastFailure = .make(from: NSError(domain: NSURLErrorDomain, code: NSURLErrorTimedOut), url: "https://example.com")
        tab.pendingUrl = "https://pending.example"

        let record = TabRecord(
            id: tab.id,
            profileId: tab.profileId,
            title: "Example",
            url: "https://example.com",
            isHome: false,
            lastActiveAt: Date(),
            pinned: false,
            privacyMode: .regular,
            dataScope: .profilePersistent,
            openSource: .restore,
            lastGoodUrl: "https://example.com",
            lastGoodTitle: "Example",
            scrollOffsetY: 0
        )
        tab.apply(record, restoreReason: .sessionRestore)

        XCTAssertEqual(tab.title, "Example")
        XCTAssertNil(tab.lastFailure)
        XCTAssertEqual(tab.pendingUrl, "")
        XCTAssertEqual(tab.runtimeState, .cold)
        XCTAssertEqual(tab.lastRestoreReason, .sessionRestore)
    }

    func testThePersistedRecordLeavesOutRuntimeState() {
        let tab = BrowserTabState(url: "https://example.com", isHome: false)
        tab.canGoBack = true
        tab.isLoading = true
        tab.estimatedProgress = 0.4

        // The record is `Codable`, and the point of leaving these out is that a
        // restored session cannot come back showing stale chrome.
        let data = try? JSONEncoder().encode(tab.record)
        let json = String(data: data ?? Data(), encoding: .utf8) ?? ""

        XCTAssertFalse(json.contains("canGoBack"))
        XCTAssertFalse(json.contains("estimatedProgress"))
        XCTAssertFalse(json.contains("isLoading"))
    }
}
