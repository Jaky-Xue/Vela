//
//  HomeFavoritesTests.swift
//  VelaTests
//
//  The home's favourites shelf is its own store: adding, editing and deleting
//  a tile must not need the bookmark list, and the one-time migration from
//  the retired bookmark-id store must keep the order the home had.
//

import XCTest
import CoreGraphics
@testable import Vela

@MainActor
final class HomeFavoritesTests: XCTestCase {
    private var suiteName = ""
    private var defaults: UserDefaults!

    override func setUp() async throws {
        try await super.setUp()
        suiteName = "HomeFavoritesTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        defaults.removePersistentDomain(forName: suiteName)
    }

    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        try await super.tearDown()
    }

    func testAddingABareHostBecomesAnHTTPSUrl() {
        let service = HomeFavoritesService(defaults: defaults)
        let favorite = service.add(url: "example.com", title: "示例")
        XCTAssertEqual(favorite?.url, "https://example.com")
        XCTAssertEqual(service.favorites.map(\.title), ["示例"])
    }

    func testAddingTheSameUrlTwiceKeepsOneTile() {
        let service = HomeFavoritesService(defaults: defaults)
        let first = service.add(url: "https://example.com", title: "示例")
        let second = service.add(url: "https://example.com/", title: "另一个名字")
        XCTAssertEqual(service.favorites.count, 1)
        XCTAssertEqual(second?.id, first?.id)
        // The existing tile keeps the name it already had: the second add is
        // not consent to rename it.
        XCTAssertEqual(service.favorites.first?.title, "示例")
    }

    func testUpdatingATileDoesNotTouchAnyBookmark() {
        let service = HomeFavoritesService(defaults: defaults)
        let favorite = service.add(url: "https://example.com", title: "旧名字")
        XCTAssertNotNil(favorite)

        let changed = service.update(
            id: favorite!.id,
            title: "新名字",
            url: "https://example.org",
            showsTitle: false
        )
        XCTAssertTrue(changed)
        XCTAssertEqual(service.favorites.first?.title, "新名字")
        XCTAssertEqual(service.favorites.first?.url, "https://example.org")
        XCTAssertEqual(service.favorites.first?.showsTitle, false)
    }

    func testInvalidAddressIsRefused() {
        XCTAssertNil(HomeFavoritesService.normalizedUrl("file:///tmp/page.html"))
        XCTAssertNil(HomeFavoritesService.normalizedUrl("javascript:alert(1)"))
        XCTAssertNil(HomeFavoritesService.normalizedUrl("ftp://example.com"))
        XCTAssertNotNil(HomeFavoritesService.normalizedUrl("example.com"))
    }

    func testTilesSurviveAReload() {
        let service = HomeFavoritesService(defaults: defaults)
        let favorite = service.add(url: "https://example.com", title: "示例", showsTitle: true)
        XCTAssertNotNil(favorite)

        let reloaded = HomeFavoritesService(defaults: defaults)
        XCTAssertEqual(reloaded.favorites.count, 1)
        XCTAssertEqual(reloaded.favorites.first?.id, favorite?.id)
        XCTAssertEqual(reloaded.favorites.first?.showsTitle, true)
    }

    func testRemovingATileLeavesTheRest() {
        let service = HomeFavoritesService(defaults: defaults)
        let first = service.add(url: "https://one.example", title: "一")
        let second = service.add(url: "https://two.example", title: "二")
        service.remove(id: first!.id)
        XCTAssertEqual(service.favorites.map(\.id), [second!.id])
    }

    func testLegacySelectionMigratesOnlyTheChosenIds() {
        defaults.set(true, forKey: "org.vela.browser.home-bookmarks-seeded")
        defaults.set(["b2"], forKey: "org.vela.browser.home-bookmark-ids")

        let bookmarks = [
            BookmarkNode(id: "b1", type: .bookmark, title: "一", url: "https://one.example"),
            BookmarkNode(id: "b2", type: .bookmark, title: "二", url: "https://two.example")
        ]
        let service = HomeFavoritesService(defaults: defaults)
        service.migrateFromLegacyHomeStoreIfNeeded(bookmarks: bookmarks)

        XCTAssertEqual(service.favorites.map(\.title), ["二"])
        XCTAssertEqual(service.favorites.first?.url, "https://two.example")
        XCTAssertNil(defaults.stringArray(forKey: "org.vela.browser.home-bookmark-ids"))
    }

    func testLegacyStoreThatWasNeverSeededMigratesTheWholeList() {
        let bookmarks = [
            BookmarkNode(id: "b1", type: .bookmark, title: "一", url: "https://one.example"),
            BookmarkNode(id: "b2", type: .bookmark, title: "二", url: "https://two.example")
        ]
        let service = HomeFavoritesService(defaults: defaults)
        service.migrateFromLegacyHomeStoreIfNeeded(bookmarks: bookmarks)
        XCTAssertEqual(service.favorites.map(\.title), ["一", "二"])
    }

    func testMigrationRunsOnce() {
        defaults.set(true, forKey: "org.vela.browser.home-bookmarks-seeded")
        defaults.set(["b1"], forKey: "org.vela.browser.home-bookmark-ids")
        let bookmarks = [
            BookmarkNode(id: "b1", type: .bookmark, title: "一", url: "https://one.example")
        ]
        let service = HomeFavoritesService(defaults: defaults)
        service.migrateFromLegacyHomeStoreIfNeeded(bookmarks: bookmarks)
        service.migrateFromLegacyHomeStoreIfNeeded(bookmarks: [])
        XCTAssertEqual(service.favorites.map(\.id).count, 1)
    }
}

/// The home grid's geometry is a value, so the spacing control can be tested
/// without a rendered shelf.
///
/// The previous column count was derived from a minimum cell width that the
/// row then stretched, so the visible gap was mostly leftover cell width and
/// the slider changed it by a fraction of its nominal range.
final class HomeTileGeometryTests: XCTestCase {
    func testASpacingStepTurnsIntoTheSameGapBetweenCells() {
        let width: CGFloat = 358
        let icon: CGFloat = 40
        let tight = HomeTileStyle.columnCount(width: width, iconSize: icon, spacing: 8)
        let loose = HomeTileStyle.columnCount(width: width, iconSize: icon, spacing: 28)

        // Both arrangements lay out the cells plus the requested gaps without
        // overflowing the row.
        let cell = HomeTileStyle.cellWidth(iconSize: icon)
        XCTAssertLessThanOrEqual(CGFloat(tight) * cell + CGFloat(tight - 1) * 8, width)
        XCTAssertLessThanOrEqual(CGFloat(loose) * cell + CGFloat(loose - 1) * 28, width)
        XCTAssertGreaterThanOrEqual(tight, loose)
    }

    func testACellHoldsTheIconAndSomeRoomForItsName() {
        XCTAssertEqual(HomeTileStyle.cellWidth(iconSize: 28), 68)
        XCTAssertEqual(HomeTileStyle.cellWidth(iconSize: 40), 68)
        XCTAssertEqual(HomeTileStyle.cellWidth(iconSize: 64), 80)
    }

    func testANarrowWindowStillGetsAColumn() {
        XCTAssertEqual(HomeTileStyle.columnCount(width: 0, iconSize: 40, spacing: 12), 3)
        XCTAssertEqual(HomeTileStyle.columnCount(width: 120, iconSize: 64, spacing: 28), 1)
    }
}
