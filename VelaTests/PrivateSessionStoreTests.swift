//
//  PrivateSessionStoreTests.swift
//  VelaTests
//
//  Starting a new private session retires the previous WebKit store. The new
//  session must receive a different store; the old one is cleared separately.
//

import XCTest
@testable import Vela

@MainActor
final class PrivateSessionStoreTests: XCTestCase {
    func testStartingANewPrivateSessionRetiresTheCurrentStore() throws {
        let harness = try BrowserHarness()
        let first = harness.coordinator.privateWebsiteDataStore()
        harness.coordinator.beginNewPrivateSession()
        let second = harness.coordinator.privateWebsiteDataStore()
        XCTAssertFalse(
            first === second,
            "a new private session must not keep using the previous store"
        )
    }
}
