//
//  WebAccountServiceTests.swift
//  VelaTests
//
//  The account list is a set of labels on this device: it normalises, it does
//  not duplicate within a provider, it refuses what cannot be an address, and
//  it is kept in the Keychain rather than in a preferences plist. Signing in
//  and out touches WebKit, not this store.
//

import XCTest
@testable import Vela

@MainActor
final class WebAccountServiceTests: XCTestCase {
    private var suiteName = ""
    private var defaults: UserDefaults!
    private var store: KeychainStore!

    override func setUp() async throws {
        try await super.setUp()
        suiteName = "WebAccountServiceTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        defaults.removePersistentDomain(forName: suiteName)
        store = KeychainStore(service: "WebAccountServiceTests-\(UUID().uuidString)")
    }

    override func tearDown() async throws {
        try? store.deleteAll()
        store = nil
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        try await super.tearDown()
    }

    private func makeService() -> WebAccountService {
        WebAccountService(store: store, legacyDefaults: defaults)
    }

    func testAddingAnAddressNormalisesIt() {
        let service = makeService()
        let account = service.add(provider: .google, email: "  Vela.User@Gmail.com ", label: " 工作 ")
        XCTAssertEqual(account?.email, "vela.user@gmail.com")
        XCTAssertEqual(account?.label, "工作")
        XCTAssertEqual(account?.provider, .google)
        XCTAssertEqual(service.accounts.count, 1)
    }

    func testTheSameAddressTwiceIsOneRow() {
        let service = makeService()
        let first = service.add(provider: .google, email: "vela.user@gmail.com", label: "工作")
        let second = service.add(provider: .google, email: "VELA.USER@gmail.com", label: "小号")
        XCTAssertEqual(service.accounts.count, 1)
        XCTAssertEqual(second?.id, first?.id)
        XCTAssertEqual(service.accounts.first?.label, "小号")
    }

    /// The same address on two providers is two different accounts — a Gmail
    /// address and the Apple ID of the same person are separate sign-ins.
    func testTheSameAddressOnTwoProvidersIsTwoRows() {
        let service = makeService()
        service.add(provider: .google, email: "same@example.com", label: "")
        service.add(provider: .apple, email: "same@example.com", label: "")
        XCTAssertEqual(service.accounts(for: .google).count, 1)
        XCTAssertEqual(service.accounts(for: .apple).count, 1)
        XCTAssertEqual(service.accounts.count, 2)
    }

    func testAnAddressThatCannotBeOneIsRefused() {
        let service = makeService()
        XCTAssertNil(service.add(provider: .google, email: "not-an-address", label: ""))
        XCTAssertNil(service.add(provider: .apple, email: "user@localhost", label: ""))
        XCTAssertNil(service.add(provider: .google, email: "user @gmail.com", label: ""))
        XCTAssertTrue(service.accounts.isEmpty)
    }

    func testTheListSurvivesARelaunch() {
        let service = makeService()
        service.add(provider: .google, email: "one@gmail.com", label: "一")
        service.add(provider: .apple, email: "two@icloud.com", label: "二")

        let reloaded = makeService()
        XCTAssertEqual(reloaded.accounts.map(\.email), ["one@gmail.com", "two@icloud.com"])
        XCTAssertEqual(reloaded.accounts(for: .apple).first?.label, "二")
    }

    func testRemovingOneLeavesTheRest() {
        let service = makeService()
        let first = service.add(provider: .google, email: "one@gmail.com", label: "")
        service.add(provider: .apple, email: "two@icloud.com", label: "")
        service.remove(id: first!.id)
        XCTAssertTrue(service.accounts(for: .google).isEmpty)
        XCTAssertEqual(service.accounts(for: .apple).count, 1)
    }

    /// The addresses are personal identifiers; they must not sit in a plist.
    func testTheListIsKeptOutOfUserDefaults() {
        let service = makeService()
        service.add(provider: .google, email: "vela.user@gmail.com", label: "")
        XCTAssertNil(defaults.data(forKey: "org.vela.browser.web-accounts"))
    }

    /// The first 4.0.72 build wrote the list as JSON in `UserDefaults`. An
    /// install that ran it is carried into the Keychain once.
    func testALegacyPreferencesListMovesIntoTheKeychain() throws {
        let legacy = [WebAccount(provider: .google, email: "old@gmail.com", label: "旧")]
        defaults.set(try JSONEncoder().encode(legacy), forKey: "org.vela.browser.web-accounts")

        let service = makeService()
        XCTAssertEqual(service.accounts.map(\.email), ["old@gmail.com"])
        XCTAssertNil(defaults.data(forKey: "org.vela.browser.web-accounts"))

        // Now read from the Keychain, not from the preferences document.
        let reloaded = makeService()
        XCTAssertEqual(reloaded.accounts.map(\.email), ["old@gmail.com"])
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

    /// No installed user script runs on a sign-in page, whatever it matched.
    func testSignInPagesAreProtectedFromUserScripts() {
        XCTAssertTrue(WebAccountProvider.isProtectedSignInHost("accounts.google.com"))
        XCTAssertTrue(WebAccountProvider.isProtectedSignInHost("ACCOUNTS.GOOGLE.COM"))
        XCTAssertTrue(WebAccountProvider.isProtectedSignInHost("appleid.apple.com"))
        XCTAssertTrue(WebAccountProvider.isProtectedSignInHost("idmsa.apple.com"))
        XCTAssertFalse(WebAccountProvider.isProtectedSignInHost("www.google.com"))
        XCTAssertFalse(WebAccountProvider.isProtectedSignInHost("mail.google.com"))
        XCTAssertFalse(WebAccountProvider.isProtectedSignInHost(""))
    }
}
