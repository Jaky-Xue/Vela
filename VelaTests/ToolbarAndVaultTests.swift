//
//  ToolbarAndVaultTests.swift
//  VelaTests
//
//  Pure value checks for the two new pieces of user configuration: the bottom
//  bar's stored order and the vault's host matching. Neither needs a web view,
//  a Keychain or a simulator window, which is why they run as ordinary unit
//  tests.
//

import XCTest
@testable import Vela

final class ToolbarLayoutTests: XCTestCase {
    func testMissingStoredSidesFallBackToTheShippedLayout() {
        let layout = ToolbarLayout(storedLeading: nil, storedTrailing: nil)
        XCTAssertEqual(layout.leading, [.back])
        XCTAssertEqual(layout.trailing, [.tabs, .menu])
    }

    func testUnknownAndDuplicateControlsAreDropped() {
        let layout = ToolbarLayout(
            storedLeading: ["back", "notAControl", "home", "home"],
            storedTrailing: ["tabs", "back", "menu"]
        )
        XCTAssertEqual(layout.leading, [.back, .home])
        // `back` already lives on the left, so it cannot appear twice.
        XCTAssertEqual(layout.trailing, [.tabs, .menu])
    }

    func testCapIsEnforcedOnRead() {
        let many = ToolbarControl.allCases.map(\.rawValue)
        let layout = ToolbarLayout(storedLeading: many, storedTrailing: many)
        XCTAssertEqual(layout.leading.count, ToolbarLayout.maximumPerSide)
        XCTAssertEqual(layout.trailing.count, ToolbarLayout.maximumPerSide)
        XCTAssertTrue(layout.leading.allSatisfy { !layout.trailing.contains($0) })
    }

    func testReplacingOneSideKeepsTheOther() {
        let layout = ToolbarLayout(leading: [.back, .home], trailing: [.tabs])
        let updated = layout.replacing(.leading, with: [.menu])
        XCTAssertEqual(updated.leading, [.menu])
        XCTAssertEqual(updated.trailing, [.tabs])
    }
}

final class VaultCredentialTests: XCTestCase {
    func testHostNormalizationAcceptsUrlsAndBareHosts() {
        XCTAssertEqual(VaultCredential.normalizeHost("https://www.Example.com/login?x=1"), "example.com")
        XCTAssertEqual(VaultCredential.normalizeHost("example.com"), "example.com")
        XCTAssertEqual(VaultCredential.normalizeHost("  WWW.Example.COM  "), "example.com")
    }

    func testCredentialFillsItsOwnSubdomainsButNotItsParent() {
        let credential = VaultCredential(
            title: "Example",
            host: "example.com",
            username: "alice",
            password: "secret"
        )
        XCTAssertTrue(credential.matches(host: "example.com"))
        XCTAssertTrue(credential.matches(host: "login.example.com"))
        XCTAssertTrue(credential.matches(host: "www.example.com"))
        XCTAssertFalse(credential.matches(host: "example.org"))
        XCTAssertFalse(credential.matches(host: "notexample.com"))

        let subdomain = VaultCredential(
            title: "Login",
            host: "login.example.com",
            username: "alice",
            password: "secret"
        )
        XCTAssertTrue(subdomain.matches(host: "login.example.com"))
        XCTAssertFalse(subdomain.matches(host: "example.com"))
    }

    func testEmptyUsernameIsStillAValidRecord() {
        let credential = VaultCredential(
            title: "",
            host: "example.com",
            username: "",
            password: "secret"
        )
        XCTAssertEqual(credential.username, "")
        XCTAssertEqual(VaultCredential.fallbackTitle(for: credential.host), "example.com")
    }
}
