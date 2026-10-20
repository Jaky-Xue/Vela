//
//  AppearanceAndZoomTests.swift
//  VelaTests
//
//  The pure parts of the appearance, forced-zoom and automatic identity work.
//

import XCTest
import UIKit
@testable import Vela

final class AppearanceAndZoomTests: XCTestCase {
    func testAppearanceModeMapsToAWindowStyle() {
        XCTAssertEqual(AppearanceMode.system.userInterfaceStyle, .unspecified)
        XCTAssertEqual(AppearanceMode.light.userInterfaceStyle, .light)
        XCTAssertEqual(AppearanceMode.dark.userInterfaceStyle, .dark)
    }

    func testTheAutomaticIdentityPresetIsFirstAndStoresNoString() {
        let first = BrowserUserAgentPreset.all[0]
        XCTAssertEqual(first.id, "auto")
        XCTAssertNil(first.userAgent)
        XCTAssertTrue(first.claimedSummary.contains("当前设备"))
    }

    func testTheIPadIdentifierClaimsATablet() {
        XCTAssertTrue(BrowserUserAgent.padIdentifier.contains("(iPad;"))
        XCTAssertTrue(BrowserUserAgent.padIdentifier.contains("Safari/604.1"))
    }
}
