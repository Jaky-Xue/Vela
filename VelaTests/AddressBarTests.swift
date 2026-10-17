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
        XCTAssertEqual(
            BrowserUrlResolver.resolveDirectUrl("https://example.com:8443/x")?.absoluteString,
            "https://example.com:8443/x"
        )
    }

    /// The address bar refuses the schemes that cannot lead anywhere useful or
    /// that can be used to disguise content.
    ///
    /// `file:` resolves only inside the app's own container, and `data:` renders
    /// markup the user did not type under a URL that appears to have been typed.
    /// Both are still loadable when a *page* asks for them; this is about what
    /// typing one does.
    func testSchemesTheAddressBarRefuses() {
        for input in [
            "file:///tmp/notes.txt",
            "data:text/html,<script>alert(1)</script>",
            "data:text/plain,hello",
            "javascript:alert(1)",
            "about:config",
            "blob:https://example.com/abc",
            "ftp://ftp.example.com/pub"
        ] {
            XCTAssertNil(BrowserUrlResolver.resolveDirectUrl(input), "should refuse \(input)")
        }
    }

    func testAboutBlankIsTheOneAboutUrlThatIsAccepted() {
        XCTAssertEqual(
            BrowserUrlResolver.resolveDirectUrl("about:blank")?.absoluteString,
            "about:blank"
        )
    }

    func testAnExternalSchemeResolvesSoItCanBeHandedToTheSystem() {
        XCTAssertNotNil(BrowserUrlResolver.resolveDirectUrl("mailto:someone@example.com"))
        XCTAssertNotNil(BrowserUrlResolver.resolveDirectUrl("weixin://dl/scan"))
    }

    func testARefusedSchemeIsReportedRatherThanSearchedFor() {
        // Silently searching for `file:///x` tells the user nothing about why the
        // address they pasted did not open.
        XCTAssertEqual(
            BrowserUrlResolver.resolve(input: "file:///tmp/notes.txt", searchEngine: Self.engine),
            .rejected(.unsupportedScheme("file"))
        )
        XCTAssertEqual(
            BrowserUrlResolver.resolve(input: "javascript:alert(1)", searchEngine: Self.engine),
            .rejected(.unsupportedScheme("javascript"))
        )
    }

    func testAnExternalSchemeResolvesAsAHandoffNotANavigation() {
        let resolution = BrowserUrlResolver.resolve(
            input: "mailto:someone@example.com",
            searchEngine: Self.engine
        )
        guard case let .handOff(url) = resolution else {
            return XCTFail("expected a handoff, got \(resolution)")
        }
        XCTAssertEqual(url.scheme, "mailto")
    }

    // MARK: - Host validation

    /// `URL(string:)` returns an object for these, and none of them can be
    /// loaded. A host is the one thing an `http(s)` URL cannot do without.
    func testAnHttpUrlWithNoHostIsNotAccepted() {
        XCTAssertNil(BrowserUrlResolver.resolveDirectUrl("https://"))
        XCTAssertNil(BrowserUrlResolver.resolveDirectUrl("https:///path"))
        XCTAssertNil(BrowserUrlResolver.resolveDirectUrl("http://"))
    }

    // MARK: - Localhost and IP literals

    func testLocalhostKeepsItsPortAndUsesHttp() {
        XCTAssertEqual(
            BrowserUrlResolver.resolveDirectUrl("localhost:8080")?.absoluteString,
            "http://localhost:8080"
        )
        XCTAssertEqual(
            BrowserUrlResolver.resolveDirectUrl("localhost:8080/dev")?.absoluteString,
            "http://localhost:8080/dev"
        )
    }

    func testAnIPv4LiteralUsesHttp() {
        XCTAssertEqual(
            BrowserUrlResolver.resolveDirectUrl("192.168.1.1:3000")?.absoluteString,
            "http://192.168.1.1:3000"
        )
        XCTAssertEqual(
            BrowserUrlResolver.resolveDirectUrl("127.0.0.1")?.absoluteString,
            "http://127.0.0.1"
        )
    }

    func testAnIPv4LiteralOutOfRangeIsNotAHost() {
        XCTAssertNil(BrowserUrlResolver.resolveDirectUrl("999.1.1.1"))
        XCTAssertNil(BrowserUrlResolver.resolveDirectUrl("192.168.1.999"))
    }

    func testAnIPv6LiteralInBracketsUsesHttp() {
        XCTAssertEqual(
            BrowserUrlResolver.resolveDirectUrl("[::1]:8080")?.absoluteString,
            "http://[::1]:8080"
        )
    }

    // MARK: - Internationalised hosts

    func testAChineseDomainIsAHostRatherThanAQuery() {
        let url = BrowserUrlResolver.resolveDirectUrl("中文.com")
        XCTAssertNotNil(url, "中文.com should resolve to a URL, not a search")
        XCTAssertEqual(url?.host?.isEmpty, false)
        XCTAssertEqual(url?.scheme, "https")
    }

    func testAChineseDomainWithAPathAndQueryKeepsBoth() {
        let url = BrowserUrlResolver.resolveDirectUrl("https://中文.com/路径?q=测试")
        XCTAssertNotNil(url)
        XCTAssertEqual(url?.scheme, "https")
        XCTAssertEqual(url?.path, "/路径")
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

    func testEmptyInputIsRejectedWithAReason() {
        XCTAssertNil(BrowserUrlResolver.resolveDirectUrl(""))
        XCTAssertNil(BrowserUrlResolver.resolveDirectUrl("   "))
        XCTAssertEqual(
            BrowserUrlResolver.resolve(input: "  ", searchEngine: Self.engine),
            .rejected(.empty)
        )
    }

    // MARK: - Search-URL generation

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
        XCTAssertEqual(
            BrowserUrlResolver.resolve(input: "swift concurrency", searchEngine: Self.engine),
            .search(URL(string: "https://search.example/?q=swift%20concurrency")!)
        )
    }

    func testAUrlIsNotSentToTheSearchEngine() {
        let url = BrowserUrlResolver.resolveNavigation(input: "example.com", searchEngine: Self.engine)
        XCTAssertEqual(url?.absoluteString, "https://example.com")
    }

    func testSurroundingWhitespaceIsIgnored() {
        let url = BrowserUrlResolver.resolveNavigation(input: "  example.com  ", searchEngine: Self.engine)
        XCTAssertEqual(url?.absoluteString, "https://example.com")
    }

    /// A term is encoded exactly once.
    ///
    /// The characters that terminate a query parameter or introduce a new one are
    /// encoded, so a search for `a&b=c` cannot smuggle a second parameter into the
    /// engine's own URL. `%` is encoded too: leaving it alone would make the
    /// substitution non-idempotent and send `100%` as something else entirely.
    func testSearchTermsAreEncodedExactlyOnce() {
        XCTAssertEqual(
            Self.engine.searchUrl(for: "a&b=c")?.absoluteString,
            "https://search.example/?q=a%26b%3Dc"
        )
        XCTAssertEqual(
            Self.engine.searchUrl(for: "100%")?.absoluteString,
            "https://search.example/?q=100%25"
        )
        XCTAssertEqual(
            Self.engine.searchUrl(for: "a?b#c")?.absoluteString,
            "https://search.example/?q=a%3Fb%23c"
        )
        XCTAssertEqual(
            Self.engine.searchUrl(for: "a+b")?.absoluteString,
            "https://search.example/?q=a%2Bb"
        )
    }

    func testAChineseSearchTermIsPercentEncodedAsUtf8() {
        XCTAssertEqual(
            Self.engine.searchUrl(for: "中文")?.absoluteString,
            "https://search.example/?q=%E4%B8%AD%E6%96%87"
        )
    }

    /// The term survives a round trip through the generated URL, which is the
    /// property that matters: whatever the user typed is what the engine is
    /// asked for.
    func testASearchTermRoundTripsThroughTheGeneratedUrl() {
        for term in ["swift concurrency", "中文 搜索", "a&b=c", "100%", "c++", "emoji 🎉", "a/b"] {
            guard let url = Self.engine.searchUrl(for: term),
                  let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
                  let value = components.queryItems?.first(where: { $0.name == "q" })?.value else {
                return XCTFail("no q parameter for \(term)")
            }
            XCTAssertEqual(value, term, "round trip failed for \(term)")
        }
    }

    func testAnEngineWithNoPlaceholderCannotExpressAQuery() {
        let broken = SearchEngineRecord(
            id: "broken",
            kind: .custom,
            name: "Broken",
            searchUrlTemplate: "https://search.example/",
            homepageUrl: "",
            isEditable: true,
            position: 0
        )
        XCTAssertNil(broken.searchUrl(for: "anything"))
        XCTAssertEqual(
            BrowserUrlResolver.resolve(input: "anything", searchEngine: broken),
            .rejected(.noUsableSearchEngine)
        )
    }
}

