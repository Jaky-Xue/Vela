import XCTest
import WebKit
@testable import Vela

@MainActor
final class CompletionRegressionTests: XCTestCase {
    private func wait(_ expression: String, web: WKWebView) async throws {
        for _ in 0..<200 {
            if (try? await web.evaluateJavaScript(expression)) as? Bool == true { return }
            try await Task.sleep(nanoseconds: 25_000_000)
        }
        XCTFail("Timed out: " + expression)
    }
    func testPrivateHomeAndNewPagesNeverActivateRegularHome() throws {
        let h = try BrowserHarness()
        let regular = h.tabManager.activeTab!
        let page = h.tabManager.openTab(url: URL(string: "https://example.test")!, privacyMode: .private)
        let actions = BrowserNavigationActions(tabManager: h.tabManager, webCoordinator: h.coordinator)
        let home = try XCTUnwrap(actions.openHomeTab(from: page))
        XCTAssertTrue(home.isHome); XCTAssertEqual(home.privacyMode, .private)
        XCTAssertNotEqual(home.id, regular.id)
        XCTAssertEqual(h.tabManager.openTab(url: URL(string: "https://example.test/next")!).privacyMode, .private)
        h.tabManager.activateTab(id: regular.id)
        XCTAssertEqual(h.tabManager.createTab().privacyMode, .regular)
    }
    func testBackCannotCrossSessionThroughAnOpener() throws {
        let h = try BrowserHarness(), regular = h.tabManager.activeTab!
        let child = h.tabManager.openTab(url: URL(string: "https://example.test")!, privacyMode: .private, openerTabId: regular.id)
        let actions = BrowserNavigationActions(tabManager: h.tabManager, webCoordinator: h.coordinator)
        XCTAssertEqual(actions.backStep(for: child), .home)
    }
    func testPerFrameMatchingStorageAndManualMenuExecution() async throws {
        let server = try LocalHTTPServer(routes: ["/parent": .html("<title>Parent</title><iframe src='/child'></iframe>"), "/child": .html("<title>Child</title><p>child</p>")])
        let base = try await server.start(); defer { server.stop() }
        let h = try BrowserHarness(); h.settings.update { $0.userScriptsEnabled = true }
        let child = InstalledUserScriptState(name: "Child", source: "GM.setValue('frame',location.pathname).then(function(){document.documentElement.dataset.child='ok';});", matches: ["*://*/child"], grants: [.gmSetValue], runAt: .documentEnd)
        let parent = InstalledUserScriptState(name: "Parent", source: "document.documentElement.dataset.parent='ok';", matches: ["*://*/parent"], grants: [.none], runAt: .documentEnd)
        let manual = InstalledUserScriptState(name: "Manual", source: "document.documentElement.dataset.manual='ok';", matches: ["*://*/child"], grants: [.none], runAt: .toolMenu)
        var noframes = InstalledUserScriptState(name: "No frames", source: "document.documentElement.dataset.noframes='bad';", matches: ["*://*/child"], grants: [.none], runAt: .documentEnd)
        noframes.noframes = true
        for script in [child,parent,manual,noframes] { try h.coordinator.userScripts.upsert(script) }
        let tab = h.open(URL(string:"/parent",relativeTo:base)!); await waitForSettled(tab,expectingTitle:"Parent")
        let web = try XCTUnwrap(h.tabManager.webView(for:tab.id))
        try await wait("document.documentElement.dataset.parent==='ok' && document.querySelector('iframe').contentDocument.documentElement.dataset.child==='ok'",web:web)
        XCTAssertEqual(try h.coordinator.userScripts.value(key:"frame",scriptId:child.id), "\"/child\"")
        let boundaries = try await web.evaluateJavaScript("!document.documentElement.dataset.child && !document.querySelector('iframe').contentDocument.documentElement.dataset.parent && !document.querySelector('iframe').contentDocument.documentElement.dataset.noframes && !document.querySelector('iframe').contentDocument.documentElement.dataset.manual")
        XCTAssertEqual(boundaries as? Bool,true)
        h.coordinator.runMenuScript(id:manual.id,tabId:tab.id)
        try await wait("document.querySelector('iframe').contentDocument.documentElement.dataset.manual==='ok'",web:web)
    }
    func testManualHidesMatchEachFrameAndPauseWithoutReload() async throws {
        let server = try LocalHTTPServer(routes:["/parent":.html("<title>Manual</title><div id='ad' class='ad-banner'>ad</div><iframe id='child'></iframe><script>document.getElementById('child').src='http://localhost:'+location.port+'/child';</script>"), "/child":.html("<div id='ad' class='ad-banner'>child ad</div>")])
        let base = try await server.start(); defer { server.stop() }
        let h = try BrowserHarness()
        h.settings.updateContentBlocker { $0.enabled = false }
        h.settings.updateManualElementHide { $0.sites=[ManualElementHideSiteRules(host:"127.0.0.1",rules:[ManualElementHideRule(selector:"["),ManualElementHideRule(selector:".ad-banner")])] }
        let tab = h.open(base.appendingPathComponent("parent")); await waitForSettled(tab,expectingTitle:"Manual")
        let web = try XCTUnwrap(h.tabManager.webView(for:tab.id))
        try await wait("getComputedStyle(document.getElementById('ad')).display==='none'",web:web)
        var childFrame: WKFrameInfo?
        for _ in 0..<100 {
            childFrame=h.coordinator.manualHideFrames.values.first { $0.request.url?.host=="localhost" }
            if childFrame != nil { break }; try await Task.sleep(nanoseconds:25_000_000)
        }
        let frame=try XCTUnwrap(childFrame)
        let visible: Any = try await withCheckedThrowingContinuation { continuation in
            web.evaluateJavaScript("getComputedStyle(document.getElementById('ad')).display!=='none'",in:frame,in:.defaultClient) { continuation.resume(with:$0) }
        }
        XCTAssertEqual(visible as? Bool,true)
        h.settings.updateManualElementHide { $0.pausedHosts=["127.0.0.1"] }
        h.coordinator.applyManualElementHides(to:web,host:"127.0.0.1")
        try await wait("getComputedStyle(document.getElementById('ad')).display!=='none'",web:web)
    }

