//
//  ShellStateTests.swift
//  VelaTests
//
//  The shell's presentation model: overlays answer by identity, the menu's
//  destination is deferred until the menu is gone, and the main surface never
//  lets a tab change replace an open reader.
//

import XCTest
@testable import Vela

@MainActor
final class ShellStateTests: XCTestCase {
    func testPresentReplacesAnOverlayOfTheSameKind() {
        let shell = ShellState()
        shell.present(.settings(.appearance))
        XCTAssertTrue(shell.isPresented(kind: .settings))
        XCTAssertEqual(shell.settingsDestination, .appearance)

        // Opening the root again must not stack a second settings sheet, and
        // the payload follows the newest presentation.
        shell.present(.settings(nil))
        XCTAssertNil(shell.settingsDestination)
        XCTAssertEqual(shell.overlays.count, 1)
    }

    func testBindingDismissesOnlyItsOwnOverlay() {
        let shell = ShellState()
        shell.present(.bookmarks)
        shell.present(.history)

        shell.binding(forKind: .bookmarks).wrappedValue = false

        XCTAssertFalse(shell.isPresented(kind: .bookmarks))
        XCTAssertTrue(shell.isPresented(kind: .history))
    }

    func testMenuDismissalPresentsTheQueuedDestination() {
        let shell = ShellState()
        shell.present(.menu)
        shell.queueMenu(.bookmarks)

        // While the menu is still up, its destination is only a request: the
        // second sheet must not be presented in the same update.
        XCTAssertFalse(shell.isPresented(kind: .bookmarks))
        XCTAssertEqual(shell.pendingMenuPresentation, .bookmarks)

        shell.dismiss(.menu)
        shell.performPendingMenuPresentation()

        XCTAssertTrue(shell.isPresented(kind: .bookmarks))
        XCTAssertNil(shell.pendingMenuPresentation)
    }

    func testBookshelfGoesThroughTheShellsContextCapture() {
        let shell = ShellState()
        var opens = 0
        shell.onBookshelfRequested = { opens += 1 }

        shell.present(.menu)
        shell.queueMenu(.bookshelf)
        shell.dismiss(.menu)
        shell.performPendingMenuPresentation()

        // The shelf needs a library and a privacy generation, so the state
        // machine hands the request back to the shell rather than inventing
        // a context.
        XCTAssertEqual(opens, 1)
        XCTAssertFalse(shell.isPresented(kind: .bookshelf))
    }

    func testSurfaceFollowsTheTabBaseState() {
        let shell = ShellState()
        shell.syncBaseSurface(isHome: false, hasFailure: false)
        XCTAssertEqual(shell.surface, .page)
        shell.syncBaseSurface(isHome: true, hasFailure: false)
        XCTAssertEqual(shell.surface, .home)
        shell.syncBaseSurface(isHome: false, hasFailure: true)
        XCTAssertEqual(shell.surface, .error)
        shell.syncBaseSurface(isHome: false, hasFailure: false)
        XCTAssertEqual(shell.surface, .page)
    }

    func testClearingWithoutAReaderLeavesTheSurfaceAlone() {
        // A reader cannot be built here without a shelf, but the clearing rule
        // is the same surface transition the shell uses.
        let shell = ShellState()
        shell.syncBaseSurface(isHome: false, hasFailure: true)
        shell.clearNovel(isHome: true, hasFailure: false)
        // Nothing was open, so a stray clear must not move the surface.
        XCTAssertEqual(shell.surface, .error)
    }
}
