//
//  HangDiagnosticsTests.swift
//  VelaTests
//
//  A main-thread stall is not a navigation event, but it needs the same
//  redacted, in-memory record so it can be read next to the page's navigation.
//

import XCTest
@testable import Vela

@MainActor
final class HangDiagnosticsTests: XCTestCase {
    func testHangIsRecordedAndRedacted() {
        let log = NavigationLog(settings: NavigationDiagnosticsSettings(enabled: true))
        log.recordHang(
            durationMs: 2_400,
            tabId: "tab",
            navigationSerial: 7,
            phase: .finished,
            url: "https://example.com/article?token=secret#part",
            note: "地址栏"
        )

        let entry = log.entries.last
        XCTAssertEqual(entry?.event, .hang)
        XCTAssertEqual(entry?.durationMs, 2_400)
        XCTAssertEqual(entry?.outcome, .failure)
        XCTAssertEqual(entry?.errorDomain, "MainThread")
        XCTAssertTrue(entry?.errorMessage.contains("地址栏") == true)
        XCTAssertEqual(entry?.url, "https://example.com/article?<1 个参数>#<片段>")
        XCTAssertFalse(log.report().contains("secret"))
    }

    func testHangIsNotRecordedWhenDiagnosticsAreOff() {
        let log = NavigationLog(settings: NavigationDiagnosticsSettings(enabled: false))
        log.recordHang(
            durationMs: 2_000,
            tabId: "tab",
            navigationSerial: 1,
            phase: .idle,
            url: "https://example.com"
        )
        XCTAssertTrue(log.entries.isEmpty)
    }
}
