//
//  WebNavigationIntegrationTests.swift
//  VelaTests
//
//  Real `WKWebView` navigations, on the production path, against a local server.
//
//  These are the tests that answer "does the browser open a page". Every one of
//  them drives `TabManager.load(url:in:)` with the real `BrowserWebCoordinator`
//  as the navigation delegate — the same objects the app runs — and asserts on
//  the tab's observable state rather than on anything internal to WebKit.
//
//  The failure cases matter as much as the successes. The bug this suite was
//  written for was not that pages failed to load; it was that a page which
//  failed was indistinguishable from a browser that was broken, and that a link
//  opening a new tab made the *current* page look like it had failed.
//

import XCTest
import WebKit
@testable import Vela

@MainActor
final class WebNavigationIntegrationTests: XCTestCase {
    private var server: LocalHTTPServer!
    private var base: URL!
    private var harness: BrowserHarness!

    override func setUp() async throws {
        try await super.setUp()

        server = try LocalHTTPServer(routes: Self.routes())
        base = try await server.start()
        harness = try BrowserHarness()
    }

    override func tearDown() async throws {
        server?.stop()
        server = nil
        base = nil
        harness = nil
        try await super.tearDown()
    }

    private static func routes() -> [String: LocalHTTPServer.Response] {
        [
            "/one": .html(TestPages.titled("Page One")),
            "/two": .html(TestPages.titled("Page Two")),
            "/scripted": .html(TestPages.javascript),
            "/links": .html(TestPages.links()),
            "/ads": .html(TestPages.withAdSlot),
            "/with-query": .html(TestPages.titled("Query")),
            "/redirect": .redirect(to: "/two"),
            "/redirect-chain": .redirect(to: "/redirect"),
            "/not-found": .html(TestPages.titled("Server 404"), status: 404),
            "/server-error": .html(TestPages.titled("Server 500"), status: 500),
            "/forbidden": .html(TestPages.titled("Server 403"), status: 403),
            "/slow": LocalHTTPServer.Response(body: TestPages.titled("Slow"), delay: 3)
        ]
    }

    private func url(_ path: String) -> URL {
        URL(string: path, relativeTo: base)!
    }

    // MARK: - A page loads

    func testAPlainPageLoadsAndReportsItsTitleAndUrl() async {
        let tab = harness.open(url("/one"))
        await waitForSettled(tab, expectingTitle: "Page One")

        XCTAssertEqual(tab.loadState, .finished)
        XCTAssertFalse(tab.isLoading)
        XCTAssertEqual(tab.estimatedProgress, 1)
        XCTAssertEqual(tab.url, url("/one").absoluteString)
        XCTAssertEqual(tab.title, "Page One")
        XCTAssertNil(tab.lastFailure)
        XCTAssertEqual(tab.serverStatus, 200)
    }

    /// The regression that started this: the request must be issued once.
    ///
    /// `WebViewHost` used to issue a second one whenever the web view had no
    /// committed URL, which raced the load `TabManager` had already started. The
    /// server counts what it actually received, so this cannot be satisfied by
    /// the app merely believing it loaded once.
    func testAPageIsRequestedExactlyOnce() async {
        let tab = harness.open(url("/one"))
        await waitForSettled(tab)

        XCTAssertEqual(tab.loadState, .finished)
        XCTAssertEqual(server.requestCount(for: "/one"), 1)
    }

    func testJavaScriptExecutesInTheLoadedPage() async {
        let tab = harness.open(url("/scripted"))
        await waitForSettled(tab)

        XCTAssertEqual(tab.loadState, .finished)
        guard let webView = harness.tabManager.webView(for: tab.id) else {
            return XCTFail("no web view for the tab")
        }

        let marker = try? await webView.evaluateJavaScript("document.getElementById('marker').textContent")
        XCTAssertEqual(marker as? String, "ran")
        XCTAssertEqual(tab.title, "after")
    }

