//
//  MediaPlayerTests.swift
//  VelaTests
//
//  The host half of the fullscreen player: what a page's `enter` and `state`
//  messages become, and the control surface the injected script must keep
//  exposing. The script itself is exercised against a real DOM by the CI
//  simulator; these tests pin the contract the native layer depends on.
//

import Foundation
import XCTest
@testable import Vela

final class MediaFullscreenSessionTests: XCTestCase {
    private func payload(_ extra: [String: Any]) -> [String: Any] {
        var value: [String: Any] = ["event": "enter"]
        for (key, item) in extra { value[key] = item }
        return value
    }

    func testEnterBuildsAContainerSession() throws {
        let session = try XCTUnwrap(
            MediaFullscreenSession(
                tabId: "tab-1",
                payload: payload([
                    "mode": "container",
                    "title": "示例视频",
                    "duration": 120.5,
                    "currentTime": 12,
                    "paused": false,
                    "muted": true,
                    "volume": 0.5,
                    "readyState": 3,
                    "canSeek": true
                ]),
                fallbackTitle: "标签页标题",
                isMainFrame: false
            )
        )

        XCTAssertEqual(session.tabId, "tab-1")
        XCTAssertEqual(session.mode, .container)
        XCTAssertEqual(session.title, "示例视频")
        XCTAssertEqual(session.duration, 120.5)
        XCTAssertEqual(session.currentTime, 12)
        XCTAssertFalse(session.isPaused)
        XCTAssertTrue(session.isMuted)
        XCTAssertEqual(session.volume, 0.5)
        XCTAssertTrue(session.isReady)
        XCTAssertTrue(session.canSeek)
        XCTAssertFalse(session.isMainFrame)
    }

    func testEmptyTitleFallsBackToTheTabTitle() throws {
        let session = try XCTUnwrap(
            MediaFullscreenSession(
                tabId: "tab-1",
                payload: payload(["title": "   "]),
                fallbackTitle: "标签页标题",
                isMainFrame: true
            )
        )
        XCTAssertEqual(session.title, "标签页标题")
    }

    func testEnterIgnoresOtherEvents() {
        XCTAssertNil(
            MediaFullscreenSession(
                tabId: "tab-1",
                payload: ["event": "state"],
                fallbackTitle: "",
                isMainFrame: true
            )
        )
    }

    func testStateUpdatesTheSession() throws {
        var session = try XCTUnwrap(
            MediaFullscreenSession(
                tabId: "tab-1",
                payload: payload(["mode": "video", "duration": 60]),
                fallbackTitle: "",
                isMainFrame: true
            )
        )

        let applied = session.applyState([
            "event": "state",
            "duration": 90,
            "currentTime": 30,
            "paused": false,
            "muted": false,
            "volume": 1,
            "ended": true,
            "readyState": 4,
            "canSeek": true
        ])

        XCTAssertTrue(applied)
        XCTAssertEqual(session.duration, 90)
        XCTAssertEqual(session.currentTime, 30)
        XCTAssertFalse(session.isPaused)
        XCTAssertTrue(session.isEnded)
        XCTAssertTrue(session.isReady)
        XCTAssertTrue(session.canSeek)
    }

    func testStateRejectsAnotherEvent() throws {
        var session = try XCTUnwrap(
            MediaFullscreenSession(
                tabId: "tab-1",
                payload: payload(["duration": 60]),
                fallbackTitle: "",
                isMainFrame: true
            )
        )
        XCTAssertFalse(session.applyState(["event": "enter"]))
        XCTAssertEqual(session.duration, 60)
    }

    func testNonFiniteNumbersAreTreatedAsZero() throws {
        let session = try XCTUnwrap(
            MediaFullscreenSession(
                tabId: "tab-1",
                payload: payload(["duration": Double.nan, "currentTime": Double.infinity]),
                fallbackTitle: "",
                isMainFrame: true
            )
        )
        XCTAssertEqual(session.duration, 0)
        XCTAssertEqual(session.currentTime, 0)
    }

    func testCurrentTimeIsClampedIntoTheFilm() throws {
        let session = try XCTUnwrap(
            MediaFullscreenSession(
                tabId: "tab-1",
                payload: payload(["duration": 10, "currentTime": 99]),
                fallbackTitle: "",
                isMainFrame: true
            )
        )
        XCTAssertEqual(session.currentTime, 10)
    }
}

final class MediaPlayerScriptTests: XCTestCase {
    func testScriptKeepsItsControlSurface() {
        let script = WebPageScripts.mediaPlayerScript
        XCTAssertTrue(script.contains("window.__velaPlayer"))
        XCTAssertTrue(script.contains("velaMediaFullscreen"))
        XCTAssertTrue(script.contains("command: command"))
        XCTAssertTrue(script.contains("promoteFrame: promoteFrame"))
    }

    func testScriptIsInjectedWithTheOtherPageScripts() {
        // The reader of `attachPageScripts` is the only place the set exists;
        // a script that is never attached would be invisible in every test.
        XCTAssertTrue(WebPageScripts.Handler.allCases.contains(.mediaFullscreen))
    }
}
