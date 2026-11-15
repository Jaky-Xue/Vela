import XCTest
import WebKit
@testable import Vela

@MainActor
final class ScriptStorageIntegrationTests: XCTestCase {
    private func eval(_ source: String, web: WKWebView, world: String) async throws -> Any {
        try await withCheckedThrowingContinuation { continuation in
            web.evaluateJavaScript(source, in: nil, in: .world(name: world)) { continuation.resume(with: $0) }
        }
    }
    private func waitJS(_ source: String, web: WKWebView, world: String) async throws {
        for _ in 0..<150 {
            if (try await eval(source, web: web, world: world)) as? Bool == true { return }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTFail("JavaScript condition timed out: " + source)
    }

    func testAsyncWritesBroadcastAcrossTabsAndDatabaseFailureRejectsPromise() async throws {
        let server = try LocalHTTPServer(routes: ["/one": .html(TestPages.titled("One")), "/two": .html(TestPages.titled("Two"))])
        let base = try await server.start()
        defer { server.stop() }
        let harness = try BrowserHarness()
        harness.settings.update { $0.userScriptsEnabled = true }
        let script = InstalledUserScriptState(name: "Storage", source: "window.lastRemote = null; GM_addValueChangeListener('x', function(k, oldValue, value, remote) { window.lastRemote = { value: value, remote: remote }; });",
            matches: ["*://*/*"], grants: [.gmGetValue, .gmSetValue, .gmDeleteValue, .gmAddValueChangeListener], runAt: .documentStart)
        try harness.coordinator.userScripts.upsert(script)
        let first = harness.open(URL(string: "/one", relativeTo: base)!)
        await waitForSettled(first, expectingTitle: "One")
        let second = harness.open(URL(string: "/two", relativeTo: base)!)
        await waitForSettled(second, expectingTitle: "Two")
        let a = try XCTUnwrap(harness.tabManager.webView(for: first.id))
        let b = try XCTUnwrap(harness.tabManager.webView(for: second.id))
        let aw = try XCTUnwrap(harness.coordinator.userScriptWorlds[first.id + "|" + script.id])
        let bw = try XCTUnwrap(harness.coordinator.userScriptWorlds[second.id + "|" + script.id])
        _ = try await eval("GM.setValue('x', 42).then(function(){ window.writeDone = true; }); true;", web: a, world: aw)
        try await waitJS("window.writeDone === true", web: a, world: aw)
        _ = try await eval("GM.getValue('x').then(function(value){ window.authoritativeRead = value; }); true;", web: b, world: bw)
        try await waitJS("window.authoritativeRead === 42", web: b, world: bw)
        XCTAssertEqual(try harness.coordinator.userScripts.value(key: "x", scriptId: script.id), "42")
        try await waitJS("GM_getValue('x') === 42 && window.lastRemote && window.lastRemote.remote === true", web: b, world: bw)

        try harness.database.execute("CREATE TRIGGER reject_gm_insert BEFORE INSERT ON \(BrowserSchema.userScriptValuesTable) BEGIN SELECT RAISE(ABORT, 'injected write failure'); END")
        _ = try await eval("GM.setValue('x', 77).catch(function(){ window.writeRejected = true; }); true;", web: a, world: aw)
        try await waitJS("window.writeRejected === true", web: a, world: aw)
        XCTAssertEqual(try harness.coordinator.userScripts.value(key: "x", scriptId: script.id), "42")
        let unchanged = try await eval("GM_getValue('x') === 42", web: a, world: aw)
        XCTAssertEqual(unchanged as? Bool, true)
        try harness.database.execute("DROP TRIGGER reject_gm_insert")

        _ = try await eval("GM.deleteValue('x').then(function(){ window.deleteDone = true; }); true;", web: b, world: bw)
        try await waitJS("window.deleteDone === true", web: b, world: bw)
        try await waitJS("typeof GM_getValue('x') === 'undefined' && window.lastRemote.remote === true", web: a, world: aw)
        XCTAssertNil(try harness.coordinator.userScripts.value(key: "x", scriptId: script.id))
        _ = try await eval("window.__velaUserScriptBridge.applyValue('x', '999', false, false, 1, true); true;", web: a, world: aw)
        let staleIgnored = try await eval("typeof GM_getValue('x') === 'undefined'", web: a, world: aw)
        XCTAssertEqual(staleIgnored as? Bool, true)
        _ = try await eval("window.__velaUserScriptBridge.applyValue('beta', '2', false, false, 100, true); window.__velaUserScriptBridge.applyValue('alpha', '1', false, false, 99, true); true;", web: a, world: aw)
        let differentKeys = try await eval("GM_getValue('alpha') === 1 && GM_getValue('beta') === 2", web: a, world: aw)
        XCTAssertEqual(differentKeys as? Bool, true)
    }
}
