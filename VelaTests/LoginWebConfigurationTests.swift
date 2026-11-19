//
//  LoginWebConfigurationTests.swift
//  VelaTests
//
//  The sign-in page is the one web view in the app that runs no third-party
//  code: no userscripts, no GM bridge, no page scripts at all. That promise is
//  easy to lose while adding a feature, so this test is what keeps it.
//

import XCTest
import WebKit
@testable import Vela

@MainActor
final class LoginWebConfigurationTests: XCTestCase {
    func testTheSignInPageInjectsNothing() {
        let scripts = LoginWebConfiguration.make().userContentController.userScripts
        XCTAssertTrue(scripts.isEmpty, "a password form gets no script at all")
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
