//
//  TopProtectionLayoutTests.swift
//  VelaTests
//
//  The arithmetic behind 全局顶部保护. The host can be laid out edge to edge or
//  inside the safe area depending on how SwiftUI places the representable;
//  the same desired content offset has to produce the right strip and scroll
//  inset in both, without counting the status bar twice.
//

import XCTest
import UIKit
@testable import Vela

final class TopProtectionLayoutTests: XCTestCase {
    func testEdgeToEdgeProtectedReservesTheWholeStatusBar() {
        let layout = WebViewContainerView.topLayout(
            originY: 0,
            safeTop: 59,
            desiredContentTop: 59,
            protectsStatusBar: true
        )
        XCTAssertEqual(layout.reserved, 59, accuracy: 0.001)
        XCTAssertEqual(layout.inset, 0, accuracy: 0.001)
    }

    func testASafeAreaHostDoesNotReserveTheStatusBarTwice() {
        let layout = WebViewContainerView.topLayout(
            originY: 59,
            safeTop: 59,
            desiredContentTop: 59,
            protectsStatusBar: true
        )
        XCTAssertEqual(layout.reserved, 0, accuracy: 0.001)
        XCTAssertEqual(layout.inset, 0, accuracy: 0.001)
    }

    func testUnprotectedEdgeToEdgeScrollsUnderTheClockByInset() {
        let layout = WebViewContainerView.topLayout(
            originY: 0,
            safeTop: 59,
            desiredContentTop: 59,
            protectsStatusBar: false
        )
        XCTAssertEqual(layout.reserved, 0, accuracy: 0.001)
        XCTAssertEqual(layout.inset, 59, accuracy: 0.001)
    }

    func testUnprotectedSafeAreaHostNeedsNoInset() {
        let layout = WebViewContainerView.topLayout(
            originY: 59,
            safeTop: 59,
            desiredContentTop: 59,
            protectsStatusBar: false
        )
        XCTAssertEqual(layout.reserved, 0, accuracy: 0.001)
        XCTAssertEqual(layout.inset, 0, accuracy: 0.001)
    }

    func testIPadTopBarOffsetStaysTheSameInBothArrangements() {
        let edgeToEdge = WebViewContainerView.topLayout(
            originY: 0,
            safeTop: 24,
            desiredContentTop: 24 + 120,
            protectsStatusBar: true
        )
        let safeArea = WebViewContainerView.topLayout(
            originY: 24,
            safeTop: 24,
            desiredContentTop: 24 + 120,
            protectsStatusBar: true
        )

        XCTAssertEqual(edgeToEdge.reserved, 24, accuracy: 0.001)
        XCTAssertEqual(edgeToEdge.inset, 120, accuracy: 0.001)
        XCTAssertEqual(safeArea.reserved, 0, accuracy: 0.001)
        XCTAssertEqual(safeArea.inset, 120, accuracy: 0.001)
    }

    func testAStaleWindowInsetDoesNotDropTheProtectionStrip() {
        // The shell's measurement and the window's are two readings of the
        // same strip. A first pass that sees one of them as zero must still
        // hold the page below the clock rather than treating the zero as an
        // answer.
        let layout = WebViewContainerView.topLayout(
            originY: 0,
            safeTop: 0,
            statusBarStrip: 59,
            desiredContentTop: 59,
            protectsStatusBar: true
        )
        XCTAssertEqual(layout.reserved, 59, accuracy: 0.001)
        XCTAssertEqual(layout.inset, 0, accuracy: 0.001)
    }
}