    func testAQueryStringIsPreserved() async {
        let tab = harness.open(url("/with-query?q=hello%20world&n=2"))
        await waitForSettled(tab)

        XCTAssertEqual(tab.loadState, .finished)
        XCTAssertTrue(tab.url.contains("q=hello%20world"), "url was \(tab.url)")
        XCTAssertTrue(tab.url.contains("n=2"))
        XCTAssertEqual(server.requestedPaths.last, "/with-query")
    }

    // MARK: - Redirects

    func testARedirectEndsOnTheDestinationUrl() async {
        let tab = harness.open(url("/redirect"))
        await waitForSettled(tab, expectingTitle: "Page Two")

        XCTAssertEqual(tab.loadState, .finished)
        XCTAssertEqual(tab.url, url("/two").absoluteString)
        XCTAssertEqual(tab.title, "Page Two")
        XCTAssertNil(tab.lastFailure)
    }

    func testARedirectChainEndsOnTheDestinationUrl() async {
        let tab = harness.open(url("/redirect-chain"))
        await waitForSettled(tab)

        XCTAssertEqual(tab.loadState, .finished)
        XCTAssertEqual(tab.url, url("/two").absoluteString)
    }

    func testTheNavigationLogRecordsTheRedirect() async {
        let tab = harness.open(url("/redirect"))
        await waitForSettled(tab)

        let events = harness.navigationLog.entries.filter { $0.tabId == tab.id }.map(\.event)
        XCTAssertTrue(events.contains(.start), "events were \(events)")
        XCTAssertTrue(events.contains(.redirect), "events were \(events)")
        XCTAssertTrue(events.contains(.finish), "events were \(events)")
    }

    // MARK: - HTTP error responses are pages, not failures

    /// A 404 is a document the server sent and WebKit rendered. Reporting it as a
    /// navigation failure would replace the server's own page with Vela's error
    /// surface, which is both wrong and less useful.
    func testAnHttpErrorStatusIsARenderedPageNotANavigationFailure() async {
        let cases: [(path: String, status: Int, title: String)] = [
            ("/not-found", 404, "Server 404"),
            ("/server-error", 500, "Server 500"),
            ("/forbidden", 403, "Server 403")
        ]

        for expected in cases {
            let tab = harness.open(url(expected.path))
            await waitForSettled(tab, expectingTitle: expected.title)

            XCTAssertEqual(tab.loadState, .finished, "\(expected.path) should commit and finish")
            XCTAssertNil(tab.lastFailure, "\(expected.path) should not produce a failure")
            XCTAssertEqual(tab.serverStatus, expected.status)
            XCTAssertEqual(tab.title, expected.title)
        }
    }

    func testTheServerStatusIsVisibleToTheShell() async {
        let tab = harness.open(url("/not-found"))
        await waitForSettled(tab)

        // The shell shows a one-line notice from this and leaves the document
        // alone; the assertion here is that the number survives to be shown.
        XCTAssertEqual(tab.serverStatus, 404)
        XCTAssertFalse(tab.isHome)
    }

    // MARK: - Network failures

    /// The scheme is `https` so that what fails is DNS and nothing else. It used
    /// to matter more than that: an `http` URL to a host that cannot resolve was
    /// stopped by App Transport Security before DNS was consulted, which is why
    /// the web-content exemption is now asserted directly in
    /// `PublicWebSmokeTests.testACleartextHttpPageOpens`.
    func testAnUnresolvableHostFailsWithADnsReason() async {
        let tab = harness.open(URL(string: "https://nonexistent-host.vela-invalid.test/")!)
        await waitForSettled(tab)

        XCTAssertEqual(tab.loadState, .failed, "events: \(harness.trace(for: tab))")
        XCTAssertFalse(tab.isLoading)
        XCTAssertEqual(
            tab.lastFailure?.kind,
            .dns,
            "error was \(tab.lastFailure?.errorDomain ?? "-")/\(tab.lastFailure?.errorCode ?? 0)"
        )
        XCTAssertEqual(tab.lastFailure?.title, "找不到该网站")
        XCTAssertTrue(tab.lastFailure?.isRetryable == true)
    }

