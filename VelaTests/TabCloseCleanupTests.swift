//
//  TabCloseCleanupTests.swift
//  VelaTests
//
//  Closing a tab must stop the work a user script left behind for it: the
//  in-flight GM_xmlhttpRequest, the GM tab state and the page's menu commands.
//

import XCTest
@testable import Vela

@MainActor
final class TabCloseCleanupTests: XCTestCase {
    func testClosingATabReleasesItsUserScriptWork() throws {
        let harness = try BrowserHarness()
        harness.tabManager.onWillCloseTab = { [weak coordinator = harness.coordinator] tab in
            coordinator?.cleanupClosedTab(tab)
        }

        let tab = harness.tabManager.openTab(
            url: URL(string: "about:blank")!,
            privacyMode: .private
        )
        harness.coordinator.userScriptTabStates[tab.id] = "{\"value\":1}"
        harness.coordinator.overlays.userScriptMenuCommands.append(
            UserScriptMenuCommand(
                tabId: tab.id,
                scriptId: "script",
                scriptName: "Script",
                commandId: "command",
                name: "Command"
            )
        )
        let xhr = Task<Void, Never> {
            try? await Task.sleep(nanoseconds: 10_000_000_000)
            return ()
        }
        harness.coordinator.userScriptXHRTasks["\(tab.id)|script|request"] = xhr

        harness.tabManager.closeTab(id: tab.id)

        XCTAssertTrue(xhr.isCancelled, "the closed tab's request must be cancelled")
        XCTAssertNil(harness.coordinator.userScriptTabStates[tab.id])
        XCTAssertTrue(
            harness.coordinator.overlays.userScriptMenuCommands.allSatisfy { $0.tabId != tab.id }
        )
    }
}
