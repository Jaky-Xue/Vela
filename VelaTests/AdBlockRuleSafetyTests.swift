//
//  AdBlockRuleSafetyTests.swift
//  VelaTests
//
//  What the shipped filter lists are allowed to do.
//
//  A content rule list is compiled by WebKit and then applied to every request a
//  page makes, including the request for the page itself. A single rule whose
//  pattern is too broad therefore does not degrade the page — it prevents the
//  page from existing, and it does so with no error a user could act on. That is
//  the worst failure a browser can have, and it is invisible in a type signature,
//  so it is asserted here.
//
//  These tests are about the rules as the compiler emits them, which is the only
//  thing WebKit sees. Compiling the shipped lists and running the generated
//  regular expressions against real URLs is as close to WebKit's own behaviour as
//  a test can get without a web view.
//

import XCTest
@testable import Vela

final class AdBlockRuleSafetyTests: XCTestCase {
    private struct Compiled {
        var rules: [ContentBlockerRule]
        var cosmeticSelectors: [String]
    }

    private func compileShipped() -> Compiled {
        let result = AdBlockRuleCompiler.compile(
            filterList: AdBlockBuiltInRules.filterLists
                .sorted { $0.key < $1.key }
                .map(\.value)
                .joined(separator: "\n"),
            includeCosmetic: true
        )
        return Compiled(rules: result.rules, cosmeticSelectors: result.cosmeticSelectors)
    }

    /// URLs a browser has to be able to open without help.
    private static let ordinaryUrls = [
        "https://example.com/",
        "https://example.com/a/b?c=1&d=2",
        "https://www.google.com/search?q=vela",
        "https://www.bing.com/search?q=vela",
        "https://www.baidu.com/s?wd=vela",
        "https://duckduckgo.com/?q=vela",
        "https://news.ycombinator.com/item?id=1",
        "https://github.com/apple/swift",
        "https://en.wikipedia.org/wiki/Browser",
        "https://www.zhihu.com/question/1",
        "https://www.bilibili.com/video/BV1",
        "https://weibo.com/u/1",
        "https://taobao.com/item.htm?id=1",
        "https://mail.qq.com/",
        "https://developer.apple.com/documentation/webkit",
        "https://cdn.example.com/assets/app.js",
        "https://static.example.com/style.css",
        "https://images.example.com/photo.jpg",
        "https://api.example.com/v1/items",
        "https://example.com/ads.txt"
    ]

    private func matches(urlFilter: String, url: String) -> Bool {
        guard let regex = try? NSRegularExpression(pattern: urlFilter) else { return false }
        let range = NSRange(url.startIndex..<url.endIndex, in: url)
        return regex.firstMatch(in: url, range: range) != nil
    }

    // MARK: - Rules must not match a page that has nothing to do with ads

    func testNoShippedRuleMatchesOrdinaryPages() {
        let compiled = compileShipped()
        XCTAssertFalse(compiled.rules.isEmpty, "the shipped lists produced no rules at all")

        for rule in compiled.rules where rule.action.type == "block" {
            let types = rule.trigger.resourceType ?? []
            // A rule with no `resource-type` applies to every type, and
            // `document` is the main frame. Those are the ones that can stop a
            // page from opening at all.
            let canBlockAMainDocument = types.isEmpty || types.contains("document")
            guard canBlockAMainDocument else { continue }

            for url in Self.ordinaryUrls {
                XCTAssertFalse(
                    matches(urlFilter: rule.trigger.urlFilter, url: url),
                    "rule \(rule.trigger.urlFilter) matches \(url) — this would block a page"
                )
            }
        }
    }

    func testNoShippedRuleMatchesAPlainSelfHostedNavigation() {
        let compiled = compileShipped()
        // The exact case a browser is judged on: the user typed a domain.
        for url in ["https://example.com", "https://example.com/", "http://example.com/page"] {
            for rule in compiled.rules where rule.action.type == "block" {
                XCTAssertFalse(
                    matches(urlFilter: rule.trigger.urlFilter, url: url),
                    "rule \(rule.trigger.urlFilter) matches \(url)"
                )
            }
        }
    }

    // MARK: - Rules must match what they are for

    /// The other half: a test that only asserts "nothing matches" would pass just
    /// as well if the compiler emitted no rules.
    func testTheShippedRulesDoMatchAdRequests() {
        let compiled = compileShipped()
        let blockRules = compiled.rules.filter { $0.action.type == "block" }

        let adUrls = [
            "https://doubleclick.net/ad",
            "https://ad.doubleclick.net/pixel?id=1",
            "https://www.googlesyndication.com/pagead/js/adsbygoogle.js",
            "https://pagead2.googlesyndication.com/pagead/js/adsbygoogle.js",
            "https://hm.baidu.com/hm.js",
            "https://pos.baidu.com/pos.php",
            "https://cpro.baidu.com/cpro/ui/c.js",
            "https://gdt.qq.com/gdt.php",
            "https://e.qq.com/abc"
        ]

        for url in adUrls {
            let matched = blockRules.contains { matches(urlFilter: $0.trigger.urlFilter, url: url) }
            XCTAssertTrue(matched, "no shipped rule blocks \(url)")
        }
    }

