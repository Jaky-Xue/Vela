//
//  AdBlockEngine.swift
//  Vela
//
//  Compiles filter lists into a `WKContentRuleList` and injects the cosmetic
//  filters a rule list cannot express.
//
//  Only two of the numbers here are real, and the settings screen says so.
//  WebKit does not report which rules fired or how often, so there is no
//  blocked-request count to show and none is fabricated. What this app can
//  measure is the cosmetic hiding it performs itself through injected CSS —
//  which it counts exactly — plus the rules and lists it actually loaded.
//

import Foundation
import WebKit
import Observation

/// A compiled rule list and what went into it.
public struct AdBlockCompiledList: Sendable {
    public var identifier: String
    public var ruleCount: Int
    public var cosmeticSelectors: [String]
    public var unsupportedRuleCount: Int
    public var invalidRuleCount: Int
    public var sourceLineCount: Int
}

@MainActor
@Observable
public final class AdBlockEngine {
    /// Identifier prefix for entries Vela owns in the shared WebKit store.
    /// Prefixed so a future list-management UI can find and evict exactly its
    /// own entries without touching another component's.
    private static let identifierPrefix = "org.vela.browser.adblock."

    /// A content rule list for the union of all enabled sources.
    ///
    /// One combined list rather than one per subscription: WebKit applies every
    /// attached list in order, and with several lists a rule in the first can be
    /// shadowed by an `ignore-previous-rules` in the second, which is not what a
    /// user expects from "enable another list". Combining preserves source order.
    public static let combinedIdentifier = identifierPrefix + "combined"

    public private(set) var isReady = false
    public private(set) var ruleCount = 0
    public private(set) var cosmeticSelectors: [String] = []
    public private(set) var lastError: String?
    public private(set) var unsupportedRuleCount = 0
    public private(set) var invalidRuleCount = 0
    public private(set) var sourceLineCount = 0
    public private(set) var lastCompiledAt: Date?

    /// Per-page count of elements the cosmetic filters actually hid.
    ///
    /// Reported by the injected script. Reset on each main-frame commit.
    public private(set) var lastPageHiddenCount = 0

    private let store: WKContentRuleListStore

    /// The compiled list, held so a navigation can attach it synchronously.
    ///
    /// `makeConfiguration(for:)` runs on the main actor while a web view is
    /// being built, and it cannot await. Keeping the compiled object in memory
    /// means the common case — compile once at launch, attach on every
    /// navigation after — never has to look the list up asynchronously.
    private var attachedList: WKContentRuleList?

    public init(store: WKContentRuleListStore = .default()) {
        self.store = store
    }

    /// The rule lists a configuration should attach.
    public func attachedRuleLists() -> [WKContentRuleList] {
        guard isReady, let attachedList else { return [] }
        return [attachedList]
    }

    // MARK: - Compiling

    /// Compiles every enabled source into one rule list and installs it.
    ///
    /// - Parameter filterLists: raw list text per source id. Text is passed in
    ///   rather than fetched here so the caller controls caching and network.
    @discardableResult
    public func compile(
        filterLists: [String: String],
        orderedSourceIds: [String],
        exceptedHosts: [String],
        includeCosmetic: Bool,
        enabled: Bool
    ) async throws -> AdBlockCompiledList {
        guard enabled else {
            try await removeCompiledList()
            isReady = false
            ruleCount = 0
            cosmeticSelectors = []
            return AdBlockCompiledList(
                identifier: Self.combinedIdentifier,
                ruleCount: 0,
                cosmeticSelectors: [],
                unsupportedRuleCount: 0,
                invalidRuleCount: 0,
                sourceLineCount: 0
            )
        }

        // Parsing and JSON encoding are pure and can be large; only the WebKit
        // store install has to run on the main actor.
        let parsed = try await Task.detached(priority: .utility) {
            try Self.parse(
                filterLists: filterLists,
                orderedSourceIds: orderedSourceIds,
                exceptedHosts: exceptedHosts,
                includeCosmetic: includeCosmetic
            )
        }.value
        let identifier = try await install(json: parsed.json)

        let compiled = AdBlockCompiledList(
            identifier: identifier,
            ruleCount: parsed.ruleCount,
            cosmeticSelectors: parsed.cosmeticSelectors,
            unsupportedRuleCount: parsed.unsupportedRuleCount,
            invalidRuleCount: parsed.invalidRuleCount,
            sourceLineCount: parsed.sourceLineCount
        )

        self.ruleCount = compiled.ruleCount
        self.cosmeticSelectors = compiled.cosmeticSelectors
        self.unsupportedRuleCount = compiled.unsupportedRuleCount
        self.invalidRuleCount = compiled.invalidRuleCount
        self.sourceLineCount = compiled.sourceLineCount
        self.lastCompiledAt = Date()
        self.lastError = nil
        self.isReady = true
        return compiled
    }

