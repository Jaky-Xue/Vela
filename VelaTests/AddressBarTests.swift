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
/// Three properties matter, and each of them was wrong at some point. The version
/// has to be current: the app once hardcoded `Version/17.0`, so on a later iOS
/// every site was told the browser was Safari 17 and the ones that check answered
/// 「浏览器版本太低」. The string has to be Safari-shaped: a bare `WKWebView` sends
/// neither `Version/` nor `Safari/`, and a site that looks for them treats their
/// absence as an embedded browser — the same complaint from the other side, which
/// is what dropping the tail produced.
///
/// The third property is what makes the first survive both an OS release and an
/// old device: on a phone the default identity sets *no* custom identifier, so
/// WebKit builds the whole string from its own platform and engine tokens, and
/// Vela appends only the Safari tail — with the newest version this build knows,
/// which is the running system's when that is newer.
@MainActor
final class BrowserUserAgentTests: XCTestCase {
    /// What Vela adds, and the only part of the identifier it writes at all.
    func testTheTailIsTheSafariPartAndClaimsTheNewestSystem() {
        let tail = BrowserUserAgent.safariTail
        let claimed = BrowserUserAgent.claimedSystemVersion
        XCTAssertTrue(tail.hasPrefix("Version/\(claimed)"), tail)
        XCTAssertTrue(tail.contains("Mobile/"), tail)
        XCTAssertTrue(tail.contains("Safari/"), tail)
        XCTAssertFalse(tail.contains("Version/17.0"))

        // The claim is the running system's when that is newer, and this
        // build's newest known version otherwise — never older than the
        // device, which is what a page reads as a stale browser.
        let running = ProcessInfo.processInfo.operatingSystemVersion
        let runningText = "\(running.majorVersion).\(running.minorVersion)"
        XCTAssertEqual(
            BrowserUserAgent.claimedSystemVersion,
            BrowserUserAgent.isVersion(runningText, newerThan: BrowserUserAgent.newestSystemVersion)
                ? runningText
                : BrowserUserAgent.newestSystemVersion
        )
    }

    /// The default leaves the whole prefix to WebKit — on a phone — and adds
    /// only the tokens a bare `WKWebView` does not send.
    ///
    /// This is the property that adapts to a new OS by itself: Vela does not name
    /// the platform, and it does not name the engine's version token either —
    /// writing that down is the same mistake as writing down `Version/17.0`, one
    /// layer down. The device is stated rather than read so the test says which
    /// device it means, not which simulator happens to run it.
    func testTheDefaultIdentityKeepsWebKitsPrefixAndAddsTheSafariTail() {
        let identity = BrowserUserAgent.identity(custom: "", prefersDesktop: false, device: .phone)
        XCTAssertNil(identity.customUserAgent)
        XCTAssertFalse(identity.isDesktop)
        XCTAssertEqual(identity.applicationNameForUserAgent, BrowserUserAgent.safariTail)
    }

    /// An iPad's automatic identity is the desktop one, and it asks for the
    /// desktop layout with it.
    ///
    /// The identifier and the rendering flag are two halves of one claim: a Mac
    /// header over a mobile document is a page told it is a computer and laid
    /// out as a phone. The tablet branches of most sites are also the ones that
    /// age worst and the ones that break in landscape, which is the reason an
    /// iPad presents the desktop page even without the desktop toggle.
    func testAnIPadPresentsTheDesktopIdentityAutomatically() {
        let identity = BrowserUserAgent.identity(custom: "", prefersDesktop: false, device: .pad)
        // The automatic identity stays WebKit's own on both layouts — an iPad
        // already shows the desktop page under `.recommended` — and adds only
        // macOS Safari's tokens. A reconstructed Mac string here would be an
        // override the app does not need, and every script and site that reads
        // the identifier would see a Mac where the device is a tablet.
        XCTAssertNil(identity.customUserAgent)
        XCTAssertEqual(identity.applicationNameForUserAgent, BrowserUserAgent.desktopSafariTail)
        XCTAssertTrue(identity.isDesktop)
        XCTAssertTrue(identity.usesRecommendedContentMode)
        let explicitDesktop = BrowserUserAgent.identity(custom: "", prefersDesktop: true, device: .phone)
        XCTAssertTrue(explicitDesktop.isDesktop)
        XCTAssertFalse(explicitDesktop.usesRecommendedContentMode)
        XCTAssertNil(explicitDesktop.customUserAgent)
    }

