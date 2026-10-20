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

    func testGestureZoomScriptRemovesTheViewportLock() {
        let enabled = WebPageScripts.gestureZoomViewportScript(enabled: true)
        XCTAssertTrue(enabled.contains("user-scalable=yes"))
        XCTAssertTrue(enabled.contains("maximum-scale=3"))
        XCTAssertTrue(enabled.contains("if (true)"))

        let disabled = WebPageScripts.gestureZoomViewportScript(enabled: false)
        XCTAssertTrue(disabled.contains("if (false)"))
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
