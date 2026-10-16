//
//  AddressBarTests.swift
//  VelaTests
//
//  What the address bar decides: whether typed text is a URL or a query, the
//  identity a tab presents, and the URL normalisation that history hashing
//  depends on.
//
//  All three are pure functions with no web view involved, which makes them the
//  cheapest thing in the app to verify and the most expensive to get wrong — a
//  resolver that sends a host to a search engine, or a normaliser that keeps a
//  fragment, is a bug users hit on the first page they type.
//

import XCTest
@testable import Vela

final class BrowserUrlResolverTests: XCTestCase {
    // MARK: - Bare hosts

    func testABareHostGetsHttpsAssumed() {
        XCTAssertEqual(
            BrowserUrlResolver.resolveDirectUrl("example.com")?.absoluteString,
            "https://example.com"
        )
    }

    func testAHostWithAPathKeepsThePath() {
        XCTAssertEqual(
            BrowserUrlResolver.resolveDirectUrl("example.com/a/b?c=1")?.absoluteString,
            "https://example.com/a/b?c=1"
        )
    }

    func testATrailingSlashOnABareHostIsDroppedBeforeTheChecks() {
        XCTAssertEqual(
            BrowserUrlResolver.resolveDirectUrl("example.com/")?.absoluteString,
            "https://example.com"
        )
    }

    func testASubdomainIsAHost() {
        XCTAssertEqual(
            BrowserUrlResolver.resolveDirectUrl("news.ycombinator.com")?.absoluteString,
            "https://news.ycombinator.com"
        )
    }

    // MARK: - Explicit schemes

    func testAnExplicitLoadableSchemeIsKept() {
        XCTAssertEqual(
            BrowserUrlResolver.resolveDirectUrl("http://example.com/x")?.absoluteString,
            "http://example.com/x"
        )
        XCTAssertNotNil(BrowserUrlResolver.resolveDirectUrl("file:///tmp/notes.txt"))
    }

    func testAnExternalSchemeResolvesSoItCanBeHandedToTheSystem() {
        XCTAssertNotNil(BrowserUrlResolver.resolveDirectUrl("mailto:someone@example.com"))
        XCTAssertNotNil(BrowserUrlResolver.resolveDirectUrl("weixin://dl/scan"))
    }

    func testAboutAndDataHaveNoAuthority() {
        XCTAssertNotNil(BrowserUrlResolver.resolveDirectUrl("about:blank"))
        XCTAssertNotNil(BrowserUrlResolver.resolveDirectUrl("data:text/plain,hello"))
    }

    // MARK: - Localhost and IP literals

    func testLocalhostKeepsItsPortAndUsesHttp() {
        XCTAssertEqual(
            BrowserUrlResolver.resolveDirectUrl("localhost:8080")?.absoluteString,
            "http://localhost:8080"
        )
    }

    func testAnIPv4LiteralUsesHttp() {
        XCTAssertEqual(
            BrowserUrlResolver.resolveDirectUrl("192.168.1.1:3000")?.absoluteString,
            "http://192.168.1.1:3000"
        )
    }

    func testAnIPv4LiteralOutOfRangeIsNotAHost() {
        XCTAssertNil(BrowserUrlResolver.resolveDirectUrl("999.1.1.1"))
    }

    // MARK: - Queries

    func testASingleWordIsAQuery() {
        XCTAssertNil(BrowserUrlResolver.resolveDirectUrl("swift"))
        XCTAssertTrue(BrowserUrlResolver.isSearchQuery("swift"))
    }

    func testAnythingWithASpaceIsAQuery() {
        XCTAssertNil(BrowserUrlResolver.resolveDirectUrl("swift concurrency"))
        XCTAssertTrue(BrowserUrlResolver.isSearchQuery("how tall is everest"))
    }

    func testANumericTldIsAVersionNumberNotADomain() {
        XCTAssertNil(BrowserUrlResolver.resolveDirectUrl("1.2.3"))
        XCTAssertNil(BrowserUrlResolver.resolveDirectUrl("swift 5.9"))
    }

    func testALeadingOrTrailingDotIsATypoNotAHost() {
        XCTAssertNil(BrowserUrlResolver.resolveDirectUrl(".example.com"))
        XCTAssertNil(BrowserUrlResolver.resolveDirectUrl("example.com."))
    }

    func testASingleLetterTldIsAQuery() {
        XCTAssertNil(BrowserUrlResolver.resolveDirectUrl("a.b"))
    }

    func testEmptyInputResolvesToNothing() {
        XCTAssertNil(BrowserUrlResolver.resolveDirectUrl(""))
        XCTAssertNil(BrowserUrlResolver.resolveDirectUrl("   "))
        XCTAssertNil(BrowserUrlResolver.resolveNavigation(input: "  ", searchEngine: Self.engine))
    }

    // MARK: - Navigation

    private static let engine = SearchEngineRecord(
        id: "test-engine",
        kind: .builtIn,
        name: "测试",
        searchUrlTemplate: "https://search.example/?q={searchTerms}",
        homepageUrl: "",
        isEditable: false,
        position: 0
    )

    func testAQueryGoesToTheSearchEngine() {
        let url = BrowserUrlResolver.resolveNavigation(input: "swift concurrency", searchEngine: Self.engine)
        XCTAssertEqual(url?.absoluteString, "https://search.example/?q=swift%20concurrency")
    }

    func testAUrlIsNotSentToTheSearchEngine() {
        let url = BrowserUrlResolver.resolveNavigation(input: "example.com", searchEngine: Self.engine)
        XCTAssertEqual(url?.absoluteString, "https://example.com")
    }