// MARK: - User agent

/// The identifier a tab presents.
///
/// Two properties matter and both were wrong before. The version has to come from
/// the running system rather than from a number written down when the string was
/// authored: the app hardcoded `Version/17.0`, so on a later iOS every site was
/// told the browser was Safari 17 and the ones that check answered
/// 「浏览器版本太低」. And the string has to be Safari-shaped: a bare `WKWebView`
/// sends neither `Version/` nor `Safari/`, and a site that looks for them treats
/// their absence as an embedded browser.
///
/// The third property is the one that makes the first survive an OS release: the
/// default identity sets *no* custom identifier, so WebKit builds the whole string
/// from its own platform and engine tokens and Vela only appends the Safari tail.
/// Nothing here has to be revised for iOS 27.
@MainActor
final class BrowserUserAgentTests: XCTestCase {
    /// What Vela adds, and the only part of the identifier it writes at all.
    func testTheTailIsTheSafariPartAndReportsTheRunningSystem() {
        let tail = BrowserUserAgent.safariTail
        let version = ProcessInfo.processInfo.operatingSystemVersion
        XCTAssertTrue(tail.hasPrefix("Version/\(version.majorVersion).\(version.minorVersion)"), tail)
        XCTAssertTrue(tail.contains("Mobile/"), tail)
        XCTAssertTrue(tail.contains("Safari/"), tail)
        XCTAssertFalse(tail.contains("Version/17.0"))
    }

