//
//  GoogleAccountServiceTests.swift
//  VelaTests
//
//  The Google account list is a set of labels on this device: it normalises,
//  it does not duplicate, it survives a relaunch and it refuses what cannot be
//  an address. Signing in and out touches WebKit, not this store.
//

import XCTest
@testable import Vela

@MainActor
final class GoogleAccountServiceTests: XCTestCase {
    private var suiteName = ""
    private var defaults: UserDefaults!

    override func setUp() async throws {
        try await super.setUp()
        suiteName = "GoogleAccountServiceTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        defaults.removePersistentDomain(forName: suiteName)
    }

    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        try await super.tearDown()
    }

    func testAddingAnAddressNormalisesIt() {
        let service = GoogleAccountService(defaults: defaults)
        let account = service.add(email: "  Vela.User@Gmail.com ", label: " 工作 ")
        XCTAssertEqual(account?.email, "vela.user@gmail.com")
        XCTAssertEqual(account?.label, "工作")
        XCTAssertEqual(service.accounts.count, 1)
    }

    func testTheSameAddressTwiceIsOneRowWithTheNewNote() {
        let service = GoogleAccountService(defaults: defaults)
        let first = service.add(email: "vela.user@gmail.com", label: "工作")
        let second = service.add(email: "VELA.USER@gmail.com", label: "小号")
        XCTAssertEqual(service.accounts.count, 1)
        XCTAssertEqual(second?.id, first?.id)
        XCTAssertEqual(service.accounts.first?.label, "小号")
    }

    func testAnAddressThatCannotBeOneIsRefused() {
        let service = GoogleAccountService(defaults: defaults)
        XCTAssertNil(service.add(email: "not-an-address", label: ""))
        XCTAssertNil(service.add(email: "user@localhost", label: ""))
        XCTAssertNil(service.add(email: "user @gmail.com", label: ""))
        XCTAssertTrue(service.accounts.isEmpty)
    }

    func testTheListSurvivesARelaunch() {
        let service = GoogleAccountService(defaults: defaults)
        service.add(email: "one@gmail.com", label: "一")
        service.add(email: "two@gmail.com", label: "二")

        let reloaded = GoogleAccountService(defaults: defaults)
        XCTAssertEqual(reloaded.accounts.map(\.email), ["one@gmail.com", "two@gmail.com"])
        XCTAssertEqual(reloaded.accounts.map(\.label), ["一", "二"])
    }

    func testRemovingOneLeavesTheRest() {
        let service = GoogleAccountService(defaults: defaults)
        let first = service.add(email: "one@gmail.com", label: "")
        service.add(email: "two@gmail.com", label: "")
        service.remove(id: first!.id)
        XCTAssertEqual(service.accounts.map(\.email), ["two@gmail.com"])
    }
}