    func testAConnectionRefusedFailsWithARefusedReason() async throws {
        // A port found by binding a listener and cancelling it, so nothing is
        // listening on it by construction.
        let closed = try await LocalHTTPServer.closedLoopbackPort()
        let tab = harness.open(URL(string: "http://127.0.0.1:\(closed)/")!)
        await waitForSettled(tab)

        XCTAssertEqual(tab.loadState, .failed, "events: \(harness.trace(for: tab))")
        XCTAssertFalse(tab.isLoading)
        // Two outcomes are honest here and the difference is WebKit's, not
        // Vela's: either the connection is reported as refused, or WebKit
        // commits its own empty document and reports nothing at all — which the
        // coordinator turns into `emptyResponse` rather than into a success.
        // What must not happen is the third possibility, a tab that says it
        // loaded a page it never received.
        XCTAssertTrue(
            [.refused, .emptyResponse].contains(tab.lastFailure?.kind ?? .other),
            "error was \(tab.lastFailure?.errorDomain ?? "-")/\(tab.lastFailure?.errorCode ?? 0) "
                + "kind=\(tab.lastFailure?.kind.rawValue ?? "none")"
        )
        XCTAssertFalse(tab.lastFailure?.detail.isEmpty ?? true)
    }

    /// A failure must not leave the address bar spinning.
    func testAFailureClearsTheLoadingState() async {
        let tab = harness.open(URL(string: "https://nonexistent-host.vela-invalid.test/")!)
        await waitForSettled(tab)

        XCTAssertFalse(tab.isLoading)
        XCTAssertEqual(tab.estimatedProgress, 0)
        XCTAssertEqual(tab.pendingUrl, "")
    }

    /// A page that failed can be fetched again, and the failure does not survive
    /// the page that loads.
    func testAFailedTabLoadsAgainAndClearsTheFailure() async {
        let tab = harness.open(URL(string: "https://nonexistent-host.vela-invalid.test/")!)
        await waitForSettled(tab)
        XCTAssertEqual(tab.loadState, .failed)

        harness.tabManager.load(url: url("/one"), in: tab)
        await waitForSettled(tab, expectingTitle: "Page One")

        XCTAssertEqual(tab.loadState, .finished)
        XCTAssertNil(tab.lastFailure)
        XCTAssertEqual(tab.title, "Page One")
    }

    /// `reload` on a tab with no committed document is not a no-op — it is a
    /// fresh request, which is what the error surface's button needs.
    func testReloadAfterAFailureIssuesAFreshRequest() async {
        let tab = harness.open(URL(string: "https://nonexistent-host.vela-invalid.test/")!)
        await waitForSettled(tab)
        let serialBefore = tab.navigationSerial

        XCTAssertTrue(harness.tabManager.reload(tab: tab))
        await waitForSettled(tab)

        XCTAssertGreaterThan(tab.navigationSerial, serialBefore)
        XCTAssertEqual(tab.loadState, .failed, "events: \(harness.trace(for: tab))")
        XCTAssertEqual(tab.lastFailure?.kind, .dns)
    }

    // MARK: - Cancellation

    func testStoppingALoadIsNotAFailure() async {
        let tab = harness.open(url("/slow"))
        // Let the request reach the server before stopping it.
        let started = await waitUntil("the navigation to start") { tab.loadState == .provisional }
        XCTAssertTrue(started)

        harness.tabManager.stopLoading(tab: tab)

        XCTAssertFalse(tab.isLoading)
        XCTAssertNotEqual(tab.loadState, .failed)
        XCTAssertNil(tab.lastFailure)
    }

