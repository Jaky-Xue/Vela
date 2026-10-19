//
//  MenuLayoutTests.swift
//  VelaTests
//
//  The menu arrangement is a value: order, hidden built-ins and shortcuts are
//  normalised on read so old installs and hand-edited preferences cannot leave
//  a tile that does not exist.
//

import XCTest
@testable import Vela

final class MenuLayoutTests: XCTestCase {
    func testDefaultOrderShowsEveryBuiltinExceptLeavePrivate() {
        let layout = MenuLayout()
        XCTAssertEqual(layout.visibleTiles.count, MenuLayout.defaultOrder.count)
        XCTAssertFalse(layout.visibleTiles.contains { $0.id == VelaMenuAction.leavePrivate.rawValue })
    }

    func testUnknownStoredIdsAndHiddenIdsAreDropped() {
        let layout = MenuLayout(
            orderRaw: ["back-to-the-future", VelaMenuAction.bookmarks.rawValue],
            hiddenRaw: ["back-to-the-future", VelaMenuAction.bookmarks.rawValue],
            shortcutsRaw: nil
        )
        XCTAssertEqual(layout.visibleTiles.first?.id, MenuLayout.defaultOrder[0])
        XCTAssertFalse(layout.allTiles.contains { $0.id == "back-to-the-future" })
        XCTAssertEqual(layout.hiddenTiles.map(\.id), [VelaMenuAction.bookmarks.rawValue])
    }

    func testHidingAndShowingABuiltinKeepsItsSlot() {
        let id = MenuLayout.defaultOrder[1]
        var layout = MenuLayout()
        layout = layout.settingVisible(false, id: id)
        XCTAssertFalse(layout.visibleTiles.contains { $0.id == id })
        XCTAssertTrue(layout.hiddenTiles.contains { $0.id == id })

        layout = layout.settingVisible(true, id: id)
        XCTAssertEqual(layout.visibleTiles.map(\.id), MenuLayout.defaultOrder)
    }

    func testMovingAVisibleTilePreservesTheOthers() {
        var layout = MenuLayout()
        let first = MenuLayout.defaultOrder[0]
        let second = MenuLayout.defaultOrder[1]
        layout = layout.movingVisible(
            from: IndexSet(integer: 0),
            to: layout.visibleTiles.count
        )
        XCTAssertEqual(layout.visibleTiles.first?.id, second)
        XCTAssertEqual(layout.visibleTiles.last?.id, first)
        XCTAssertEqual(Set(layout.visibleTiles.map(\.id)).count, MenuLayout.defaultOrder.count)
    }

    func testShortcutAddAndRemove() {
        let shortcut = MenuShortcut(title: "工作台", url: "https://example.com/panel", symbolName: "star.fill")
        var layout = MenuLayout()
        layout = layout.adding(shortcut)
        XCTAssertTrue(layout.visibleTiles.contains { $0.id == shortcut.id })
        XCTAssertEqual(layout.shortcuts.count, 1)

        layout = layout.removingShortcut(id: shortcut.id)
        XCTAssertFalse(layout.visibleTiles.contains { $0.id == shortcut.id })
        XCTAssertTrue(layout.shortcuts.isEmpty)
    }
}

final class WebRTCGuardTests: XCTestCase {
    func testAllowShipsNoScript() {
        XCTAssertNil(WebRTCGuard.script(for: .allow))
    }

    func testBalancedFiltersCandidatesWithoutForcingRelay() {
        guard let script = WebRTCGuard.script(for: .balanced) else {
            return XCTFail("missing balanced script")
        }
        XCTAssertTrue(script.contains("var mode = \"balanced\""))
        XCTAssertTrue(script.contains("icecandidate"))
        XCTAssertTrue(script.contains("isPrivateAddress"))
    }

    func testStrictForcesRelayTransport() {
        guard let script = WebRTCGuard.script(for: .strict) else {
            return XCTFail("missing strict script")
        }
        XCTAssertTrue(script.contains("var mode = \"strict\""))
        XCTAssertTrue(script.contains("config.iceTransportPolicy = \"relay\""))
    }

    func testBlockedRemovesTheConstructor() {
        guard let script = WebRTCGuard.script(for: .blocked) else {
            return XCTFail("missing blocked script")
        }
        XCTAssertTrue(script.contains("NotAllowedError"))
        XCTAssertTrue(script.contains("getUserMedia"))
    }
}