    /// The default leaves the whole prefix to WebKit.
    ///
    /// This is the property that adapts to a new OS by itself: Vela does not name
    /// the platform, and it does not name the engine's version token either —
    /// writing that down is the same mistake as writing down `Version/17.0`, one
    /// layer down.
    func testTheDefaultIdentityWritesNoCustomIdentifier() {
        let identity = BrowserUserAgent.identity(custom: "", prefersDesktop: false)
        XCTAssertNil(identity.customUserAgent)
        XCTAssertEqual(identity.applicationNameForUserAgent, BrowserUserAgent.safariTail)
    }

    func testACustomIdentifierBecomesTheOverride() {
        let identity = BrowserUserAgent.identity(custom: "MyAgent/9", prefersDesktop: true)
        // A custom string wins outright, desktop toggle included: someone who
        // typed one asked for that exact value.
        XCTAssertEqual(identity.customUserAgent, "MyAgent/9")
        // The tail is still set, which is harmless because the override replaces
        // the whole identifier — and it is what makes the desktop toggle a
        // one-property change.
        XCTAssertEqual(identity.applicationNameForUserAgent, BrowserUserAgent.safariTail)
    }

    func testTheCustomIdentifierIsTrimmed() {
        XCTAssertEqual(
            BrowserUserAgent.identity(custom: "  MyAgent/9  ", prefersDesktop: false).customUserAgent,
            "MyAgent/9"
        )
    }

    func testAWhitespaceOnlyCustomIdentifierIsNotACustomIdentifier() {
        XCTAssertNil(
            BrowserUserAgent.identity(custom: "   \n ", prefersDesktop: false).customUserAgent
        )
    }