    /// A second navigation replaces the first, and the first one's cancellation
    /// must not clear the state of the one that replaced it.
    func testASupersededNavigationDoesNotClobberTheNewerOne() async {
        let tab = harness.open(url("/slow"))
        _ = await waitUntil("the slow navigation to start") { tab.loadState == .provisional }

        // Supersede it while it is still in flight.
        harness.tabManager.load(url: url("/one"), in: tab)
        XCTAssertEqual(tab.loadState, .requested)

        await waitForSettled(tab, expectingTitle: "Page One")

        XCTAssertEqual(tab.loadState, .finished)
        XCTAssertEqual(tab.title, "Page One")
        XCTAssertNil(tab.lastFailure)
        XCTAssertFalse(tab.isLoading)
    }

    // MARK: - Links

    /// Following an ordinary link navigates the tab it was clicked in.
    ///
    /// The click is synthesized from script, because a unit test has no finger.
    /// WebKit's user-activation rules decide whether a script-dispatched click on
    /// an anchor counts as a user following a link, and they have moved between
    /// releases — so if this ever stops navigating, the answer is in the trace:
    /// no `start` at all means WebKit declined to treat the synthetic click as a
    /// navigation, while a `start` that does not finish means Vela dropped it.
    func testAFollowedLinkLoadsInTheSameTabAndUpdatesTheUrl() async {
        let tab = harness.open(url("/links"))
        await waitForSettled(tab, expectingTitle: "links")
        XCTAssertEqual(tab.title, "links")

        guard let webView = harness.tabManager.webView(for: tab.id) else {
            return XCTFail("no web view")
        }
        _ = try? await webView.evaluateJavaScript("document.getElementById('same').click()")

        let settled = await waitUntil(
            "the link's page to load: \(harness.trace(for: tab))"
        ) {
            tab.loadState == .finished && tab.title == "Page Two"
        }
        XCTAssertTrue(settled, "events: \(harness.trace(for: tab))")
        XCTAssertEqual(tab.url, url("/two").absoluteString)
        XCTAssertTrue(tab.canGoBack, "the page behind the link should be reachable")
    }

    /// Opening a `target="_blank"` link must not make the page it was clicked on
    /// look like it failed.
    ///
    /// WebKit reports the cancelled navigation as
    /// `WebKitErrorFrameLoadInterruptedByPolicyChange`, which is not
    /// `NSURLErrorCancelled`; the failure path used to classify it as a real
    /// failure and put the *current* tab into the failed state.
    func testOpeningALinkInANewTabLeavesTheCurrentTabAlone() async {
        let tab = harness.open(url("/links"))
        await waitForSettled(tab)

        guard let webView = harness.tabManager.webView(for: tab.id) else {
            return XCTFail("no web view")
        }

        let tabsBefore = harness.tabManager.tabs.count
        _ = try? await webView.evaluateJavaScript("document.getElementById('blank').click()")

        let opened = await waitUntil("a new tab to be created") {
            harness.tabManager.tabs.count == tabsBefore + 1
        }
        XCTAssertTrue(opened)

        let created = harness.tabManager.tabs.first { $0.id != tab.id && !$0.isHome }
        XCTAssertNotNil(created, "the new tab should be pointed at the link")
        guard let created else { return }

        await waitForSettled(created)
        XCTAssertEqual(created.loadState, .finished)
        XCTAssertEqual(created.title, "Page Two")

        // The page the link was clicked on is untouched.
        XCTAssertEqual(tab.loadState, .finished)
        XCTAssertNil(tab.lastFailure)
        XCTAssertEqual(tab.title, "links")
        XCTAssertEqual(tab.url, url("/links").absoluteString)
    }

