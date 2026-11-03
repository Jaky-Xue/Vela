//
//  PageDisplayTests.swift
//  VelaTests
//
//  The page-side background report that keeps the strip under the command bar
//  the page's own colour, and the CSS colour parser the shell reads it with.
//

import XCTest
import UIKit
import SwiftUI
@testable import Vela

final class PageDisplayTests: XCTestCase {
    private func components(
        of color: Color
    ) -> (red: CGFloat, green: CGFloat, blue: CGFloat, alpha: CGFloat)? {
        let resolved = UIColor(color).resolvedColor(with: UITraitCollection(userInterfaceStyle: .light))
        var red: CGFloat = 0
        var green: CGFloat = 0
        var blue: CGFloat = 0
        var alpha: CGFloat = 0
        guard resolved.getRed(&red, green: &green, blue: &blue, alpha: &alpha) else {
            return nil
        }
        return (red, green, blue, alpha)
    }

    func testTheLegacyRGBFormIsRead() {
        guard let color = Color(cssColor: "rgb(255, 255, 255)"),
              let sample = components(of: color) else {
            return XCTFail("a plain RGB colour did not parse")
        }
        XCTAssertEqual(sample.red, 1, accuracy: 0.001)
        XCTAssertEqual(sample.green, 1, accuracy: 0.001)
        XCTAssertEqual(sample.blue, 1, accuracy: 0.001)
        XCTAssertEqual(sample.alpha, 1, accuracy: 0.001)
    }

    func testTheAlphaChannelIsHonoured() {
        guard let color = Color(cssColor: "rgba(0, 0, 0, 0.5)"),
              let sample = components(of: color) else {
            return XCTFail("an RGBA colour did not parse")
        }
        XCTAssertEqual(sample.red, 0, accuracy: 0.001)
        XCTAssertEqual(sample.alpha, 0.5, accuracy: 0.001)
    }

    func testPercentageChannelsAreRead() {
        guard let color = Color(cssColor: "rgb(50%, 50%, 50%)"),
              let sample = components(of: color) else {
            return XCTFail("a percentage colour did not parse")
        }
        XCTAssertEqual(sample.red, 0.5, accuracy: 0.002)
        XCTAssertEqual(sample.green, 0.5, accuracy: 0.002)
        XCTAssertEqual(sample.blue, 0.5, accuracy: 0.002)
    }

    func testSurroundingWhitespaceAndCaseAreTolerated() {
        XCTAssertNotNil(Color(cssColor: "  RGB(12, 34, 56)  "))
    }

    func testAnythingTheBridgeWouldNotSendIsRejected() {
        XCTAssertNil(Color(cssColor: ""))
        XCTAssertNil(Color(cssColor: "#ff0000"))
        XCTAssertNil(Color(cssColor: "not a colour"))
        XCTAssertNil(Color(cssColor: "rgb(12, 34)"))
        XCTAssertNil(Color(cssColor: "rgb(12, 34, 56, 78, 90)"))
    }

    func testTheReporterPostsTheBackgroundToTheMetricsHandler() {
        let script = WebPageScripts.pageBackgroundReporter
        XCTAssertTrue(script.contains("velaPageMetrics"))
        XCTAssertTrue(script.contains("pageBackground"))
        XCTAssertTrue(script.contains("elementFromPoint"))
    }
}