    func testSurroundingWhitespaceIsIgnored() {
        let url = BrowserUrlResolver.resolveNavigation(input: "  example.com  ", searchEngine: Self.engine)
        XCTAssertEqual(url?.absoluteString, "https://example.com")
    }
}

// MARK: - User agent

final class BrowserUserAgentTests: XCTestCase {
    func testTheDesktopStringIsUsedWhenAskedFor() {
        let agent = BrowserUserAgent.resolve(custom: "", prefersDesktop: true)
        XCTAssertEqual(agent, BrowserUserAgent.defaultUserAgent)
        XCTAssertTrue(agent.contains("Macintosh"))
    }

    func testTheMobileStringIsTheDefault() {
        let agent = BrowserUserAgent.resolve(custom: "", prefersDesktop: false)
        XCTAssertTrue(agent.contains("iPhone"))
    }

    func testACustomStringWinsOverTheToggle() {
        // Someone who typed one asked for that exact value; letting the desktop
        // toggle override it is what made the field look broken.
        XCTAssertEqual(
            BrowserUserAgent.resolve(custom: "MyAgent/9", prefersDesktop: true),
            "MyAgent/9"
        )
    }

    func testAWhitespaceOnlyCustomStringIsNotACustomString() {
        XCTAssertEqual(
            BrowserUserAgent.resolve(custom: "   \n ", prefersDesktop: true),
            BrowserUserAgent.defaultUserAgent
        )
    }

    func testTheCustomStringIsTrimmed() {
        XCTAssertEqual(
            BrowserUserAgent.resolve(custom: "  MyAgent/9  ", prefersDesktop: false),
            "MyAgent/9"
        )
    }
}

// MARK: - History normalisation

final class HistoryUrlNormalizerTests: XCTestCase {
    func testSchemeAndHostAreLowercasedAndThePathIsNot() {
        XCTAssertEqual(
            HistoryUrlNormalizer.normalize("HTTPS://Example.COM/Path"),
            "https://example.com/Path"
        )
    }

    func testABareRootLosesItsTrailingSlash() {
        XCTAssertEqual(
            HistoryUrlNormalizer.normalize("https://example.com/"),
            "https://example.com"
        )
    }

    func testTheFragmentIsDroppedSoASectionIsNotASecondRow() {
        XCTAssertEqual(
            HistoryUrlNormalizer.normalize("https://example.com/page#section"),
            "https://example.com/page"
        )
    }

    func testTheQueryIsKept() {
        XCTAssertEqual(
            HistoryUrlNormalizer.normalize("https://example.com/s?q=a&p=2"),
            "https://example.com/s?q=a&p=2"
        )
    }

    func testADefaultPortIsDropped() {
        XCTAssertEqual(
            HistoryUrlNormalizer.normalize("https://example.com:443/x"),
            "https://example.com/x"
        )
        XCTAssertEqual(
            HistoryUrlNormalizer.normalize("http://example.com:80/x"),
            "http://example.com/x"
        )
    }

    func testANonDefaultPortIsKept() {
        XCTAssertEqual(
            HistoryUrlNormalizer.normalize("https://example.com:8443/x"),
            "https://example.com:8443/x"
        )
    }

    func testCredentialsAreStripped() {
        XCTAssertEqual(
            HistoryUrlNormalizer.normalize("https://user:secret@example.com/x"),
            "https://example.com/x"
        )
    }

    func testOnlyHttpAndHttpsAreHistory() {
        XCTAssertNil(HistoryUrlNormalizer.normalize("vela://newtab"))
        XCTAssertNil(HistoryUrlNormalizer.normalize("file:///tmp/notes.txt"))
        XCTAssertNil(HistoryUrlNormalizer.normalize("about:blank"))
    }

    func testNormalisationIsStable() {
        // The normalised form is hashed to enforce one row per URL, so running
        // it twice has to produce the same string.
        let once = HistoryUrlNormalizer.normalize("HTTPS://Example.COM/a/../b/?q=1#frag")
        let twice = once.flatMap { HistoryUrlNormalizer.normalize($0) }
        XCTAssertNotNil(once)
        XCTAssertEqual(once, twice)
    }

    func testTheHashIsStableWithinAProcess() {
        XCTAssertEqual(
            HistoryUrlNormalizer.hash("https://example.com"),
            HistoryUrlNormalizer.hash("https://example.com")
        )
        XCTAssertNotEqual(
            HistoryUrlNormalizer.hash("https://example.com"),
            HistoryUrlNormalizer.hash("https://example.org")
        )
    }

    func testTheOriginDropsThePathAndKeepsANonDefaultPort() {
        XCTAssertEqual(
            HistoryUrlNormalizer.origin(of: URL(string: "https://example.com/a/b")!),
            "https://example.com"
        )
        XCTAssertEqual(
            HistoryUrlNormalizer.origin(of: URL(string: "http://localhost:8080/x")!),
            "http://localhost:8080"
        )
    }

    func testATransitionOnlyCountsAsIntentWhenItWasTyped() {
        XCTAssertTrue(HistoryTransition.typed.countsAsIntent)
        XCTAssertTrue(HistoryTransition.keyword.countsAsIntent)
        // A link click is a visit, but not evidence that the user meant to come
        // here, which is what the ranking reads.
        XCTAssertFalse(HistoryTransition.link.countsAsIntent)
        XCTAssertFalse(HistoryTransition.reload.countsAsIntent)
    }
}
