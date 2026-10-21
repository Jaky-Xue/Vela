//
//  NovelBrowserRoutingTests.swift
//  VelaTests
//
//  T-11: a private reader's "open in browser" must never fall back to the
//  active regular tab. The routing is pure, so the target decision is tested
//  here; the UI presentation itself has no UI-test target.
//

import XCTest
@testable import Vela

final class NovelBrowserRoutingTests: XCTestCase {
    private let tabs: [(id: String, privacyMode: BrowserSessionPrivacyMode)] = [
        (id: "source", privacyMode: .private),
        (id: "regular", privacyMode: .regular)
    ]

    func testPrivateReaderUsesItsPrivateSourceEvenWithARegularActiveTab() {
        let target = NovelBrowserRouting.target(
            isPrivateSession: true,
            sessionGeneration: 4,
            currentGeneration: 4,
            sourceTabId: "source",
            tabs: tabs,
            activeTabId: "regular"
        )
        XCTAssertEqual(target, .existingTab("source"))
    }

    func testPrivateReaderWithoutAValidPrivateSourceOpensANewPrivateTab() {
        let missingSource = NovelBrowserRouting.target(
            isPrivateSession: true,
            sessionGeneration: 4,
            currentGeneration: 4,
            sourceTabId: "closed",
            tabs: tabs,
            activeTabId: "regular"
        )
        XCTAssertEqual(missingSource, .newPrivateTab)

        // A source id that points at a regular tab is not a valid source for a
        // private session, even though the tab exists.
        let regularSource = NovelBrowserRouting.target(
            isPrivateSession: true,
            sessionGeneration: 4,
            currentGeneration: 4,
            sourceTabId: "regular",
            tabs: tabs,
            activeTabId: "regular"
        )
        XCTAssertEqual(regularSource, .newPrivateTab)
    }

    func testPrivateReaderWithAStaleSessionRefuses() {
        let target = NovelBrowserRouting.target(
            isPrivateSession: true,
            sessionGeneration: 3,
            currentGeneration: 4,
            sourceTabId: "source",
            tabs: tabs,
            activeTabId: "regular"
        )
        XCTAssertEqual(target, .refuse)
    }

    func testRegularReaderKeepsTheActiveTab() {
        let active = NovelBrowserRouting.target(
            isPrivateSession: false,
            sessionGeneration: 0,
            currentGeneration: 4,
            sourceTabId: "",
            tabs: tabs,
            activeTabId: "regular"
        )
        XCTAssertEqual(active, .activeTab("regular"))

        let noActive = NovelBrowserRouting.target(
            isPrivateSession: false,
            sessionGeneration: 0,
            currentGeneration: 4,
            sourceTabId: "",
            tabs: tabs,
            activeTabId: nil
        )
        XCTAssertEqual(noActive, .newRegularTab)
    }
}
