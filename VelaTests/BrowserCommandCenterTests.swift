import XCTest
@testable import Vela

@MainActor
final class BrowserCommandCenterTests: XCTestCase {
    func testRegistrationDoesNotStealFocusAndActivationSelectsWindow() {
        let center = BrowserCommandCenter()
        var calls: [String] = []
        center.register(owner: "a") { _ in calls.append("a") }
        XCTAssertFalse(center.isAvailable)
        center.setActive(owner: "a", active: true)
        center.register(owner: "b") { _ in calls.append("b") }
        center.perform(.newTab)
        center.setActive(owner: "b", active: true)
        center.perform(.newTab)
        center.setActive(owner: "b", active: false)
        center.perform(.newTab)
        XCTAssertEqual(calls, ["a", "b", "a"])
    }
    func testInactiveAndUnregisteredWindowsCannotReceiveCommands() {
        let center = BrowserCommandCenter()
        var calls = 0
        center.register(owner: "a") { _ in calls += 1 }
        center.setActive(owner: "a", active: true)
        center.setActive(owner: "a", active: false)
        center.perform(.closeTab)
        center.unregister(owner: "a")
        center.setActive(owner: "a", active: true)
        center.perform(.closeTab)
        XCTAssertEqual(calls, 0)
        XCTAssertFalse(center.isAvailable)
    }
}
