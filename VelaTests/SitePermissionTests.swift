//
//  SitePermissionTests.swift
//  VelaTests
//
//  The pure rules behind the site-permission screen: how a stored per-site
//  answer is matched, and that an older preferences document still decodes
//  after the notification kind was added.
//

import XCTest
@testable import Vela

final class SitePermissionTests: XCTestCase {
    func testSiteRuleMatchesTheExactHostAndItsSubdomains() {
        let preferences = BrowserPreferences(
            sitePermissionRules: [
                SitePermissionSiteRule(host: "example.com", kind: .camera, rule: .allow)
            ]
        )

        XCTAssertEqual(
            preferences.sitePermissionRule(host: "example.com", kind: .camera),
            .allow
        )
        XCTAssertEqual(
            preferences.sitePermissionRule(host: "news.example.com", kind: .camera),
            .allow
        )
        XCTAssertNil(
            preferences.sitePermissionRule(host: "example.com", kind: .microphone)
        )
        XCTAssertNil(
            preferences.sitePermissionRule(host: "badexample.com", kind: .camera)
        )
    }

    func testTheLongestMatchingHostWins() {
        let preferences = BrowserPreferences(
            sitePermissionRules: [
                SitePermissionSiteRule(host: "example.com", kind: .location, rule: .allow),
                SitePermissionSiteRule(host: "news.example.com", kind: .location, rule: .block)
            ]
        )

        XCTAssertEqual(
            preferences.sitePermissionRule(host: "news.example.com", kind: .location),
            .block
        )
        XCTAssertEqual(
            preferences.sitePermissionRule(host: "blog.example.com", kind: .location),
            .allow
        )
    }

    func testAnOlderPermissionsDocumentReadsNotificationAsAsk() throws {
        let legacy = #"""
        {"camera":"allow","microphone":"ask","location":"block","sensor":"ask","clipboard":"ask"}
        """#.data(using: .utf8)!

        let decoded = try JSONDecoder().decode(SitePermissionDefaultSettings.self, from: legacy)
        XCTAssertEqual(decoded[.camera], .allow)
        XCTAssertEqual(decoded[.location], .block)
        XCTAssertEqual(decoded[.notification], .ask)
    }
}
