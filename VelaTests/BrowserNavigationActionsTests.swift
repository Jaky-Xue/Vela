//
//  BrowserNavigationActionsTests.swift
//  VelaTests
//
//  The back/reload/home decisions are shared by every entry point; these tests
//  pin the rules the toolbar, menu and hardware keys rely on.
//

import XCTest
@testable import Vela

@MainActor
final class BrowserNavigationActionsTests: XCTestCase {
    private func actions(_ harness: BrowserHarness) -> BrowserNavigationActions {
        BrowserNavigationActions(
            tabManager: harness.tabManager,
            webCoordinator: harness.coordinator
        )
    }

    func testHomeDoesNothingWhenTheActiveTabIsAlreadyHome() throws {
        let harness = try BrowserHarness()
        harness.tabManager.activateTab(id: harness.tabManager.tabs.first!.id)
        XCTAssertNil(actions(harness).openHomeTab(from: harness.tabManager.activeTab))
        XCTAssertEqual(harness.tabManager.tabs.count, 1)
    }

    func testHomeFromAPageCreatesAHomeTab() throws {
        let harness = try BrowserHarness()
        let page = harness.tabManager.openTab(url: URL(string: "https://example.com")!)
        XCTAssertEqual(harness.tabManager.activeTabId, page.id)

        let home = actions(harness).openHomeTab(from: harness.tabManager.activeTab)
        XCTAssertNotNil(home)
        XCTAssertEqual(home?.isHome, true)
        XCTAssertEqual(harness.tabManager.tabs.count, 2)
    }

    func testBackFromTheHomeSurfaceReturnsToThePage() throws {
        let harness = try BrowserHarness()
        let home = harness.tabManager.tabs.first!
        XCTAssertEqual(actions(harness).backStep(for: home), .returnToPage)
    }

    func testBackFallsBackToTheOpeningTab() throws {
        let harness = try BrowserHarness()
        let opener = harness.tabManager.createTab()
        let child = harness.tabManager.openTab(
            url: URL(string: "https://example.com/child")!,
            openerTabId: opener.id
        )
        XCTAssertEqual(actions(harness).backStep(for: child), .opener(opener.id))
    }

    func testReloadWithoutATabIsANoOp() throws {
        let harness = try BrowserHarness()
        XCTAssertFalse(actions(harness).reload(nil))
    }
}
