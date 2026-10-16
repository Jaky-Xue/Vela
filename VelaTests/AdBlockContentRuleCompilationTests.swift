//
//  AdBlockContentRuleCompilationTests.swift
//  VelaTests
//
//  Whether WebKit will actually accept the rule list Vela builds.
//
//  This is separate from `AdBlockRuleSafetyTests`, which checks the rules'
//  *meaning* without WebKit. This one goes through `WKContentRuleListStore`, and
//  it exists because a rule list WebKit refuses to compile is worse than no rule
//  list: the compile throws, the caller is designed to keep whatever it had
//  before, and "whatever it had before" on a fresh install is nothing — so
//  blocking silently does not work at all, for the life of the install.
//
//  WebKit's error names no rule ("The operation couldn't be completed.
//  (WKErrorDomain error 6.)"), so the list is also compiled one rule at a time
//  here. That turns "the list does not compile" into the name of the rule that
//  broke it.
//

import XCTest
import WebKit
@testable import Vela

@MainActor
final class AdBlockContentRuleCompilationTests: XCTestCase {
    /// Compiles an encoded rule list into the app's store.
    ///
    /// A unique identifier per call, so one rule cannot be blamed for another's
    /// failure by way of a stale entry.
    private func compile(_ rules: [ContentBlockerRule], label: String) async throws -> WKContentRuleList {
        let json = try AdBlockRuleCompiler.encode(rules)
        let identifier = "org.vela.tests.compile.\(label)"
        // `default()` is failable in the Swift interface even though the app's
        // default parameter takes it implicitly unwrapped; a nil store here means
        // WebKit could not create one at all, which is worth saying rather than
        // crashing on.
        guard let store = WKContentRuleListStore.default() else {
            throw AdBlockError.compilationFailed("WebKit returned no default rule list store")
        }
        try? await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            store.removeContentRuleList(forIdentifier: identifier) { error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume() }
            }
        }
        return try await withCheckedThrowingContinuation { continuation in
            store.compileContentRuleList(forIdentifier: identifier, encodedContentRuleList: json) { list, error in
                if let error {
                    continuation.resume(throwing: error)
                } else if let list {
                    continuation.resume(returning: list)
                } else {
                    continuation.resume(throwing: AdBlockError.compilationFailed("no list returned"))
                }
            }
        }
    }

    private func shippedRules() -> [ContentBlockerRule] {
        let result = AdBlockRuleCompiler.compile(
            filterList: AdBlockBuiltInRules.filterLists.values.joined(separator: "\n"),
            includeCosmetic: true
        )
        return result.rules
    }

    /// The whole shipped list, which is what the app compiles at launch.
    func testTheShippedRuleListCompiles() async throws {
        let rules = shippedRules()
        XCTAssertFalse(rules.isEmpty)

        do {
            _ = try await compile(rules, label: "shipped")
        } catch {
            let nsError = error as NSError
            XCTFail(
                "WebKit refused the shipped rule list: "
                    + "\(nsError.domain)/\(nsError.code) — \(nsError.localizedDescription)"
            )
        }
    }

    /// Every rule on its own, so a failure names the rule.
    func testEveryShippedRuleCompilesOnItsOwn() async {
        var broken: [(index: Int, filter: String, error: String)] = []

        for (index, rule) in shippedRules().enumerated() {
            do {
                _ = try await compile([rule], label: "rule-\(index)")
            } catch {
                let nsError = error as NSError
                broken.append((index, rule.trigger.urlFilter, "\(nsError.domain)/\(nsError.code)"))
            }
        }

        XCTAssertTrue(
            broken.isEmpty,
            "WebKit refused \(broken.count) rule(s): "
                + broken.map { "#\($0.index) \($0.filter) [\($0.error)]" }.joined(separator: "; ")
        )
    }

    /// Removing a rule list that was never compiled.
    ///
    /// `install` removes the previous list before compiling the new one, and the
    /// first compile after a fresh install has nothing to remove. Whether WebKit
    /// reports that as an error decides whether the removal has to be tolerant —
    /// and if it does, an untolerated removal means the *first* compile always
    /// throws, which is a rule list that is never installed rather than one that
    /// is installed late. The answer is not documented anywhere useful, so it is
    /// asked here.
    func testRemovingARuleListThatDoesNotExist() async {
        guard let store = WKContentRuleListStore.default() else {
            return XCTFail("no default store")
        }
        let identifier = "org.vela.tests.absent.\(UUID().uuidString)"

        let error: Error? = await withCheckedContinuation { continuation in
            store.removeContentRuleList(forIdentifier: identifier) { error in
                continuation.resume(returning: error)
            }
        }

        print("=== removing an absent rule list → \(error.map { "\($0)" } ?? "no error") ===")

        // What matters is not WebKit's answer but what happens next: the compile
        // that follows a removal has to work either way. That is the property
        // `install` depends on, and the reason it tolerates the removal failing.
        do {
            _ = try await compile([shippedRules()[0]], label: "after-absent-removal")
        } catch {
            XCTFail("a compile after removing an absent list failed: \(error)")
        }
    }

    /// Every *shape* of pattern the compiler can emit, compiled through WebKit.
    ///
    /// This replaces a harder question — "which constructs does WebKit's
    /// validator accept" — with the one that actually matters, because the answer
    /// to the first is a moving target and the answer to the second is a property
    /// of this code. It is the guard against reintroducing the construct that
    /// broke the entire list: WebKit refuses a `$` anchor that is not the last
    /// character, including one inside a group, and refuses the whole rule list
    /// with an error that names no rule.
    func testEveryPatternShapeTheCompilerEmitsIsAccepted() async {
        let filters = [
            "||example.com^",
            "||example.com",
            "||example.com/ads",
            "|https://example.com/x",
            "|https://example.com/x|",
            "example.com/ads|",
            "example.com/track",
            "||example.com/a*b",
            "||example.com^$script,third-party",
            "||example.com^$domain=other.example",
            "https://example.com/?price=$5"
        ]

        var failures: [String] = []
        for filter in filters {
            // A filter the compiler declines is counted as unsupported rather
            // than emitted, which is a legitimate outcome; a filter it declines
            // by accident is reported here as the shape that went missing.
            guard let pattern = AdBlockRuleCompiler.regexFilter(for: filter) else {
                failures.append("\(filter) → the compiler emitted no pattern")
                continue
            }
            do {
                _ = try await compile(
                    [ContentBlockerRule(trigger: .init(urlFilter: pattern), action: .block)],
                    label: "shape"
                )
            } catch {
                let nsError = error as NSError
                failures.append("\(filter) → \(pattern) [\(nsError.domain)/\(nsError.code)]")
            }
        }

        XCTAssertTrue(
            failures.isEmpty,
            "WebKit refused emitted patterns: " + failures.joined(separator: "; ")
        )
    }

    /// The exception rules a site whitelist produces — the other thing the app
    /// hands to WebKit, and the one whose pattern is not built by `regexFilter`.
    func testTheExceptionRuleCompiles() async throws {
        let rules = AdBlockRuleCompiler.compile(
            filterList: "||ads.example^",
            exceptedHosts: ["trusted.example"],
            includeCosmetic: false
        ).rules
        _ = try await compile(rules, label: "exception")

        guard let exception = rules.last else { return XCTFail("no exception rule") }
        XCTAssertEqual(exception.action.type, "ignore-previous-rules")
        XCTAssertEqual(exception.trigger.urlFilter, ".*")
    }

    /// The two rules the safety tests care most about, checked both ways: that
    /// WebKit accepts the pattern and that the pattern matches and does not match
    /// what it is supposed to. A pattern that WebKit silently reinterprets is as
    /// bad as one it rejects.
    func testTheEmittedPatternsBehaveTheWayTheCompilerIntends() async throws {
        let rules = shippedRules()
        guard let rule = rules.first(where: { $0.trigger.urlFilter.contains("doubleclick") }) else {
            return XCTFail("no doubleclick rule was emitted")
        }
        _ = try await compile([rule], label: "doubleclick")

        let regex = try NSRegularExpression(pattern: rule.trigger.urlFilter)
        func matches(_ url: String) -> Bool {
            regex.firstMatch(in: url, range: NSRange(url.startIndex..<url.endIndex, in: url)) != nil
        }

        XCTAssertTrue(matches("https://ad.doubleclick.net/pixel?id=1"))
        XCTAssertTrue(matches("http://doubleclick.net/x"))
        XCTAssertFalse(matches("https://example.com/"))
        XCTAssertFalse(matches("https://example.com/?ref=doubleclick.net"))
    }
}