    func testAnAdSubdomainDoesNotDragItsWholeDomainIn() {
        // The domain anchor has to mean "this host or a subdomain of it", not
        // "any URL containing this text". A rule for `criteo.com` must not match
        // a page that merely mentions it in a query.
        let compiled = compileShipped()
        let blockRules = compiled.rules.filter { $0.action.type == "block" }

        for url in [
            "https://example.com/?ref=criteo.com",
            "https://example.com/article/about-doubleclick.net",
            "https://mycriteo.example/page",
            "https://example.com/tanx.com.html"
        ] {
            let matched = blockRules.contains { matches(urlFilter: $0.trigger.urlFilter, url: url) }
            XCTAssertFalse(matched, "an ad rule matched the harmless URL \(url)")
        }
    }

    // MARK: - Cosmetic rules

    /// A cosmetic rule hides elements by selector. One that names `body`, `html`
    /// or a bare element hides the page.
    ///
    /// The check is that every selector carries a constraint — a class or an
    /// attribute — rather than being a bare element name. `div[data-ad-slot]` is
    /// constrained and safe; `div` would not be.
    func testNoShippedCosmeticRuleHidesTheWholePage() {
        let compiled = compileShipped()
        XCTAssertFalse(compiled.cosmeticSelectors.isEmpty)

        let forbidden: Set<String> = ["*", "body", "html", "div", "a", "p", "span", "main", "article", "iframe"]
        for selector in compiled.cosmeticSelectors {
            let lowered = selector.lowercased()
            XCTAssertFalse(
                forbidden.contains(lowered),
                "cosmetic rule \(selector) would hide the page itself"
            )
            XCTAssertTrue(
                lowered.contains(".") || lowered.contains("["),
                "cosmetic rule \(selector) has no class or attribute constraint"
            )
            // A selector is interpolated into a stylesheet, so a brace in one
            // would break out of its rule block.
            XCTAssertFalse(
                selector.contains("{") || selector.contains("}"),
                "cosmetic rule \(selector) could escape its rule block"
            )
        }
    }

    // MARK: - The pattern shapes WebKit will accept

    /// The `$` anchor is only valid as the last character.
    ///
    /// The compiler used to append `([^…]|$)` to every domain-anchored rule in
    /// order to match a URL that ended at the host. WebKit's content-extension
    /// validator refuses a `$` inside a group and refuses the *entire rule list*
    /// when it meets one — with "Invalid or unsupported regular expression" and
    /// no indication of which rule or which part — so the shipped list never
    /// compiled and ad blocking did nothing at all. Measuring the candidates one
    /// at a time through `WKContentRuleListStore` is what identified the
    /// construct; this keeps it out.
    func testTheDollarAnchorIsOnlyValidAtTheEnd() {
        XCTAssertFalse(AdBlockRuleCompiler.isAcceptable("^https://example\\.com([^/]|$)"))
        XCTAssertFalse(AdBlockRuleCompiler.isAcceptable("(abc|$)"))
        XCTAssertTrue(AdBlockRuleCompiler.isAcceptable("^https://example\\.com/$"))
        XCTAssertTrue(AdBlockRuleCompiler.isAcceptable("^https://example\\.com/"))
        XCTAssertTrue(AdBlockRuleCompiler.isAcceptable(".*"))
    }

    func testAPatternThatIsNotARegularExpressionIsRefused() {
        // WebKit would refuse the whole list over it, and would not say which
        // rule was to blame.
        XCTAssertFalse(AdBlockRuleCompiler.isAcceptable("["))
        XCTAssertFalse(AdBlockRuleCompiler.isAcceptable("(unclosed"))
    }

    func testADomainAnchorDoesNotEmitAGroupedDollarAnchor() throws {
        let pattern = try XCTUnwrap(AdBlockRuleCompiler.regexFilter(for: "||doubleclick.net^"))
        XCTAssertFalse(pattern.contains("|$"), "pattern was \(pattern)")
        XCTAssertTrue(pattern.contains("[^a-zA-Z0-9_.%-]"), "pattern was \(pattern)")
        XCTAssertTrue(AdBlockRuleCompiler.isAcceptable(pattern))
    }

    /// What the domain-anchor pattern matches, including the one case the
    /// end-of-URL alternative used to cover and no longer does.
    func testADomainAnchorPatternMatchesHostsAndPaths() throws {
        let pattern = try XCTUnwrap(AdBlockRuleCompiler.regexFilter(for: "||doubleclick.net^"))
        let regex = try NSRegularExpression(pattern: pattern)
        func matches(_ url: String) -> Bool {
            regex.firstMatch(in: url, range: NSRange(url.startIndex..<url.endIndex, in: url)) != nil
        }

        XCTAssertTrue(matches("https://ad.doubleclick.net/pixel?id=1"))
        XCTAssertTrue(matches("http://doubleclick.net/x"))
        XCTAssertTrue(matches("https://doubleclick.net/"))

        XCTAssertFalse(matches("https://example.com/"))
        XCTAssertFalse(matches("https://example.com/?ref=doubleclick.net"))
        // A lookalike host is not the host: the `^` separator requires something
        // that is not a dot, a letter or a digit, and `.` is a dot.
        XCTAssertFalse(matches("https://doubleclick.net.example.com/x"))

        // The case given up: a URL that stops at the host with no path at all.
        // An `http(s)` request URL always carries a `/`, so nothing real is
        // missed — and if this ever did matter, `$` inside a group is what cannot
        // be used to cover it.
        XCTAssertFalse(matches("https://doubleclick.net"))
    }

