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
