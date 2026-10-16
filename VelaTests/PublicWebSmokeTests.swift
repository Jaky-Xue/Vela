//
//  PublicWebSmokeTests.swift
//  VelaTests
//
//  The half of the evidence the local server cannot give: real HTTPS, real DNS,
//  real certificates, real redirects, on the open internet.
//
//  These tests are slower and less reliable than the rest of the suite by
//  construction — they depend on somebody else's servers — so they are written to
//  report *what happened* rather than to assert a page's content, and they keep
//  the number of third parties small. A failure here is information about the
//  network, not necessarily about Vela; a pass is proof that the whole chain
//  works against a real site.
//
//  The list is deliberately short and long-lived: a site that changes its
//  front-end would fail a content assertion and tell us nothing.
//

import XCTest
@testable import Vela

@MainActor
final class PublicWebSmokeTests: XCTestCase {
    private var harness: BrowserHarness!

    /// Sites to smoke-test. Every one is an HTTPS homepage that does not require
    /// authentication and is unlikely to disappear.
    private static let sites = [
        "https://www.example.com/",
        "https://www.wikipedia.org/",
        "https://duckduckgo.com/"
    ]

    override func setUp() async throws {
        try await super.setUp()
        harness = try BrowserHarness()
        // The shipped rules are installed, because a smoke test run with ad
        // blocking off would not exercise what users run. Whether they compiled
        // is asserted by the ad-block suites; this one is about the network.
        _ = await harness.installShippedAdBlockRules()
    }

    override func tearDown() async throws {
        harness = nil
        try await super.tearDown()
    }

    /// Every site opens, and the tab ends up describing the page it actually got.
    func testPublicHttpsSitesLoad() async {
        var results: [String] = []

        for site in Self.sites {
            guard let url = URL(string: site) else { continue }
            let tab = harness.open(url)

            _ = await waitUntil("\(site) to settle", timeout: 30) {
                !tab.loadState.isInFlight && !tab.isLoading
            }

            let outcome = "\(site) → state=\(tab.loadState.rawValue) "
                + "status=\(tab.serverStatus) title=\"\(tab.title)\" "
                + "url=\(tab.url) error=\(tab.lastFailure?.title ?? "none")"
            results.append(outcome)

            XCTAssertEqual(
                tab.loadState,
                .finished,
                "\(site) did not finish. \(outcome)"
            )
            XCTAssertNil(tab.lastFailure, outcome)
            XCTAssertFalse(tab.isLoading, outcome)
            XCTAssertFalse(tab.title.isEmpty, "no title was reported for \(site). \(outcome)")
            XCTAssertNotNil(URL(string: tab.url)?.host, "no host in the final URL. \(outcome)")
        }

        // Printed rather than asserted on: the record of what the run actually
        // saw, which is what a smoke test is for.
        print("=== public web smoke test ===")
        for result in results { print(result) }
    }

    /// A search goes to the configured engine and produces a results page.
    func testASearchReachesTheConfiguredEngine() async {
        let engine = harness.settings.preferences.searchEngine.activeEngine
        guard let url = engine.searchUrl(for: "vela browser") else {
            return XCTFail("the active engine could not build a search URL")
        }

        let tab = harness.open(url)
        _ = await waitUntil("the search results to settle", timeout: 30) {
            !tab.loadState.isInFlight && !tab.isLoading
        }

        print("=== search smoke test: \(engine.name) → \(tab.url) status=\(tab.serverStatus) " +
              "state=\(tab.loadState.rawValue) title=\"\(tab.title)\"")

        // The engine's own page is rendered — including its own error page, which
        // is a successful navigation to a page that says something went wrong.
        XCTAssertEqual(tab.loadState, .finished)
        XCTAssertNil(tab.lastFailure)
        XCTAssertNotNil(URL(string: tab.url)?.host)
    }

    /// A real DNS failure on a domain reserved never to resolve.
    func testAnUnresolvableDomainFailsCleanly() async {
        let tab = harness.open(URL(string: "https://nonexistent-host.vela-invalid.test/")!)
        _ = await waitUntil("the failure to settle", timeout: 30) {
            !tab.loadState.isInFlight && !tab.isLoading
        }

        XCTAssertEqual(tab.loadState, .failed)
        XCTAssertEqual(tab.lastFailure?.kind, .dns)
        XCTAssertFalse(tab.isLoading)
    }

    /// A cleartext page opens.
    ///
    /// This is the test for the web-content App Transport Security exemption.
    /// Without it the navigation fails with
    /// `NSURLErrorAppTransportSecurityRequiresSecureConnection` before a packet
    /// is sent — so a browser that accepted the address in the address bar then
    /// refused to open it, which is one of the ways "the browser cannot open
    /// pages" presented itself. `example.com` serves both schemes.
    func testACleartextHttpPageOpens() async throws {
        guard let url = URL(string: "http://example.com/") else { return XCTFail("bad test URL") }
        let tab = harness.open(url)

        let settled = await waitUntil("the cleartext page to settle", timeout: 30) {
            !tab.loadState.isInFlight && !tab.isLoading
        }

        print("=== cleartext smoke test: http://example.com/ → state=\(tab.loadState.rawValue) " +
              "status=\(tab.serverStatus) error=\(tab.lastFailure?.title ?? "none")")

        // A refusal by the platform arrives as a failure callback within
        // milliseconds, and that is what this test is for.
        if tab.loadState == .failed {
            XCTFail("App Transport Security blocked web content: \(harness.trace(for: tab))")
        }
        // No callback at all is a different thing, and not something about Vela:
        // it means the runner's egress never answered a cleartext request. Skipped
        // rather than passed, so it cannot be mistaken for a passing exemption —
        // and it is reported with the reason.
        guard settled else {
            throw XCTSkip("the runner never answered a cleartext request: \(harness.trace(for: tab))")
        }

        XCTAssertEqual(tab.loadState, .finished)
        XCTAssertNil(tab.lastFailure)
        XCTAssertEqual(tab.serverStatus, 200)
    }
}