    /// Compiles JSON into the WebKit store, replacing any previous list.
    private func install(json: String) async throws -> String {
        let identifier = Self.combinedIdentifier

        // Replacing a list means removing it first. A store that has never held
        // this identifier — which is every fresh install — reports the removal of
        // something that was not there as an error, and treating that as fatal
        // meant the *first* compile never happened: ad blocking was compiled
        // nowhere and no rule list was ever attached, silently and permanently,
        // because the compile is retried at launch and fails the same way each
        // time.
        try? await store.removeContentRuleList(forIdentifier: identifier)

        return try await withCheckedThrowingContinuation { continuation in
            store.compileContentRuleList(
                forIdentifier: identifier,
                encodedContentRuleList: json
            ) { list, error in
                // The bookkeeping and the resumption happen together, on the
                // main actor. Assigning `attachedList` from a detached `Task`
                // instead would let `compile` return — and the next navigation
                // build its configuration — before the list was stored, so the
                // first page after a compile or a settings change would be loaded
                // without any rules at all.
                Task { @MainActor in
                    if let error {
                        // WebKit's error here is usually a rule it refused to
                        // parse. It does not say which rule, so the message is
                        // passed through verbatim rather than dressed up.
                        continuation.resume(
                            throwing: AdBlockError.compilationFailed(error.localizedDescription)
                        )
                        return
                    }
                    guard let list else {
                        continuation.resume(
                            throwing: AdBlockError.compilationFailed("系统未返回规则列表。")
                        )
                        return
                    }
                    self.attachedList = list
                    continuation.resume(returning: identifier)
                }
            }
        }
    }

    /// Loads the already-compiled list, if the WebKit store still has it.
    ///
    /// Called on launch so a slow compile does not delay the first page. WebKit
    /// persists compiled lists across launches, which is why this is a lookup
    /// and not a recompile.
    public func loadExistingList() async -> WKContentRuleList? {
        let list = await withCheckedContinuation { continuation in
            store.lookUpContentRuleList(forIdentifier: Self.combinedIdentifier) { list, _ in
                continuation.resume(returning: list)
            }
        }
        if let list {
            attachedList = list
            isReady = true
        }
        return list
    }

