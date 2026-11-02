//
//  OfflinePageTests.swift
//  VelaTests
//
//  Page identity for the offline shelf.
//

import XCTest
@testable import Vela

final class OfflinePageTests: XCTestCase {
    @MainActor
    func testOfflineUrlNormalizationDropsTheFragment() {
        let normalized = OfflinePageService.normalizedUrlString(
            "HTTPS://Example.COM/Path?q=1#section"
        )
        XCTAssertEqual(normalized, "https://example.com/Path?q=1")
    }

    @MainActor
    func testOfflineUrlNormalizationGivesABareHostAPath() {
        let normalized = OfflinePageService.normalizedUrlString("https://example.com")
        XCTAssertEqual(normalized, "https://example.com/")
    }

    @MainActor
    func testOfflineHashIsStableAndDistinguishesUrls() {
        let first = OfflinePageService.hash("https://example.com/a")
        let second = OfflinePageService.hash("https://example.com/a")
        let other = OfflinePageService.hash("https://example.com/b")
        XCTAssertEqual(first, second)
        XCTAssertNotEqual(first, other)
        XCTAssertEqual(first.count, 64)
    }
}
