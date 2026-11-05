//
//  PagePopupWindowTests.swift
//  VelaTests
//
//  A page's `window.open` window is drawn at the size the page asked for.
//  Sign-in providers build their form for that size; stretching it across the
//  screen is what turned the form into a card floating in its own empty
//  background.
//

import XCTest
import UIKit
@testable import Vela

final class PagePopupWindowTests: XCTestCase {
    private let screen = CGSize(width: 1032, height: 1376)

    func testTheWindowKeepsTheSizeThePageAskedFor() {
        let size = PagePopupWindowView.windowSize(
            for: CGSize(width: 400, height: 600),
            in: screen
        )
        XCTAssertEqual(size.width, 400)
        XCTAssertEqual(size.height, 600)
    }

    func testAWindowLargerThanTheScreenIsClampedToIt() {
        let size = PagePopupWindowView.windowSize(
            for: CGSize(width: 2000, height: 3000),
            in: screen
        )
        XCTAssertEqual(size.width, 952)
        XCTAssertEqual(size.height, 1236)
    }

    func testAPageThatAskedForNoSizeGetsTheDefaultWindow() {
        let size = PagePopupWindowView.windowSize(for: nil, in: screen)
        XCTAssertEqual(size.width, 460)
        XCTAssertEqual(size.height, 620)
    }

    func testAWindowTooSmallToUseIsRaisedToTheMinimum() {
        let size = PagePopupWindowView.windowSize(
            for: CGSize(width: 80, height: 90),
            in: screen
        )
        XCTAssertEqual(size.width, 280)
        XCTAssertEqual(size.height, 320)
    }
}