    /// The identifier decides the layout now: a typed Windows string on a
    /// phone lays out a desktop document, an Android string lays out a mobile
    /// one, and a string carrying no platform token falls back to the device's
    /// automatic answer.
    func testATypedIdentifierDecidesTheLayout() {
        XCTAssertTrue(
            BrowserUserAgent.identity(
                custom: "Mozilla/5.0 (Windows NT 10.0; Win64; x64)",
                prefersDesktop: false,
                device: .phone
            ).isDesktop
        )
        XCTAssertFalse(
            BrowserUserAgent.identity(
                custom: "Mozilla/5.0 (Linux; Android 16; Pixel 10)",
                prefersDesktop: false,
                device: .phone
            ).isDesktop
        )
        XCTAssertFalse(
            BrowserUserAgent.identity(
                custom: "MyAgent/9",
                prefersDesktop: false,
                device: .phone
            ).isDesktop
        )
        XCTAssertTrue(
            BrowserUserAgent.identity(
                custom: "MyAgent/9",
                prefersDesktop: false,
                device: .pad
            ).isDesktop
        )
    }

    /// The video-site exception is a phone's. An iPad that asks for the desktop
    /// page gets it on YouTube too — the exception used to outrank the desktop
    /// toggle there, so 桌面网站 visibly did nothing on that site.
    func testAVideoSiteFollowsTheDeviceWhenTheDeviceWantsDesktop() {
        let phone = BrowserUserAgent.identity(
            custom: "",
            prefersDesktop: false,
            host: "www.youtube.com",
            device: .phone
        )
        XCTAssertNil(phone.customUserAgent)
        XCTAssertFalse(phone.isDesktop)

        let pad = BrowserUserAgent.identity(
            custom: "",
            prefersDesktop: false,
            host: "www.youtube.com",
            device: .pad
        )
        XCTAssertNil(pad.customUserAgent)
        XCTAssertEqual(pad.applicationNameForUserAgent, BrowserUserAgent.desktopSafariTail)
        XCTAssertTrue(pad.isDesktop)

        // The explicit desktop toggle on a phone gets the same answer.
        let phoneDesktop = BrowserUserAgent.identity(
            custom: "",
            prefersDesktop: true,
            host: "www.youtube.com",
            device: .phone
        )
        XCTAssertNil(phoneDesktop.customUserAgent)
        XCTAssertEqual(
            phoneDesktop.applicationNameForUserAgent,
            BrowserUserAgent.desktopSafariTail
        )
        XCTAssertTrue(phoneDesktop.isDesktop)
    }

    /// A site's own choice outranks the device, the identifier preset and the
    /// video-site exception: it is the most specific answer there is.
    func testASiteChoiceOutranksEveryOtherIdentityRule() {
        let phoneDesktop = BrowserUserAgent.identity(
            custom: BrowserUserAgent.mobileIdentifier,
            prefersDesktop: false,
            host: "www.youtube.com",
            device: .phone,
            siteMode: .desktop
        )
        XCTAssertEqual(phoneDesktop.customUserAgent, BrowserUserAgent.desktopIdentifier)
        XCTAssertTrue(phoneDesktop.isDesktop)

        let padMobile = BrowserUserAgent.identity(
            custom: "",
            prefersDesktop: true,
            host: "example.com",
            device: .pad,
            siteMode: .mobile
        )
        XCTAssertNil(padMobile.customUserAgent)
        XCTAssertFalse(padMobile.isDesktop)
    }