    func testIncludeExpansionIsBoundedAndRejectsCycles() async throws {
        let base = URL(string:"https://lists.test/main.txt")!
        let (text, expanded) = try await FilterIncludeResolver.expand("!#include child.txt\n||root.test^",base:base) { url in
            XCTAssertEqual(url.absoluteString,"https://lists.test/child.txt"); return "##.child-ad"
        }
        XCTAssertTrue(expanded); XCTAssertTrue(text.contains("##.child-ad")); XCTAssertTrue(text.contains("||root.test^"))
        do { _ = try await FilterIncludeResolver.expand("!#include main.txt",base:base) { _ in "||ad.test^" }; XCTFail("cycle accepted") } catch { }
        do { _ = try await FilterIncludeResolver.expand("!#include http://other.test/list",base:base) { _ in "||ad.test^" }; XCTFail("HTTP include accepted") } catch { }
    }
    func testScopedHideExceptionsPreserveOtherSitesAndNetworkRules() async throws {
        let result = AdBlockRuleCompiler.compile(filterList:"##.ad\nexample.com#@#.ad\n||tracker.test^")
        let hide = try XCTUnwrap(result.rules.first { $0.action.selector == ".ad" })
        XCTAssertEqual(hide.trigger.unlessDomain,["*example.com"])
        XCTAssertTrue(result.rules.contains { $0.action.type == "block" })
        let store = WKContentRuleListStore.default()!
        let id = UUID().uuidString
        _ = try await store.compileContentRuleList(forIdentifier:id,encodedContentRuleList:AdBlockRuleCompiler.encode(result.rules))
        try await store.removeContentRuleList(forIdentifier:id)
        let complex = AdBlockRuleCompiler.compile(filterList:"example.com,~shop.example.com##.ad\nexample.com#@#.ad\n~keep.example.com#@#.other\n##.other")
        _ = try await store.compileContentRuleList(forIdentifier:id,encodedContentRuleList:AdBlockRuleCompiler.encode(complex.rules))
        try await store.removeContentRuleList(forIdentifier:id)
        let mixed = AdBlockRuleCompiler.compile(filterList:"||ad.test^$script,domain=example.com|~shop.example.com\n/ads[0-9]+[.]js/$script")
        XCTAssertEqual(mixed.rules.count,2)
        _ = try await store.compileContentRuleList(forIdentifier:id,encodedContentRuleList:AdBlockRuleCompiler.encode(mixed.rules))
        try await store.removeContentRuleList(forIdentifier:id)
    }
    func testDiagnosticLineNumbersRetainBlankLines() {
        let result = AdBlockRuleCompiler.compile(filterList:"! header\n\n||ad.test^$unknown-option")
        XCTAssertEqual(result.diagnostics.first?.line,3)
        XCTAssertEqual(result.diagnostics.first?.text,"||ad.test^$unknown-option")
    }
    func testPageWorldRejectsNativePrivilegesAndInvalidatesAfterUpdate() throws {
        var script = InstalledUserScriptState(name:"Page",source:"unsafeWindow.test=1",matches:["*://*/*"],grants:[.unsafeWindow],runAt:.documentEnd)
        XCTAssertTrue(UserScriptService.permitsPageWorld(script))
        let h = try BrowserHarness(); try h.coordinator.userScripts.upsert(script)
        script = try XCTUnwrap(h.coordinator.userScripts.script(id: script.id))
        let service = UserScriptService(repository:h.coordinator.userScripts,settings:h.settings)
        service.setPageWorld(true,for:script)
        XCTAssertTrue(service.usesPageWorld(script))
        script.updatedAt = script.updatedAt.addingTimeInterval(1)
        XCTAssertFalse(service.usesPageWorld(script))
        script.grants.append(.gmCookie)
        XCTAssertFalse(UserScriptService.permitsPageWorld(script))
    }
    func testNetworkChunksArriveBeforeCompletionAndCrossOriginRedirectIsDeclined() async throws {
        let other = try LocalHTTPServer(routes: ["/secret": .html("secret")])
        let otherBase = try await other.start(); defer { other.stop() }
        let server = try LocalHTTPServer(routes: [
            "/stream": .init(body:"",contentType:"text/event-stream",chunks:["first\\n","second\\n"],chunkDelay:0.5),
            "/redirect": .redirect(to:otherBase.appendingPathComponent("secret").absoluteString)
        ])
        let base = try await server.start(); defer { server.stop() }
        var script = InstalledUserScriptState(name:"Stream",source:"",matches:["*://*/*"],grants:[.gmFetch],runAt:.documentEnd)
        script.connectRules=["127.0.0.1"]
        var firstAt: Date?, collected = Data()
        let (body, _) = try await UserScriptHTTP.load(URLRequest(url:base.appendingPathComponent("stream")),script:script,origin:base,buffered:false) { data,_,_ in
            if !data.isEmpty { firstAt = firstAt ?? Date(); collected.append(data) }
        }
        XCTAssertTrue(body.isEmpty)
        XCTAssertEqual(String(data:collected,encoding:.utf8),"first\\nsecond\\n")
        XCTAssertGreaterThan(Date().timeIntervalSince(try XCTUnwrap(firstAt)),0.15)
        let (_, response) = try await UserScriptHTTP.load(URLRequest(url:base.appendingPathComponent("redirect")),script:script,origin:base,buffered:true,progress:nil)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode,302)
        XCTAssertEqual(other.requestCount(for:"/secret"),0)
    }

    func testDownloadPermissionRequiresGrantAndConnect() {
        let origin = URL(string:"https://origin.test")!
        var script = InstalledUserScriptState(name:"Download",source:"",matches:["*://*/*"],grants:[.gmDownload],runAt:.documentEnd)
        script.connectRules=["files.test"]
        XCTAssertTrue(UserScriptNativePolicy.allows(type:"download",payload:["url":"https://files.test/file"],script:script,origin:origin))
        XCTAssertFalse(UserScriptNativePolicy.allows(type:"download",payload:["url":"https://evil.test/file"],script:script,origin:origin))
        script.grants=[.none]
        XCTAssertFalse(UserScriptNativePolicy.allows(type:"download",payload:["url":"https://files.test/file"],script:script,origin:origin))
    }
}
