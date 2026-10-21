//
//  PrivateSessionStartTests.swift
//  VelaTests
//
//  The TabManager hook that tells the environment a new private session began.
//  It must fire only when the strip had no private tabs, not for every tab
//  appended to a live session.
//

import XCTest
import WebKit
@testable import Vela

@MainActor
private final class StartStubConfigurationProvider: BrowserWebViewConfigurationProviding {
    func makeConfiguration(for tab: BrowserTabState) -> WKWebViewConfiguration {
        WKWebViewConfiguration()
    }

    func webIdentity(for tab: BrowserTabState) -> BrowserWebIdentity {
        BrowserWebIdentity(applicationNameForUserAgent: "VelaTests/1.0")
    }

    var navigationDelegate: WKNavigationDelegate? { nil }
    var uiDelegate: WKUIDelegate? { nil }
}

@MainActor
final class PrivateSessionStartTests: XCTestCase {
    func testPrivateSessionStartFiresOnlyWhenThePrivateStripWasEmpty() {
        let manager = TabManager(configurationProvider: StartStubConfigurationProvider())
        var starts = 0
        manager.onPrivateSessionStarted = { starts += 1 }

        _ = manager.createTab(privacyMode: .private)
        XCTAssertEqual(starts, 1)

        _ = manager.openTab(
            url: URL(string: "about:blank")!,
            privacyMode: .private
        )
        XCTAssertEqual(starts, 1, "a second private tab is still the same session")

        manager.endPrivateSession()
        _ = manager.createTab(privacyMode: .private)
        XCTAssertEqual(starts, 2, "the first private tab after the strip emptied starts a new session")
    }
}
