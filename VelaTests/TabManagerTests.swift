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
    private(set) var recordedVisits: [URL] = []

    func makeConfiguration(for tab: BrowserTabState) -> WKWebViewConfiguration {
        WKWebViewConfiguration()
    }

    func recordVisit(
        url: URL,
        title: String,
        boundary: BrowserDataBoundary,
        transition: HistoryTransition
    ) {
        recordedVisits.append(url)
    }

    func userAgent(for tab: BrowserTabState) -> String { "VelaTests/1.0" }

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

    func testCreateTabWithAUrlDoesNotMarkItAsHome() {
        let manager = makeManager()
        let tab = manager.createTab(url: "https://example.com")

        XCTAssertFalse(tab.isHome)
        XCTAssertEqual(tab.url, "https://example.com")
    }

    func testCreateTabInTheBackgroundLeavesTheActiveTabAlone() {
        let manager = makeManager()
        let first = manager.createTab()
        let second = manager.createTab(url: "https://example.com", activate: false)

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
        let background = manager.createTab(url: "https://example.com", activate: false)

        manager.load(url: URL(string: "https://example.com/article")!, in: background)

        XCTAssertNotNil(manager.webView(for: background.id))
        XCTAssertEqual(manager.activeTabId, foreground.id)
    }

    // MARK: - The live web view pool

    func testDiscardingAWebViewClearsBackAndForward() {
        let manager = makeManager()
        let tab = manager.createTab(url: "https://example.com")
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
        let tab = manager.createTab(url: "https://example.com")
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
            tabs.append(manager.createTab(url: "https://site\(index).example"))
        }

        XCTAssertEqual(manager.liveWebViewCount, TabManager.maximumLiveWebViews)
        // The two oldest background tabs are the victims, and the active tab is
        // never one of them.
        XCTAssertNil(manager.webView(for: tabs[0].id))
        XCTAssertNil(manager.webView(for: tabs[1].id))
        XCTAssertNotNil(manager.webView(for: manager.activeTabId))
    }

    func testPinnedTabOutlivesAnUnpinnedOneUnderPressure() {
        let manager = makeManager()
        let pinned = manager.createTab(url: "https://pinned.example", activate: false)
        manager.setPinned(true, id: pinned.id)
        _ = manager.ensureWebView(for: pinned)
        manager.activateTab(id: pinned.id)

        for index in 0..<(TabManager.maximumLiveWebViews + 1) {
            manager.createTab(url: "https://filler\(index).example")
        }

        XCTAssertNotNil(manager.webView(for: pinned.id))
    }

    // MARK: - Closing

    func testClosingTheOnlyTabLeavesAFreshHomeTab() {
        let manager = makeManager()
        let tab = manager.createTab()
        manager.closeTab(id: tab.id)

        XCTAssertEqual(manager.tabs.count, 1)
        XCTAssertTrue(manager.tabs[0].isHome)
        XCTAssertNotEqual(manager.tabs[0].id, tab.id)
    }

    func testClosingATabRecordsItAsRecentlyClosed() {
        let manager = makeManager()
        manager.createTab()
        let page = manager.createTab(url: "https://example.com/article")
        manager.closeTab(id: page.id)

        XCTAssertEqual(manager.recentlyClosed.count, 1)
        XCTAssertEqual(manager.recentlyClosed[0].url, "https://example.com/article")
    }

    func testClosingAHomeTabIsNotRecorded() {
        let manager = makeManager()
        let page = manager.createTab(url: "https://example.com")
        let home = manager.createTab()
        manager.closeTab(id: home.id)

        XCTAssertTrue(manager.recentlyClosed.isEmpty)
        XCTAssertNotNil(manager.tab(id: page.id))
    }

    func testReopeningTheLastClosedTabRestoresItsUrl() {
        let manager = makeManager()
        manager.createTab()
        let page = manager.createTab(url: "https://example.com/article")
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
        let page = manager.createTab(url: "https://example.com")
        manager.closeTab(id: page.id)

        // A private session must not be able to reopen a regular tab.
        XCTAssertNil(manager.reopenLastClosedTab(privacyMode: .private))
        XCTAssertEqual(manager.recentlyClosed.count, 1)
    }

    func testClosingATabWithAnOpenerReturnsToIt() {
        let manager = makeManager()
        let opener = manager.createTab()
        let child = manager.createTab(
            url: "https://example.com",
            openerTabId: opener.id
        )
        manager.closeTab(id: child.id)

        XCTAssertEqual(manager.activeTabId, opener.id)
    }

    // MARK: - Ordering

    func testPinningMovesATabToTheLeadingEdge() {
        let manager = makeManager()
        let first = manager.createTab()
        let second = manager.createTab()
        let third = manager.createTab()

        manager.setPinned(true, id: third.id)

        XCTAssertEqual(manager.tabs.map(\.id), [third.id, first.id, second.id])

        manager.setPinned(false, id: third.id)
        XCTAssertEqual(manager.tabs.map(\.id), [first.id, second.id, third.id])
    }

    func testSwitchTabWrapsInBothDirections() {
        let manager = makeManager()
        let first = manager.createTab()
        manager.createTab()
        let last = manager.createTab()
        XCTAssertEqual(manager.activeTabId, last.id)

        manager.switchTab(by: 1)
        XCTAssertEqual(manager.activeTabId, first.id)

        manager.switchTab(by: -1)
        XCTAssertEqual(manager.activeTabId, last.id)
    }

    func testMoveReordersTheStrip() {
        let manager = makeManager()
        let first = manager.createTab()
        let second = manager.createTab()
        let third = manager.createTab()

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

    // MARK: - Session

    func testSessionRoundTripsTheTabsAndTheActiveOne() {
        let manager = makeManager()
        manager.createTab(url: "https://one.example")
        let second = manager.createTab(url: "https://two.example")
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
        // Only the visible tab is fetched; the rest wait until they are opened.
        XCTAssertNotNil(restored.webView(for: second.id))
        XCTAssertNil(restored.webView(for: manager.tabs[0].id))
    }
}

// MARK: - Tab state

@MainActor
final class BrowserTabStateTests: XCTestCase {
    func testDisplayTitleFallsBackToTheHostThenToNewTab() {
        let tab = BrowserTabState(url: "https://www.example.com/a/b", isHome: false)
        XCTAssertEqual(tab.displayTitle, "www.example.com")

        tab.title = "  An article  "
        XCTAssertEqual(tab.displayTitle, "An article")

        let home = BrowserTabState()
        XCTAssertEqual(home.displayTitle, "新标签页")
    }

    func testDisplayHostDropsTheWwwPrefix() {
        let tab = BrowserTabState(url: "https://www.example.com/a", isHome: false)
        XCTAssertEqual(tab.displayHost, "example.com")
    }

    func testRestoringARecordResetsTheRuntimeState() {
        let tab = BrowserTabState(url: "https://example.com", isHome: false)
        tab.lastError = "boom"
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
        XCTAssertEqual(tab.lastError, "")
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
