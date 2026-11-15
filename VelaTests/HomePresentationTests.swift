import XCTest
@testable import Vela

@MainActor
final class HomePresentationTests: XCTestCase {
    func testHomeReadsLiveClosedTabsAndDropsThemWhenPrivate() throws {
        let harness = try BrowserHarness()
        let favorites = HomeFavoritesService(defaults: UserDefaults(suiteName: UUID().uuidString)!)
        var home = NewTabHomeView(settings: harness.settings, favoritesService: favorites,
                                  tabManager: harness.tabManager, onNavigate: { _ in })
        XCTAssertTrue(home.recentlyClosed.isEmpty)
        let regular = harness.open(URL(string: "https://example.com/regular")!)
        harness.tabManager.closeTab(id: regular.id)
        XCTAssertEqual(home.recentlyClosed.map(\.url), ["https://example.com/regular"])
        let privateTab = harness.tabManager.openTab(url: URL(string: "https://example.com/private")!, privacyMode: .private)
        harness.tabManager.closeTab(id: privateTab.id)
        XCTAssertEqual(home.recentlyClosed.map(\.url), ["https://example.com/regular"])
        home.isPrivate = true
        XCTAssertTrue(home.recentlyClosed.isEmpty)
        home.isPrivate = false
        XCTAssertEqual(home.recentlyClosed.count, 1)
        harness.tabManager.removeRecentlyClosedRecord(id: try XCTUnwrap(home.recentlyClosed.first).id)
        XCTAssertTrue(home.recentlyClosed.isEmpty)
    }
}
