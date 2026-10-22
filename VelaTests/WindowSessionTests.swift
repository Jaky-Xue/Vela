//
//  WindowSessionTests.swift
//  VelaTests
//
//  R-18: the first window's session survives a relaunch and a Stage Manager
//  window's session is separate. The repository is the single authority for
//  that split; this pins it without needing two scenes.
//

import XCTest
@testable import Vela

@MainActor
final class WindowSessionTests: XCTestCase {
    func testWindowsKeepSeparateSessions() throws {
        let database = try SQLiteDatabase(path: ":memory:")
        for statement in BrowserSchema.creationStatements {
            try database.execute(statement)
        }
        let repository = TabSessionRepository(database: database)

        let firstTab = BrowserTabState(url: "https://one.example", isHome: false)
        let secondTab = BrowserTabState(url: "https://two.example", isHome: false)
        let main = BrowserSessionSnapshot(
            tabs: [firstTab.record],
            activeTabId: firstTab.id,
            tabSequence: 1
        )
        let stage = BrowserSessionSnapshot(
            tabs: [secondTab.record],
            activeTabId: secondTab.id,
            tabSequence: 1
        )

        try repository.saveSession(main, windowId: "window-main")
        try repository.saveSession(stage, windowId: "window-stage")

        XCTAssertEqual(
            try repository.loadSession(windowId: "window-main")?.tabs.map(\.url),
            ["https://one.example"]
        )
        XCTAssertEqual(
            try repository.loadSession(windowId: "window-stage")?.tabs.map(\.url),
            ["https://two.example"]
        )

        try repository.removeSessions(except: ["window-main"])
        XCTAssertNotNil(try repository.loadSession(windowId: "window-main"))
        XCTAssertNil(try repository.loadSession(windowId: "window-stage"))
    }
}