    /// A mailto: link is handed to the system, and the page it was clicked on is
    /// likewise left alone.
    func testAnExternalSchemeLinkDoesNotFailThePage() async {
        let tab = harness.open(url("/links"))
        await waitForSettled(tab)

        guard let webView = harness.tabManager.webView(for: tab.id) else {
            return XCTFail("no web view")
        }
        // The policy is what runs; the system open is not exercised here.
        _ = try? await webView.evaluateJavaScript("document.getElementById('external').click()")

        let logged = await waitUntil("the external scheme to be handled") {
            harness.navigationLog.entries.contains { $0.event == .externalScheme }
        }
        XCTAssertTrue(logged)

        // Nothing navigated and nothing failed: the page is where it was.
        XCTAssertEqual(tab.loadState, .finished)
        XCTAssertNil(tab.lastFailure)
        XCTAssertEqual(tab.url, url("/links").absoluteString)
    }

    // MARK: - Tabs

    func testTwoTabsKeepTheirOwnState() async {
        let first = harness.open(url("/one"))
        await waitForSettled(first, expectingTitle: "Page One")

        let second = harness.open(url("/two"))
        await waitForSettled(second, expectingTitle: "Page Two")

        XCTAssertEqual(first.title, "Page One")
        XCTAssertEqual(first.url, url("/one").absoluteString)
        XCTAssertEqual(first.loadState, .finished)

        XCTAssertEqual(second.title, "Page Two")
        XCTAssertEqual(second.url, url("/two").absoluteString)
        XCTAssertEqual(second.loadState, .finished)

        XCTAssertNotEqual(first.navigationSerial, second.navigationSerial)
        XCTAssertTrue(harness.tabManager.webView(for: first.id) !== harness.tabManager.webView(for: second.id))
    }

    func testATabOpenedInTheBackgroundIsStillFetched() async {
        let foreground = harness.open(url("/one"))
        await waitForSettled(foreground)

        // The link path: a new tab that is not the one on screen.
        let background = harness.tabManager.openTab(url: url("/two"), activate: false)
        await waitForSettled(background, expectingTitle: "Page Two")

        XCTAssertEqual(background.loadState, .finished)
        XCTAssertEqual(background.title, "Page Two")
        XCTAssertEqual(harness.tabManager.activeTabId, foreground.id)
    }

    func testADiscardedTabIsRefetchedWhenReactivated() async {
        let first = harness.open(url("/one"))
        await waitForSettled(first)
        let second = harness.open(url("/two"))
        await waitForSettled(second)

        harness.tabManager.activateTab(id: first.id)
        harness.tabManager.discardWebView(for: first.id, reason: .memoryPressure)

        XCTAssertNil(harness.tabManager.webView(for: first.id))
        XCTAssertEqual(first.loadState, .idle)
        XCTAssertNil(first.lastFailure)

        // Switching away and back is what reactivates it.
        harness.tabManager.activateTab(id: second.id)
        harness.tabManager.activateTab(id: first.id)

        let reloaded = await waitUntil("the discarded tab to be refetched") {
            first.loadState == .finished && first.title == "Page One"
        }
        XCTAssertTrue(reloaded)
        XCTAssertNotNil(harness.tabManager.webView(for: first.id))
    }

    func testAWebContentProcessCrashIsNotReportedAsANetworkFailure() async {
        let tab = harness.open(url("/one"))
        await waitForSettled(tab)

        // WebKit has no public way to kill a content process, so the delegate
        // callback is delivered the way WebKit would deliver it.
        harness.coordinator.webViewWebContentProcessDidTerminate(
            harness.tabManager.webView(for: tab.id)!
        )
        _ = await waitUntil("the crash to be recorded") { tab.loadState == .crashed }

        XCTAssertEqual(tab.loadState, .crashed)
        XCTAssertEqual(tab.lastFailure?.kind, .crashed)
        XCTAssertFalse(tab.isLoading)
        // A crash is not retryable by re-displaying the same document; the page
        // has to be fetched again, which is what the error surface offers.
        XCTAssertEqual(tab.lastFailure?.isRetryable, false)
    }

