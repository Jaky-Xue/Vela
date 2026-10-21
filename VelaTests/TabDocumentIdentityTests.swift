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
            committedUrl: "https://example.com/article",
            navigationSerial: 7
        )
        let identity = TabDocumentIdentity(tab: tab)

        XCTAssertTrue(identity.matches(tab))
        XCTAssertFalse(identity.matches(nil))
        XCTAssertFalse(
            identity.matches(
                BrowserTabState(
                    id: "other",
                    committedUrl: "https://example.com/article",
                    navigationSerial: 7
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
