import XCTest
import WebKit
@testable import Vela

@MainActor
final class PrivateSessionLifecycleTests: XCTestCase {
    func testRetiredStoreCleanupCannotRetireNewSessionStore() async throws {
        let harness = try BrowserHarness()
        let privateTab = harness.tabManager.createTab(privacyMode: .private)
        _ = harness.tabManager.webView(for: privateTab.id)
        let old = harness.coordinator.privateWebsiteDataStore()
        let next = PrivateSessionLedger.end(expectedGeneration: 1, currentGeneration: 1) {
            harness.tabManager.endPrivateSession()
        }
        XCTAssertEqual(next, 2)
        XCTAssertTrue(harness.tabManager.privateTabs.isEmpty)
        let retired = try XCTUnwrap(harness.coordinator.takePrivateWebsiteDataStoreForCleanup())
        XCTAssertTrue(retired === old)
        let newStore = harness.coordinator.privateWebsiteDataStore()
        XCTAssertFalse(newStore === retired)
        await harness.coordinator.clearPrivateWebsiteData(retired)
        XCTAssertTrue(harness.coordinator.privateWebsiteDataStore() === newStore)
        XCTAssertNil(PrivateSessionLedger.end(expectedGeneration: 1, currentGeneration: 2) {
            XCTFail("old request must not close new session")
        })
    }
}