    // MARK: - Ad blocking

    func testTheShippedRulesDoNotPreventAPageFromLoading() async {
        let installed = await harness.installShippedAdBlockRules()
        XCTAssertTrue(installed, "the shipped rules did not install: \(harness.adBlockCompileError ?? "no error reported")")

        let tab = harness.open(url("/ads"))
        await waitForSettled(tab, expectingTitle: "ads")

        XCTAssertEqual(tab.loadState, .finished)
        XCTAssertEqual(tab.title, "ads")
        XCTAssertNil(tab.lastFailure)
    }

    func testTheCosmeticRulesHideTheAdSlotAndNotTheContent() async {
        let installed = await harness.installShippedAdBlockRules()
        XCTAssertTrue(installed, "the shipped rules did not install: \(harness.adBlockCompileError ?? "no error reported")")

        let tab = harness.open(url("/ads"))
        await waitForSettled(tab)

        guard let webView = harness.tabManager.webView(for: tab.id) else {
            return XCTFail("no web view")
        }
        // The cosmetic style is injected at document start and applies
        // immediately, so no waiting on the counting script.
        let stylePresent = try? await webView.evaluateJavaScript(
            "!!document.getElementById('\(AdBlockEngine.cosmeticStyleIdentifier)')"
        )
        let slotDisplay = try? await webView.evaluateJavaScript(
            "getComputedStyle(document.getElementById('slot')).display"
        )
        let contentDisplay = try? await webView.evaluateJavaScript(
            "getComputedStyle(document.getElementById('content')).display"
        )
        let bodyLength = try? await webView.evaluateJavaScript("document.body.innerHTML.length")

        XCTAssertEqual(
            stylePresent as? Bool,
            true,
            "the cosmetic stylesheet was never injected, so nothing could be hidden"
        )
        XCTAssertEqual(slotDisplay as? String, "none")
        XCTAssertNotEqual(contentDisplay as? String, "none")
        XCTAssertGreaterThan((bodyLength as? Int) ?? 0, 0)
    }

    /// With the rule list switched off the same slot is visible, which is what
    /// makes the previous test's assertion about Vela rather than about CSS.
    func testWithAdBlockingDisabledTheAdSlotIsVisible() async {
        await harness.installShippedAdBlockRules(enabled: false)

        let tab = harness.open(url("/ads"))
        await waitForSettled(tab)

        guard let webView = harness.tabManager.webView(for: tab.id) else {
            return XCTFail("no web view")
        }
        let slotDisplay = try? await webView.evaluateJavaScript(
            "getComputedStyle(document.getElementById('slot')).display"
        )
        XCTAssertNotEqual(slotDisplay as? String, "none")
        XCTAssertEqual(tab.loadState, .finished)
    }

    /// A page-initiated navigation that WebKit abandons must not cost the user
    /// the page that is displayed.
    ///
    /// This is the case a real log showed on a Bing results page: the results
    /// load and finish, then the page fires a click-tracking beacon as a
    /// main-frame navigation, and WebKit reports it interrupted by a policy
    /// change. The tab's state became `cancelled` while the results were still on
    /// screen — and because a cancelled tab is treated as one whose page was
    /// never shown, switching away and back re-fetched it, reloading the results
    /// and losing the user's place.
    func testACancelledSecondaryNavigationDoesNotCostTheDisplayedPage() async {
        let tab = harness.open(url("/one"))
        await waitForSettled(tab, expectingTitle: "Page One")
        let requestsAfterLoad = server.requestCount(for: "/one")

        // A navigation the page starts and does not finish — the shape of a
        // beacon — stopped while it is in flight.
        harness.tabManager.load(url: url("/slow"), in: tab)
        _ = await waitUntil("the beacon navigation to start") { tab.loadState == .provisional }
        harness.tabManager.stopLoading(tab: tab)
        _ = await waitUntil("the beacon navigation to be cancelled") { tab.loadState == .cancelled }

        // The page it was fired from is still the one on screen.
        XCTAssertEqual(
            tab.committedUrl,
            url("/one").absoluteString,
            "the tab should still be showing the page the beacon was fired from"
        )

        // Leaving and coming back must not re-fetch it.
        let other = harness.tabManager.openTab(url: url("/two"))
        await waitForSettled(other, expectingTitle: "Page Two")
        harness.tabManager.activateTab(id: tab.id)

        XCTAssertEqual(
            server.requestCount(for: "/one"),
            requestsAfterLoad,
            "the displayed page was fetched again because a beacon was cancelled: "
                + harness.trace(for: tab)
        )
    }