    /// An end anchor at the very end of a pattern is still expressible, which is
    /// what a `|`-terminated filter needs.
    func testATrailingEndAnchorIsKeptAsATrailingDollar() throws {
        let pattern = try XCTUnwrap(AdBlockRuleCompiler.regexFilter(for: "|https://example.com/x|"))
        XCTAssertTrue(pattern.hasSuffix("$"), "pattern was \(pattern)")
        XCTAssertTrue(pattern.hasPrefix("^"), "pattern was \(pattern)")
        XCTAssertTrue(AdBlockRuleCompiler.isAcceptable(pattern))
    }

    // MARK: - Rule-shape invariants

    func testEveryCompiledRuleIsValidJsonAndHasAnAction() throws {
        let compiled = compileShipped()
        let json = try AdBlockRuleCompiler.encode(compiled.rules)
        let decoded = try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [[String: Any]]
        XCTAssertEqual(decoded?.count, compiled.rules.count)

        for rule in compiled.rules {
            XCTAssertFalse(rule.trigger.urlFilter.isEmpty)
            XCTAssertFalse(rule.action.type.isEmpty)
            if rule.action.type == "css-display-none" {
                XCTAssertNotNil(rule.action.selector)
            }
            // WebKit rejects the entire list when one filter will not compile,
            // so every emitted pattern has to be a valid regular expression.
            XCTAssertNoThrow(
                try NSRegularExpression(pattern: rule.trigger.urlFilter),
                "invalid url-filter: \(rule.trigger.urlFilter)"
            )
        }
    }

    func testTheExceptionRulesAreEmittedLastSoTheyWin() {
        let result = AdBlockRuleCompiler.compile(
            filterList: "||ads.example^",
            exceptedHosts: ["trusted.example"],
            includeCosmetic: false
        )
        XCTAssertEqual(result.rules.last?.action.type, "ignore-previous-rules")
        XCTAssertEqual(result.rules.last?.trigger.ifDomain, ["*trusted.example"])
    }

    /// The per-site exception has to actually suppress the blocking rule for that
    /// host, which is what the user asked for when they added the site.
    func testAnExceptedHostIsNotBlocked() {
        let result = AdBlockRuleCompiler.compile(
            filterList: "||ads.example^",
            exceptedHosts: ["trusted.example"],
            includeCosmetic: false
        )
        let blockRules = result.rules.filter { $0.action.type == "block" }
        XCTAssertEqual(blockRules.count, 1)

        // The exception carries no resource-type, so it applies to the same
        // requests the blocking rule does.
        guard let exception = result.rules.last else { return XCTFail("no exception rule") }
        XCTAssertNil(exception.trigger.resourceType)
        XCTAssertEqual(exception.trigger.urlFilter, ".*")
    }

    func testTheCompilerRefusesAFilterItCannotRepresent() {
        let result = AdBlockRuleCompiler.compile(
            filterList: """
            /regex-rule/
            example.com##+js(nano-setInterval-booster)
            example.com#?#div:has-text(Sponsored)
            ||ok.example^
            """,
            includeCosmetic: true
        )
        // Only the one representable rule becomes a rule; the rest are counted as
        // unsupported rather than silently dropped.
        XCTAssertEqual(result.rules.count, 1)
        XCTAssertGreaterThanOrEqual(result.unsupportedRuleCount, 3)
    }
}

// MARK: - The built-in lists themselves

final class AdBlockBuiltInRulesTests: XCTestCase {
    func testTheShippedSourcesAreEnabledAndNamed() {
        let sources = AdBlockBuiltInRules.sources
        XCTAssertEqual(sources.count, 3)
        XCTAssertTrue(sources.allSatisfy(\.enabled))
        XCTAssertTrue(sources.allSatisfy { !$0.name.isEmpty })
        XCTAssertEqual(Set(sources.map(\.id)).count, sources.count)
    }

    func testEverySourceHasTextToCompile() {
        for source in AdBlockBuiltInRules.sources {
            let text = AdBlockBuiltInRules.filterLists[source.id]
            XCTAssertNotNil(text, "\(source.id) has no filter list text")
            XCTAssertFalse(text?.isEmpty ?? true)
        }
    }

    func testTheListsStayWellUnderTheWebKitRuleLimit() {
        let result = AdBlockRuleCompiler.compile(
            filterList: AdBlockBuiltInRules.filterLists.values.joined(separator: "\n"),
            includeCosmetic: true
        )
        XCTAssertLessThan(result.rules.count, AdBlockCompileResult.webKitRuleLimit)
        XCTAssertEqual(result.invalidRuleCount, 0, "a shipped rule failed to parse")
    }
}
