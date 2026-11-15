import XCTest
import WebKit
@testable import Vela

@MainActor
final class ReportRegressionTests: XCTestCase {
    private func fixture() -> InstalledUserScriptState {
        InstalledUserScriptState(name: "Permissions", source: "window.__ran = true;",
                                 matches: ["https://*.example.com/Admin/*"],
                                 grants: [.gmXmlhttpRequest], connectRules: ["api.example.com"], runAt: .documentStart)
    }

    func testWildcardIncludesBareHostButPathIsCaseSensitive() throws {
        let script = fixture()
        XCTAssertTrue(UserScriptMatcher.matches(script, url: try XCTUnwrap(URL(string: "https://example.com/Admin/index"))))
        XCTAssertTrue(UserScriptMatcher.matches(script, url: try XCTUnwrap(URL(string: "https://www.example.com/Admin/index"))))
        XCTAssertFalse(UserScriptMatcher.matches(script, url: try XCTUnwrap(URL(string: "https://example.com/admin/index"))))
        XCTAssertFalse(UserScriptMatcher.matches(script, url: try XCTUnwrap(URL(string: "https://fakeexample.com/Admin/index"))))
    }

    func testNativePermissionsDenyGrantNoneAndUnlistedConnections() throws {
        XCTAssertEqual(UserScriptGrant(token: "GM.xmlHttpRequest"), .gmXmlhttpRequest)
        XCTAssertEqual(UserScriptGrant(token: "GM.getValue"), .gmGetValue)
        var script = fixture()
        let origin = try XCTUnwrap(URL(string: "https://example.com/Admin/"))
        XCTAssertTrue(UserScriptNativePolicy.allows(type: "xhr", payload: ["url": "https://api.example.com/items"], script: script, origin: origin))
        XCTAssertFalse(UserScriptNativePolicy.allows(type: "xhr", payload: ["url": "https://api.example.com.evil.test/items"], script: script, origin: origin))
        XCTAssertFalse(UserScriptNativePolicy.allows(type: "cookie", payload: ["action": "list"], script: script, origin: origin))
        script.grants = [.none]
        XCTAssertFalse(UserScriptNativePolicy.allows(type: "xhr", payload: ["url": "https://api.example.com/items"], script: script, origin: origin))
        script.grants = [.gmCookie]
        XCTAssertFalse(UserScriptNativePolicy.allows(type: "cookie", payload: ["action": "list", "details": ["domain": "other.test"]], script: script, origin: origin))
        XCTAssertFalse(UserScriptNativePolicy.cookiePath("/foo", matches: "/foobar"))
        XCTAssertTrue(UserScriptNativePolicy.cookiePath("/foo", matches: "/foo/bar"))
    }

    private final class LoadObserver: NSObject, WKNavigationDelegate {
        let expectation: XCTestExpectation
        init(_ expectation: XCTestExpectation) { self.expectation = expectation }
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { expectation.fulfill() }
        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            XCTFail(error.localizedDescription); expectation.fulfill()
        }
    }

    private func load(_ web: WKWebView) async {
        let done = expectation(description: "local fixture loaded")
        let observer = LoadObserver(done)
        web.navigationDelegate = observer
        web.loadHTMLString("<html><body><div class='ad-banner' id='ad'>ad</div><p id='normal'>article</p></body></html>", baseURL: URL(string: "https://example.com/Admin/"))
        await fulfillment(of: [done], timeout: 15)
        web.navigationDelegate = nil
        _ = observer
    }

    func testScriptGlobalsAndGMBridgeAreNotVisibleToPage() async throws {
        let config = WKWebViewConfiguration()
        let script = fixture()
        let world = "org.vela.test.isolated"
        let built = UserScriptInjector.makeUserScripts(for: [script], url: URL(string: "https://example.com/Admin/")!, valuesByScriptId: [:], worldsByScriptId: [script.id: world])
        built.scripts.forEach { config.userContentController.addUserScript($0) }
        let web = WKWebView(frame: .zero, configuration: config)
        await load(web)
        let isolated = try await web.evaluateJavaScript("window.__ran === true", in: nil, in: .world(name: world))
        XCTAssertEqual(isolated as? Bool, true)
        let page = try await web.evaluateJavaScript("typeof window.__ran === 'undefined' && typeof window.__velaUserScriptBridge === 'undefined' && !window.webkit?.messageHandlers?.velaUserScript")
        XCTAssertEqual(page as? Bool, true)
    }

    func testCosmeticRulesHideAdsAndRemovalRestoresPage() async throws {
        let result = AdBlockRuleCompiler.compile(filterList: "##.ad-banner")
        let store = try XCTUnwrap(WKContentRuleListStore.default())
        let identifier = UUID().uuidString
        let list = try await store.compileContentRuleList(forIdentifier: identifier, encodedContentRuleList: AdBlockRuleCompiler.encode(result.rules))
        let config = WKWebViewConfiguration()
        config.userContentController.add(try XCTUnwrap(list))
        let web = WKWebView(frame: .zero, configuration: config)
        await load(web)
        let hidden = try await web.evaluateJavaScript("getComputedStyle(document.getElementById('ad')).display === 'none' && getComputedStyle(document.getElementById('normal')).display !== 'none'")
        XCTAssertEqual(hidden as? Bool, true)
        config.userContentController.removeAllContentRuleLists()
        await load(web)
        let restored = try await web.evaluateJavaScript("getComputedStyle(document.getElementById('ad')).display !== 'none'")
        XCTAssertEqual(restored as? Bool, true)
        try? await store.removeContentRuleList(forIdentifier: identifier)
    }

    func testHiddenExceptionsNeverDisableNetworkRules() {
        let result = AdBlockRuleCompiler.compile(filterList: "##.ad\nexample.com#@#.ad\n||tracker.test^")
        XCTAssertFalse(result.rules.contains { $0.action.selector == ".ad" })
        XCTAssertTrue(result.rules.contains { $0.action.type == "block" })
    }
}