    /// The other half of the same rule: a tab whose *only* navigation was stopped
    /// has no document, and activating it does fetch again — the alternative is a
    /// tab that shows a blank rectangle for the rest of the session.
    func testATabWhoseOnlyNavigationWasStoppedIsFetchedAgain() async {
        let tab = harness.open(url("/slow"))
        _ = await waitUntil("the navigation to start") { tab.loadState == .provisional }
        harness.tabManager.stopLoading(tab: tab)
        _ = await waitUntil("the navigation to be cancelled") { tab.loadState == .cancelled }

        guard let webView = harness.tabManager.webView(for: tab.id) else {
            return XCTFail("no web view")
        }
        // Nothing committed — which is not the same as `webView.url` being nil:
        // WebKit reports the navigation in flight there, so it names the page
        // that was never shown. That distinction is the reason `committedUrl`
        // exists.
        XCTAssertTrue(tab.committedUrl.isEmpty, "nothing should have committed")
        XCTAssertEqual(webView.url?.absoluteString, url("/slow").absoluteString)

        let other = harness.tabManager.openTab(url: url("/one"))
        await waitForSettled(other, expectingTitle: "Page One")

        let before = server.requestCount(for: "/slow")
        harness.tabManager.activateTab(id: tab.id)

        let refetched = await waitUntil("the stopped tab to be fetched again") {
            server.requestCount(for: "/slow") > before
        }
        XCTAssertTrue(refetched, "events: \(harness.trace(for: tab))")
    }

    // MARK: - The identifier presented to sites

    /// The identifier presented is Safari's on this device, and its prefix is
    /// WebKit's own.
    ///
    /// Three properties, each of which was wrong before:
    ///
    /// * The version is the device's, not a number written down when the string
    ///   was authored. The app hardcoded `Version/17.0`, so on a later iOS every
    ///   site was told the browser was Safari 17 and the ones that check answered
    ///   「浏览器版本太低」.
    /// * The identifier carries `Version/` and `Safari/`. A bare `WKWebView` sends
    ///   neither — they are tokens Safari adds for itself — and a site that looks
    ///   for them treats their absence as an embedded browser, which is the other
    ///   way a site tells the user to go and open Safari.
    /// * Its *prefix* is byte-identical to what WebKit builds unaided: the
    ///   platform token and the engine's version token are the running system's,
    ///   not this project's. That is what makes the identifier survive an OS
    ///   release — the check against a throwaway web view is the whole point, and
    ///   it is what a hardcoded `AppleWebKit/605.1.15` would fail.
    func testTheIdentifierIsSafarisOnThisDevice() async {
        let tab = harness.open(url("/one"))
        await waitForSettled(tab, expectingTitle: "Page One")

        guard let webView = harness.tabManager.webView(for: tab.id) else {
            return XCTFail("no web view")
        }
        // The default sets no override at all: WebKit assembles the identifier
        // and Vela only supplies the tail. Read back leniently — assigning nil
        // to `customUserAgent` reads back as the empty string, not as nil, which
        // is a WebKit detail rather than a property of this code.
        XCTAssertTrue(
            (webView.customUserAgent ?? "").isEmpty,
            "the default should set no override: \(webView.customUserAgent ?? "-")"
        )

        let value = try? await webView.evaluateJavaScript("navigator.userAgent")
        let identifier = value as? String ?? ""
        let major = ProcessInfo.processInfo.operatingSystemVersion.majorVersion

        XCTAssertTrue(identifier.contains("Safari/"), identifier)
        XCTAssertTrue(identifier.contains("Version/\(major)."), identifier)
        XCTAssertFalse(identifier.contains("Version/17.0"), identifier)

        // What WebKit sends when nothing is appended...
        let reference = WKWebView(frame: .zero, configuration: WKWebViewConfiguration())
        let referenceValue = try? await reference.evaluateJavaScript("navigator.userAgent")
        let referenceIdentifier = referenceValue as? String ?? ""
        guard let marker = referenceIdentifier.range(of: "(KHTML, like Gecko) ") else {
            return XCTFail("unexpected reference identifier: \(referenceIdentifier)")
        }
        // ...must be the prefix of what a tab sends. Everything up to and
        // including the marker is WebKit's, so if this project ever writes down a
        // platform or engine token, this is where it shows.
        let webKitPrefix = String(referenceIdentifier[referenceIdentifier.startIndex..<marker.upperBound])
        XCTAssertTrue(identifier.hasPrefix(webKitPrefix), identifier)
    }