    /// The explicit iPad preset is the way back to a site's tablet page. The
    /// preset carries its own layout, so choosing it is the whole request.
    func testTheLegacyIPadPresetUsesSystemMobileMode() {
        guard let preset = BrowserUserAgentPreset.all.first(where: { $0.id == "safari-ipad" }) else {
            return XCTFail("no iPad preset")
        }
        let identity = BrowserUserAgent.identity(
            custom: preset.userAgent ?? "",
            prefersDesktop: false,
            device: .pad
        )
        XCTAssertNil(identity.customUserAgent)
        XCTAssertFalse(identity.isDesktop)
    }

    /// A typed desktop identifier carries the desktop layout with it: there is
    /// no separate layout switch to leave behind.
    func testATypedDesktopIdentifierLaysOutADesktopDocument() {
        let typed = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) MyAgent/9"
        let identity = BrowserUserAgent.identity(
            custom: typed,
            prefersDesktop: false,
            device: .phone
        )
        XCTAssertEqual(identity.customUserAgent, typed)
        XCTAssertTrue(identity.isDesktop)
    }

    /// A typed mobile identifier keeps a mobile layout even on an iPad, where
    /// the automatic identity would have been desktop.
    func testAStoredMobileSystemIdentifierFollowsTheSystemOnAnIPad() {
        let identity = BrowserUserAgent.identity(
            custom: BrowserUserAgent.mobileIdentifier,
            prefersDesktop: false,
            device: .pad
        )
        // The system presets are not values to send: the stored string means
        // "the phone identity", so the page gets WebKit's own string with the
        // current Safari tail rather than a frozen literal.
        XCTAssertNil(identity.customUserAgent)
        XCTAssertEqual(identity.applicationNameForUserAgent, BrowserUserAgent.safariTail)
        XCTAssertFalse(identity.isDesktop)
    }

    /// A desktop identifier chosen on a phone lays the document out as a
    /// desktop one, and claims the newest version with it.
    func testAStoredDesktopSystemIdentifierUsesTheDesktopLayout() {
        let identity = BrowserUserAgent.identity(
            custom: BrowserUserAgent.desktopIdentifier,
            prefersDesktop: false,
            device: .phone
        )
        XCTAssertEqual(identity.customUserAgent, BrowserUserAgent.desktopIdentifier)
        XCTAssertTrue(identity.isDesktop)
        XCTAssertTrue(
            identity.customUserAgent?.contains("Version/\(BrowserUserAgent.claimedSystemVersion)")
                ?? false
        )
    }

    /// A literal an earlier build stored for a system preset follows the system
    /// again instead of being sent verbatim.
    ///
    /// Builds before 4.0.77 wrote the preset down as a string — `26_0`, `26_1`,
    /// whatever the OS was when the user chose it. A literal is fine until the
    /// OS moves; then it is exactly the stale label sites reject, and it was
    /// never something the user typed.
    func testALiteralStoredByAnEarlierBuildFollowsTheSystem() {
        let stored = "Mozilla/5.0 (iPhone; CPU iPhone OS 26_0 like Mac OS X) "
            + "AppleWebKit/605.1.15 (KHTML, like Gecko) "
            + "Version/26.0 Mobile/15E148 Safari/604.1"
        let identity = BrowserUserAgent.identity(custom: stored, prefersDesktop: false, device: .phone)
        XCTAssertNil(identity.customUserAgent)
        XCTAssertEqual(identity.applicationNameForUserAgent, BrowserUserAgent.safariTail)
        XCTAssertFalse(identity.isDesktop)
        XCTAssertEqual(BrowserUserAgentPreset.matching(stored)?.id, "safari-iphone")
    }

    func testALiteralStoredForTheDesktopPresetKeepsTheDesktopLayout() {
        let stored = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) "
            + "AppleWebKit/605.1.15 (KHTML, like Gecko) Version/26.0 Safari/605.1.15"
        let identity = BrowserUserAgent.identity(custom: stored, prefersDesktop: false, device: .phone)
        XCTAssertEqual(identity.customUserAgent, BrowserUserAgent.desktopIdentifier)
        XCTAssertTrue(identity.isDesktop)
        XCTAssertEqual(BrowserUserAgentPreset.matching(stored)?.id, "safari-macos")
    }

    /// A string naming another browser is a compatibility choice and is sent as
    /// given; only Safari-shaped literals are read as system presets.
    func testACompatibilityIdentifierIsNotReadAsASystemPreset() {
        // A version the preset list does not carry, so this is about the
        // shape — not about landing on the exact literal of a preset.
        let chrome = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 "
            + "(KHTML, like Gecko) Chrome/157.0.0.0 Safari/537.36"
        let identity = BrowserUserAgent.identity(custom: chrome, prefersDesktop: false, device: .phone)
        XCTAssertEqual(identity.customUserAgent, chrome)
        XCTAssertTrue(identity.isDesktop)
        XCTAssertNil(BrowserUserAgentPreset.systemSafariPresetID(for: chrome))
    }

    /// The Chrome preset itself is a real override: it is sent as written, and
    /// no Safari tail is appended to it.
    func testACompatibilityPresetIsSentExactlyAsWritten() {
        guard let preset = BrowserUserAgentPreset.all.first(where: { $0.id == "chrome-windows" }),
              let chrome = preset.userAgent else {
            return XCTFail("no Chrome Windows preset")
        }
        let identity = BrowserUserAgent.identity(custom: chrome, prefersDesktop: false, device: .phone)
        XCTAssertEqual(identity.customUserAgent, chrome)
        XCTAssertEqual(identity.isDesktop, preset.isDesktop)
    }

    func testACustomIdentifierBecomesTheOverride() {
        let identity = BrowserUserAgent.identity(custom: "MyAgent/9", prefersDesktop: true)
        // A custom string wins outright, desktop toggle included: someone who
        // typed one asked for that exact value.
        XCTAssertEqual(identity.customUserAgent, "MyAgent/9")
        // The tail is still set, which is harmless because the override
        // replaces the whole identifier — and it is what the tab falls back to
        // when the string is cleared.
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
            BrowserUserAgent.identity(custom: "   \n ", prefersDesktop: false, device: .phone).customUserAgent
        )
    }

    func testDesktopModeKeepsWebKitsIdentityWithTheDesktopTail() {
        let identity = BrowserUserAgent.identity(custom: "", prefersDesktop: true)
        XCTAssertTrue(identity.isDesktop)
        XCTAssertNil(identity.customUserAgent)
        XCTAssertEqual(identity.applicationNameForUserAgent, BrowserUserAgent.desktopSafariTail)
        XCTAssertFalse(identity.usesRecommendedContentMode)

        // An explicit 系统桌面版 choice still sends the reconstructed Mac
        // string, because that one has to be swapped in and out of a live tab.
        guard let preset = BrowserUserAgentPreset.all.first(where: { $0.id == "safari-macos" }),
              let stored = preset.userAgent else {
            return XCTFail("no 系统桌面版 preset")
        }
        let explicit = BrowserUserAgent.identity(custom: stored, prefersDesktop: false, device: .pad)
        XCTAssertEqual(explicit.customUserAgent, BrowserUserAgent.desktopIdentifier)
        XCTAssertTrue(explicit.isDesktop)
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
    func testTheDefaultPresetDescribesDeviceFollowing() {
        XCTAssertEqual(
            BrowserUserAgentPreset.all[0].claimedSummary,
            "按当前设备自动决定：iPhone 手机版，iPad 与 Mac 桌面版"
        )
    }

    func testEveryPresetProducesASummary() {
        for preset in BrowserUserAgentPreset.all {
            XCTAssertFalse(preset.claimedSummary.isEmpty, preset.id)
        }
    }

    func testTheIPhonePresetDescribesNativeMobileMode() {
        let preset = BrowserUserAgentPreset.all.first { $0.id == "safari-iphone" }
        guard let preset else { return XCTFail("the iPhone preset is gone") }
        XCTAssertEqual(preset.claimedSummary, "由当前系统生成手机版标识")
    }

    func testTheLegacyIPadPresetDescribesNativeMobileMode() {
        let preset = BrowserUserAgentPreset.all.first { $0.id == "safari-ipad" }
        guard let preset else { return XCTFail("the iPad preset is gone") }
        XCTAssertEqual(preset.claimedSummary, "由当前系统生成手机版标识")
        XCTAssertFalse(preset.isDesktop)
    }

    func testTheAndroidPresetNamesThePhoneAndTheEngine() {
        let preset = BrowserUserAgentPreset.all.first { $0.id == "chrome-android" }
        guard let preset else { return XCTFail("the Android preset is gone") }
        XCTAssertEqual(preset.claimedSummary, "Pixel 11 · Android 17 · Chrome 158")
    }

    func testAnEdgePresetIsNotMistakenForChrome() {
        let preset = BrowserUserAgentPreset.all.first { $0.id == "edge-windows" }
        guard let preset else { return XCTFail("the Edge preset is gone") }
        XCTAssertTrue(preset.claimedSummary.hasPrefix("Windows 10.0 · Edge 157"), preset.claimedSummary)
        XCTAssertFalse(preset.claimedSummary.contains("Chrome"), preset.claimedSummary)
    }

    func testTheMacPresetDescribesNativeDesktopMode() {
        let preset = BrowserUserAgentPreset.all.first { $0.id == "safari-macos" }
        guard let preset else { return XCTFail("the macOS preset is gone") }
        XCTAssertEqual(preset.claimedSummary, "由当前系统生成桌面版标识")
    }
}

