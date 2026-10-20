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

    func testForcedZoomScriptEmbedsTheFactorAndClampsIt() {
        let normal = WebPageScripts.forcedZoomScript(scale: 1.5)
        XCTAssertTrue(normal.contains("zoom: 1.500 !important"))
        XCTAssertTrue(normal.contains("vela-forced-zoom"))

        let clampedHigh = WebPageScripts.forcedZoomScript(scale: 9)
        XCTAssertTrue(clampedHigh.contains("zoom: 2.000 !important"))

        let clampedLow = WebPageScripts.forcedZoomScript(scale: 0.1)
        XCTAssertTrue(clampedLow.contains("zoom: 0.500 !important"))

        // 100% is neutral and must not override a site's own root zoom.
        XCTAssertFalse(WebPageScripts.forcedZoomScript(scale: 1).contains("zoom:"))
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
