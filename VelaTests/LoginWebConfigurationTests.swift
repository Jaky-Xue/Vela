//
//  LoginWebConfigurationTests.swift
//  VelaTests
//
//  The sign-in page is the one web view in the app that runs no third-party
//  code: no userscripts, no GM bridge, no page scripts beyond the appearance
//  stylesheet. That promise is easy to lose while adding a feature, so this
//  test is what keeps it.
//

import XCTest
import WebKit
@testable import Vela

@MainActor
final class LoginWebConfigurationTests: XCTestCase {
    func testTheSignInPageInjectsNothingButTheAppearanceStylesheet() {
        let scripts = LoginWebConfiguration.make().userContentController.userScripts
        XCTAssertEqual(
            scripts.count,
            1,
            "a password form gets the appearance stylesheet and nothing else"
        )
        XCTAssertEqual(
            scripts.first?.source,
            WebPageScripts.makeAppearanceScript().source
        )
    }

    func testTheSignInPageKeepsTheBrowsersOwnCookieJar() {
        let configuration = LoginWebConfiguration.make()
        // The default store is the point of signing in here: the session the
        // tabs already use.
        XCTAssertTrue(configuration.websiteDataStore === WKWebsiteDataStore.default())
    }

    /// 网页标识 must not reach a password form. The Safari tail is a header —
    /// it makes the page read the app as Safari rather than as a bare web view
    /// — not an identity the user chose.
    func testTheSignInPageClaimsTheSystemBrowserWithoutOverridingIt() {
        let configuration = LoginWebConfiguration.make()
        XCTAssertEqual(configuration.applicationNameForUserAgent, BrowserUserAgent.safariTail)
        XCTAssertFalse(BrowserUserAgent.safariTail.isEmpty)
    }
}