    public func removeCompiledList() async throws {
        // A list that is not there is not a failure: the caller is asking for
        // this store not to hold one, and it will not afterwards either way.
        try? await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            store.removeContentRuleList(forIdentifier: Self.combinedIdentifier) { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            }
        }
        attachedList = nil
        isReady = false
    }

    // MARK: - Per-site exceptions

    private struct ParsedRules: Sendable {
        var json: String
        var ruleCount: Int
        var cosmeticSelectors: [String]
        var unsupportedRuleCount: Int
        var invalidRuleCount: Int
        var sourceLineCount: Int
    }

    /// Parses, validates and encodes every list. Pure, so it runs off-main.
    nonisolated private static func parse(
        filterLists: [String: String],
        orderedSourceIds: [String],
        exceptedHosts: [String],
        includeCosmetic: Bool
    ) throws -> ParsedRules {
        var combined = ContentBlockerRuleAccumulator()

        // Sources are concatenated in the caller's order so that "later list
        // wins" behaves the way the subscription list is displayed.
        for sourceId in orderedSourceIds {
            guard let text = filterLists[sourceId] else { continue }
            let result = AdBlockRuleCompiler.compile(
                filterList: text,
                exceptedHosts: [],
                includeCosmetic: includeCosmetic
            )
            combined.append(result)
        }

        // Per-site exceptions are appended once, after every list, so they
        // override all of them.
        combined.rules.append(contentsOf: exceptionRules(for: exceptedHosts))

        guard combined.rules.count <= AdBlockCompileResult.webKitRuleLimit else {
            throw AdBlockError.ruleListTooLarge(count: combined.rules.count)
        }

        let json = try AdBlockRuleCompiler.encode(combined.rules)

        // Cosmetic selectors are deduplicated: the same `.ad-banner` appears in
        // most lists, and injecting it a hundred times would bloat the stylesheet
        // for no benefit.
        var seen = Set<String>()
        let selectors = combined.cosmeticSelectors.filter { seen.insert($0).inserted }

        return ParsedRules(
            json: json,
            ruleCount: combined.rules.count,
            cosmeticSelectors: selectors,
            unsupportedRuleCount: combined.unsupportedRuleCount,
            invalidRuleCount: combined.invalidRuleCount,
            sourceLineCount: combined.sourceLineCount
        )
    }

    private static func exceptionRules(for hosts: [String]) -> [ContentBlockerRule] {
        hosts.compactMap { host in
            let normalized = host.lowercased().trimmingCharacters(in: .whitespaces)
            guard !normalized.isEmpty else { return nil }
            return ContentBlockerRule(
                trigger: ContentBlockerRule.Trigger(
                    urlFilter: ".*",
                    ifDomain: ["*" + normalized]
                ),
                action: .ignorePreviousRules
            )
        }
    }

    // MARK: - Cosmetic injection

    /// The `id` the injected cosmetic `<style>` element carries, so the page and
    /// the injected script can both find it.
    public static let cosmeticStyleIdentifier = "org.vela.browser.adblock.cosmetic"

    /// Builds the CSS for a host, including the user's manual element hides.
    ///
    /// - Parameter manualSelectors: rules added with the element picker. They are
    ///   appended after the list selectors and marked `!important`, so a manual
    ///   hide overrides a site stylesheet as the user intended.
    public func cosmeticStyle(for host: String, manualSelectors: [String] = []) -> String? {
        guard isReady else { return nil }

        var selectors = cosmeticSelectors
        selectors.append(contentsOf: manualSelectors)
        guard !selectors.isEmpty else { return nil }

        // A selector containing a brace would break out of the rule block, so it
        // is skipped rather than allowed to corrupt the stylesheet.
        let safe = selectors.filter { !$0.contains("{") && !$0.contains("}") }
        guard !safe.isEmpty else { return nil }

        return safe.joined(separator: ",\n") + "\n{ display: none !important; }"
    }

    /// The script that reports how many elements the cosmetic CSS actually hid.
    ///
    /// Injected at document end so the DOM exists. The count is the only block
    /// statistic iOS can honestly produce, and it is reported per page rather
    /// than accumulated into a lifetime total that would imply completeness.
    public static var cosmeticCountingScript: String {
        """
        (function () {
          if (window.__velaCosmeticCounterInstalled) { return; }
          window.__velaCosmeticCounterInstalled = true;

          function report() {
            try {
              var style = document.getElementById('\(cosmeticStyleIdentifier)');
              if (!style || !style.sheet) { return; }
              var count = 0;
              var rules = style.sheet.cssRules || [];
              for (var i = 0; i < rules.length; i++) {
                try {
                  count += document.querySelectorAll(rules[i].selectorText || '').length;
                } catch (_error) {
                }
              }
              if (window.webkit && window.webkit.messageHandlers &&
                  window.webkit.messageHandlers.velaAdBlockReport) {
                window.webkit.messageHandlers.velaAdBlockReport.postMessage({
                  hiddenCount: count,
                  url: String(window.location.href || '')
                });
              }
            } catch (_error) {
            }
          }

          // Filtering runs as the page streams in, so a single pass at
          // document-end undercounts. Two deferred passes catch late insertions
          // without a MutationObserver, which would cost more than it is worth
          // on a page that mutates constantly.
          report();
          setTimeout(report, 800);
          setTimeout(report, 2500);
        })();
        """
    }

    public func applyReport(hiddenCount: Int) {
        lastPageHiddenCount = hiddenCount
    }

    public func resetPageReport() {
        lastPageHiddenCount = 0
    }
}

/// Accumulates compile results across several filter lists.
private struct ContentBlockerRuleAccumulator {
    var rules: [ContentBlockerRule] = []
    var cosmeticSelectors: [String] = []
    var unsupportedRuleCount = 0
    var invalidRuleCount = 0
    var sourceLineCount = 0

    mutating func append(_ result: AdBlockCompileResult) {
        rules.append(contentsOf: result.rules)
        cosmeticSelectors.append(contentsOf: result.cosmeticSelectors)
        unsupportedRuleCount += result.unsupportedRuleCount
        invalidRuleCount += result.invalidRuleCount
        sourceLineCount += result.sourceLineCount
    }
}
