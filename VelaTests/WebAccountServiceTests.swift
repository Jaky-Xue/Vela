//
//  WebAccountServiceTests.swift
//  VelaTests
//
//  The account list is a set of labels on this device: it normalises, it does
//  not duplicate within a provider, it survives a relaunch and it refuses what
//  cannot be an address. Signing in and out touches WebKit, not this store.
//

import XCTest
@testable import Vela

@MainActor
final class WebAccountServiceTests: XCTestCase {
    private var suiteName = ""
    private var defaults: UserDefaults!

    override func setUp() async throws {
        try await super.setUp()
        suiteName = "WebAccountServiceTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        defaults.removePersistentDomain(forName: suiteName)
    }

    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        try await super.tearDown()
    }

    func testAddingAnAddressNormalisesIt() {
        let service = WebAccountService(defaults: defaults)
        let account = service.add(provider: .google, email: "  Vela.User@Gmail.com ", label: " 工作 ")
        XCTAssertEqual(account?.email, "vela.user@gmail.com")
        XCTAssertEqual(account?.label, "工作")
        XCTAssertEqual(account?.provider, .google)
        XCTAssertEqual(service.accounts.count, 1)
    }

    func testTheSameAddressTwiceIsOneRow() {
        let service = WebAccountService(defaults: defaults)
        let first = service.add(provider: .google, email: "vela.user@gmail.com", label: "工作")
        let second = service.add(provider: .google, email: "VELA.USER@gmail.com", label: "小号")
        XCTAssertEqual(service.accounts.count, 1)
        XCTAssertEqual(second?.id, first?.id)
        XCTAssertEqual(service.accounts.first?.label, "小号")
    }

    /// The same address on two providers is two different accounts — a Gmail
    /// address and the Apple ID of the same person are separate sign-ins.
    func testTheSameAddressOnTwoProvidersIsTwoRows() {
        let service = WebAccountService(defaults: defaults)
        service.add(provider: .google, email: "same@example.com", label: "")
        service.add(provider: .apple, email: "same@example.com", label: "")
        XCTAssertEqual(service.accounts(for: .google).count, 1)
        XCTAssertEqual(service.accounts(for: .apple).count, 1)
        XCTAssertEqual(service.accounts.count, 2)
    }

    func testAnAddressThatCannotBeOneIsRefused() {
        let service = WebAccountService(defaults: defaults)
        XCTAssertNil(service.add(provider: .google, email: "not-an-address", label: ""))
        XCTAssertNil(service.add(provider: .apple, email: "user@localhost", label: ""))
        XCTAssertNil(service.add(provider: .google, email: "user @gmail.com", label: ""))
        XCTAssertTrue(service.accounts.isEmpty)
    }

    func testTheListSurvivesARelaunch() {
        let service = WebAccountService(defaults: defaults)
        service.add(provider: .google, email: "one@gmail.com", label: "一")
        service.add(provider: .apple, email: "two@icloud.com", label: "二")

        let reloaded = WebAccountService(defaults: defaults)
        XCTAssertEqual(reloaded.accounts.map(\.email), ["one@gmail.com", "two@icloud.com"])
        XCTAssertEqual(reloaded.accounts(for: .apple).first?.label, "二")
    }

    func testRemovingOneLeavesTheRest() {
        let service = WebAccountService(defaults: defaults)
        let first = service.add(provider: .google, email: "one@gmail.com", label: "")
        service.add(provider: .apple, email: "two@icloud.com", label: "")
        service.remove(id: first!.id)
        XCTAssertTrue(service.accounts(for: .google).isEmpty)
        XCTAssertEqual(service.accounts(for: .apple).count, 1)
    }

    /// Each provider signs in and is cleared at its own addresses.
    func testProvidersPointAtTheirOwnPagesAndDomains() {
        XCTAssertEqual(WebAccountProvider.google.signInURL?.host, "accounts.google.com")
        XCTAssertEqual(WebAccountProvider.apple.signInURL?.host, "appleid.apple.com")
        XCTAssertEqual(WebAccountProvider.google.accountPageURL?.host, "myaccount.google.com")
        XCTAssertEqual(WebAccountProvider.apple.accountPageURL?.host, "account.apple.com")
        XCTAssertTrue(WebAccountProvider.google.domainsToClear.contains("google.com"))
        XCTAssertTrue(WebAccountProvider.apple.domainsToClear.contains("apple.com"))
        XCTAssertFalse(WebAccountProvider.google.sessionCookieNames.isEmpty)
        XCTAssertFalse(WebAccountProvider.apple.sessionCookieNames.contains("SID"))
        XCTAssertTrue(WebAccountProvider.apple.sessionCookieNames.contains("myacinfo"))
    }
}