    func testDesktopModeOverridesWithAMacIdentifier() {
        let identity = BrowserUserAgent.identity(custom: "", prefersDesktop: true)
        guard let desktop = identity.customUserAgent else {
            return XCTFail("desktop mode has to write a whole identifier: a web view will not claim a Mac for us")
        }
        XCTAssertTrue(desktop.contains("Macintosh"), desktop)
        XCTAssertTrue(desktop.contains("Mozilla/5.0"), desktop)
        // ` Mobile/` is the token that makes a string read as mobile, and macOS
        // Safari does not send it.
        XCTAssertFalse(desktop.contains("Mobile/"), desktop)
        let version = ProcessInfo.processInfo.operatingSystemVersion
        XCTAssertTrue(desktop.contains("Version/\(version.majorVersion)."), desktop)
    }

    /// The reconstruction used as the desktop base and shown in settings.
    func testTheReconstructedMobileIdentifierEndsWithTheTail() {
        XCTAssertTrue(BrowserUserAgent.mobileIdentifier.hasSuffix(BrowserUserAgent.safariTail))
        XCTAssertTrue(BrowserUserAgent.mobileIdentifier.hasPrefix("Mozilla/5.0 (iPhone;"))
    }

    func testTheDesktopFormKeepsTheEngineTokens() {
        let mobile = "Mozilla/5.0 (iPhone; CPU iPhone OS 18_2 like Mac OS X) "
            + "AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.2 Mobile/15E148 Safari/604.1"
        XCTAssertEqual(
            BrowserUserAgent.desktopForm(of: mobile),
            "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) "
                + "AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.2 Safari/604.1"
        )
    }

    func testAnIdentifierThatIsNotAMobileSafariOneIsLeftAlone() {
        // A custom or unusual string must survive rather than be mangled into
        // something half-changed.
        let value = "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 Chrome/120 Safari/537.36"
        XCTAssertEqual(BrowserUserAgent.desktopForm(of: value), value)
    }

    func testTheDesktopFormIsIdempotentOnAMacIdentifier() {
        let mac = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) "
            + "AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.2 Safari/604.1"
        XCTAssertEqual(BrowserUserAgent.desktopForm(of: mac), mac)
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

/// The one-line description printed under each preset row on the identifier
/// screen. It is derived from the identifier string itself so it cannot drift
/// from the string it describes; these pin the derivations.
final class PresetSummaryTests: XCTestCase {
    func testTheDefaultPresetSaysItIsGeneratedLive() {
        XCTAssertEqual(
            BrowserUserAgentPreset.all[0].claimedSummary,
            "由系统的 WebKit 现场生成，随 iOS 保持最新"
        )
    }

    func testEveryPresetProducesASummary() {
        for preset in BrowserUserAgentPreset.all {
            XCTAssertFalse(preset.claimedSummary.isEmpty, preset.id)
        }
    }

    func testTheIPhonePresetNamesTheDeviceTheSystemAndTheEngine() {
        let preset = BrowserUserAgentPreset.all.first { $0.id == "safari-iphone" }
        guard let preset else { return XCTFail("the iPhone preset is gone") }
        XCTAssertEqual(preset.claimedSummary, "iPhone · iOS 26.0 · Safari 26")
    }

    func testTheAndroidPresetNamesThePhoneAndTheEngine() {
        let preset = BrowserUserAgentPreset.all.first { $0.id == "chrome-android" }
        guard let preset else { return XCTFail("the Android preset is gone") }
        XCTAssertEqual(preset.claimedSummary, "Pixel 10 · Android 16 · Chrome 146")
    }

    func testAnEdgePresetIsNotMistakenForChrome() {
        let preset = BrowserUserAgentPreset.all.first { $0.id == "edge-windows" }
        guard let preset else { return XCTFail("the Edge preset is gone") }
        XCTAssertTrue(preset.claimedSummary.hasPrefix("Windows 10.0 · Edge 146"), preset.claimedSummary)
        XCTAssertFalse(preset.claimedSummary.contains("Chrome"), preset.claimedSummary)
    }

    func testTheMacPresetReadsAsMacOS() {
        let preset = BrowserUserAgentPreset.all.first { $0.id == "safari-macos" }
        guard let preset else { return XCTFail("the macOS preset is gone") }
        XCTAssertEqual(preset.claimedSummary, "macOS 10.15.7 · Safari 26")
    }
}