// MARK: - Per-site display

/// The stored 桌面/手机 choices: host normalization, parent-domain matching,
/// and the viewport script that makes 桌面版 a layout rather than only a header.
final class SiteDisplayTests: XCTestCase {
    func testHostsAreNormalized() {
        XCTAssertEqual(
            BrowserSiteHost.normalize("https://WWW.Example.com:443/path"),
            "example.com"
        )
        XCTAssertEqual(BrowserSiteHost.normalize("m.example.com"), "m.example.com")
        XCTAssertEqual(BrowserSiteHost.normalize("  "), "")
    }

    func testARuleCoversSubdomainsAndNotLookalikes() {
        var settings = SiteDisplaySettings.default
        settings.set(.desktop, forPageHost: "example.com")
        XCTAssertEqual(settings.mode(forPageHost: "www.example.com"), .desktop)
        XCTAssertEqual(settings.mode(forPageHost: "m.example.com"), .desktop)
        XCTAssertNil(settings.mode(forPageHost: "notexample.com"))
        XCTAssertNil(settings.mode(forPageHost: "example.org"))
    }

    func testTheMostSpecificRuleWins() {
        var settings = SiteDisplaySettings.default
        settings.set(.desktop, forPageHost: "example.com")
        settings.set(.mobile, forPageHost: "m.example.com")
        XCTAssertEqual(settings.mode(forPageHost: "m.example.com"), .mobile)
        XCTAssertEqual(settings.mode(forPageHost: "www.example.com"), .desktop)
    }

    func testClearingOneSiteLeavesTheOthers() {
        var settings = SiteDisplaySettings.default
        settings.set(.desktop, forPageHost: "a.example")
        settings.set(.mobile, forPageHost: "b.example")
        settings.set(nil, forPageHost: "a.example")
        XCTAssertNil(settings.mode(forPageHost: "a.example"))
        XCTAssertEqual(settings.mode(forPageHost: "b.example"), .mobile)
    }

    func testTheDesktopViewportScriptLiftsOnlyADeviceWidthDeclaration() {
        let script = WebPageScripts.desktopViewportScript
        XCTAssertTrue(script.contains("1200"), script)
        XCTAssertTrue(script.contains("device-width"), script)
        XCTAssertTrue(script.contains("initial-scale"), script)
        // The rewrite is gated on the site's own declaration; a page that
        // named its own width already made a desktop choice.
        XCTAssertTrue(script.contains("test(content)"), script)
    }
}
