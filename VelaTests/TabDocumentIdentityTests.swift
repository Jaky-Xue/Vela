//
//  TabDocumentIdentityTests.swift
//  VelaTests
//
//  A delayed reader/ad-block/novel result may only be applied to the exact
//  document it was started for.
//

import XCTest
@testable import Vela

@MainActor
final class TabDocumentIdentityTests: XCTestCase {
    func testIdentityMatchesOnlyTheSameDocument() {
        let tab = BrowserTabState(
            id: "tab",
            navigationSerial: 7,
            committedUrl: "https://example.com/article"
        )
        let identity = TabDocumentIdentity(tab: tab)

        XCTAssertTrue(identity.matches(tab))
        XCTAssertFalse(identity.matches(nil as BrowserTabState?))
        XCTAssertFalse(
            identity.matches(
                BrowserTabState(
                    id: "other",
                    navigationSerial: 7,
                    committedUrl: "https://example.com/article"
                )
            )
        )

        tab.navigationSerial = 8
        XCTAssertFalse(identity.matches(tab), "a newer navigation is a different document")

        tab.navigationSerial = 7
        tab.committedUrl = "https://example.com/other"
        XCTAssertFalse(identity.matches(tab), "a different committed URL is a different document")
    }
}