    func testDesktopModePresentsADesktopIdentifierToThePage() async {
        harness.settings.update { $0.desktopSiteByDefault = true }

        let tab = harness.open(url("/one"))
        await waitForSettled(tab, expectingTitle: "Page One")

        guard let webView = harness.tabManager.webView(for: tab.id) else {
            return XCTFail("no web view")
        }
        XCTAssertEqual(webView.customUserAgent?.contains("Macintosh"), true)

        let value = try? await webView.evaluateJavaScript("navigator.userAgent")
        let identifier = value as? String ?? ""
        XCTAssertTrue(identifier.contains("Macintosh"), identifier)
        XCTAssertFalse(identifier.contains("Mobile/"), identifier)
    }

    /// The desktop toggle round-trips: on, off, and back to a phone identifier.
    ///
    /// The "off" direction is the one worth testing, because it works by
    /// assigning nil — and a cleared override that does not actually restore the
    /// default would leave the user stuck claiming to be a Mac with no way back
    /// except deleting the app's settings.
    func testTurningDesktopModeOffRestoresThePhoneIdentifier() async {
        harness.settings.update { $0.desktopSiteByDefault = true }
        let tab = harness.open(url("/one"))
        await waitForSettled(tab, expectingTitle: "Page One")

        guard let webView = harness.tabManager.webView(for: tab.id) else {
            return XCTFail("no web view")
        }
        var value = try? await webView.evaluateJavaScript("navigator.userAgent")
        XCTAssertTrue((value as? String ?? "").contains("Macintosh"), value as? String ?? "")

        // What the settings screen's toggle does.
        harness.settings.update { $0.desktopSiteByDefault = false }
        harness.tabManager.applyUserAgentToAllWebViews()
        _ = harness.tabManager.reload(tab: tab)
        await waitForSettled(tab, expectingTitle: "Page One")

        value = try? await webView.evaluateJavaScript("navigator.userAgent")
        let identifier = value as? String ?? ""
        XCTAssertFalse(identifier.contains("Macintosh"), identifier)
        XCTAssertTrue(identifier.contains("iPhone"), identifier)
        XCTAssertTrue(identifier.contains("Safari/"), identifier)
    }

    // MARK: - Privacy

    func testAPrivateTabLoadsToo() async {
        let tab = harness.tabManager.openTab(url: url("/one"), privacyMode: .private)
        await waitForSettled(tab, expectingTitle: "Page One")

        XCTAssertEqual(tab.loadState, .finished)
        XCTAssertEqual(tab.title, "Page One")
    }
}
