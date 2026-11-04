//
//  ChromeScrollTests.swift
//  VelaTests
//
//  The collapsing toolbar's state machine. Two failures matter and both are
//  threshold questions: a bar that will not stay hidden (the reversal counted
//  too eagerly) and a bar that flickers while the page jiggles (the page's own
//  movement counted as the user's).
//

import XCTest
@testable import Vela

final class ChromeScrollTests: XCTestCase {
    func testDownwardTravelAccumulatesIntoAHide() {
        let tracker = ShellScrollTracker()
        XCTAssertEqual(tracker.consume(offset: 10, now: 0), .none)
        XCTAssertEqual(tracker.consume(offset: 40, now: 0.016), .none)
        XCTAssertEqual(tracker.consume(offset: 60, now: 0.032), .hide)
    }

    func testAHideResetsTheAccumulation() {
        let tracker = ShellScrollTracker()
        XCTAssertEqual(tracker.consume(offset: 30, now: 0), .none)
        XCTAssertEqual(tracker.consume(offset: 60, now: 0.016), .hide)
        // The hide reset the count; the next small step is not a second hide
        // just because the page is still scrolling.
        XCTAssertEqual(tracker.consume(offset: 70, now: 0.032), .none)
    }

    func testBounceInsideADownwardFlingDoesNotBringTheBarBack() {
        let tracker = ShellScrollTracker()
        _ = tracker.consume(offset: 0, now: 0)
        XCTAssertEqual(tracker.consume(offset: 100, now: 0.1), .hide)
        // A few points of drift back and forth is the page, not the finger.
        XCTAssertEqual(tracker.consume(offset: 96, now: 0.116), .none)
        XCTAssertEqual(tracker.consume(offset: 90, now: 0.132), .none)
        XCTAssertEqual(tracker.consume(offset: 99, now: 0.148), .none)
        XCTAssertEqual(tracker.consume(offset: 92, now: 0.164), .none)
    }

    func testADeliberateUpwardReversalShowsTheBar() {
        let tracker = ShellScrollTracker()
        _ = tracker.consume(offset: 0, now: 0)
        XCTAssertEqual(tracker.consume(offset: 100, now: 0.1), .hide)
        XCTAssertEqual(tracker.consume(offset: 90, now: 0.2), .none)
        XCTAssertEqual(tracker.consume(offset: 80, now: 0.216), .none)
        // The distance is already there on the third sample, but the reversal
        // has to have held for a moment before it counts.
        XCTAssertEqual(tracker.consume(offset: 70, now: 0.25), .show)
    }

    func testASingleFrameShiftIsNotTreatedAsAScroll() {
        let tracker = ShellScrollTracker()
        _ = tracker.consume(offset: 0, now: 0)
        // A page snapping its own scroll position.
        XCTAssertEqual(tracker.consume(offset: 400, now: 0.1), .none)
        XCTAssertEqual(tracker.consume(offset: 100, now: 0.2), .none)
    }

    func testReachingTheTopAlwaysShowsTheBar() {
        let tracker = ShellScrollTracker()
        _ = tracker.consume(offset: 0, now: 0)
        XCTAssertEqual(tracker.consume(offset: 50, now: 0.1), .hide)
        XCTAssertEqual(tracker.consume(offset: 2, now: 0.2), .show)
    }
}
