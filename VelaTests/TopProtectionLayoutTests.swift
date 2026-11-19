//
//  TopProtectionLayoutTests.swift
//  VelaTests
//
//  The arithmetic behind 全局顶部保护 and the command bar's bottom reserve. The
//  host can be laid out edge to edge or inside the safe area depending on how
//  SwiftUI places the representable; the same desired content offset has to
//  produce the right strip and inset in both, without counting the status bar
//  twice. The bottom reserve has the same job in the other direction: the
//  page's own footers must end above the bar, and — where the system can be
//  told about it — the strip must come back to the page when the bar leaves.
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

    // MARK: - The command bar's bottom reserve

    /// The system that can describe its chrome to the layout viewport follows
    /// the bar: while the bar is up the page's fixed footers end above it, and
    /// when it slides away the page takes the strip back — which is what makes
    /// a bottom sheet's last row usable.
    func testTheReserveFollowsTheChromeWhereTheLayoutViewportCan() {
        let shown = WebViewContainerView.bottomLayout(
            safeBottom: 34,
            chromeHeight: 46,
            chromeHidden: false,
            containerBottomFromWindow: 0,
            followsChrome: true
        )
        let hidden = WebViewContainerView.bottomLayout(
            safeBottom: 34,
            chromeHeight: 46,
            chromeHidden: true,
            containerBottomFromWindow: 0,
            followsChrome: true
        )

        XCTAssertEqual(shown, 80, accuracy: 0.001)
        XCTAssertEqual(
            hidden,
            34,
            accuracy: 0.001,
            "the home indicator is still covered; the bar's strip is the page's again"
        )
    }

    /// The legacy scroll inset cannot follow the bar: shrinking it at the end
    /// of a document clamps the scroll position, and the shell reads that
    /// clamp as a gesture. The reserve therefore stays constant.
    func testTheScrollInsetStaysConstantWhileTheBarIsShown() {
        let shown = WebViewContainerView.bottomLayout(
            safeBottom: 34,
            chromeHeight: 46,
            chromeHidden: false,
            containerBottomFromWindow: 0,
            followsChrome: false
        )
        let hidden = WebViewContainerView.bottomLayout(
            safeBottom: 34,
            chromeHeight: 46,
            chromeHidden: true,
            containerBottomFromWindow: 0,
            followsChrome: false
        )

        XCTAssertEqual(shown, 80, accuracy: 0.001)
        XCTAssertEqual(hidden, 80, accuracy: 0.001)
    }

    /// The iPad layout has no bottom bar, and a surface with no bar reserves
    /// nothing — the page owns the whole edge.
    func testASurfaceWithoutABottomBarReservesNothing() {
        let resolved = WebViewContainerView.bottomLayout(
            safeBottom: 34,
            chromeHeight: 0,
            chromeHidden: false,
            containerBottomFromWindow: 0,
            followsChrome: true
        )
        XCTAssertEqual(resolved, 0, accuracy: 0.001)
    }

    /// A host that does not reach the window's bottom already leaves part of
    /// the bar outside itself; that part must not be reserved twice.
    func testAHostAboveTheWindowBottomReservesLess() {
        let resolved = WebViewContainerView.bottomLayout(
            safeBottom: 34,
            chromeHeight: 46,
            chromeHidden: false,
            containerBottomFromWindow: 20,
            followsChrome: true
        )
        XCTAssertEqual(resolved, 60, accuracy: 0.001)
    }
}
