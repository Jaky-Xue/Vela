//
//  ContentBlocker.swift
//  Vela
//
//  The built-in ad and tracker filter list, compiled into the one rule engine
//  WebKit gives a web view: `WKContentRuleList`.
//
//  The list is compiled once per launch into the shared WebKit store. A web
//  view copies the rule lists attached to it when it is built, so a list that
//  finishes compiling after a page exists is re-attached to the open web views
//  through `onChange`; the environment owns that wiring.
//
//  The numbers shown to the user are the ones this app can know: the rule
//  count it compiled. WebKit does not report which rules fired or how often,
//  so no blocked-request count is displayed or invented.
//

import Foundation
import WebKit
import Observation

@MainActor
@Observable
public final class ContentBlocker {
    /// One combined list: WebKit applies attached lists in order, and a later
    /// ignore rule could otherwise shadow an earlier block.
    public static let identifier = "org.vela.browser.content-blocker.builtin"

    public private(set) var isReady = false
    public private(set) var isCompiling = false
    public private(set) var ruleCount = 0
    public private(set) var lastError: String?
    public private(set) var loadedAt: Date?

    private let settings: SettingsService
    private let store: WKContentRuleListStore
    private var compiledList: WKContentRuleList?

    /// Called when the compiled list changes. The environment re-attaches it
    /// to web views that already exist, which were built before this list was
    /// available.
    public var onChange: (() -> Void)?

    public init(
        settings: SettingsService,
        store: WKContentRuleListStore = WKContentRuleListStore.default()
    ) {
        self.settings = settings
        self.store = store
    }

    /// The list a page may receive, or nil when blocking is off for it.
    public func ruleList(forHost host: String?) -> WKContentRuleList? {
        guard settings.contentBlocker.enabled, let compiledList else { return nil }
        if let host, settings.contentBlocker.isExcepted(host: host) { return nil }
        return compiledList
    }

    /// Compiles the shipped list. Safe to call more than once; a compile in
    /// flight is not restarted.
    public func prepare() {
        guard !isCompiling else { return }
        isCompiling = true

        let text = AdBlockBuiltInRules.filterLists
            .sorted { $0.key < $1.key }
            .map(\.value)
            .joined(separator: "\n")
        let result = AdBlockRuleCompiler.compile(filterList: text)
        ruleCount = result.rules.count

        guard result.rules.count <= AdBlockCompileResult.webKitRuleLimit else {
            lastError = "规则数量超过 WebKit 上限"
            isCompiling = false
            return
        }

        let encoded: String
        do {
            encoded = try AdBlockRuleCompiler.encode(result.rules)
        } catch {
            lastError = error.localizedDescription
            isCompiling = false
            return
        }

        Task { [weak self] in
            guard let self else { return }
            do {
                let list = try await self.store.compileContentRuleList(
                    forIdentifier: Self.identifier,
                    encodedContentRuleList: encoded
                )
                self.compiledList = list
                self.isReady = list != nil
                self.lastError = list == nil ? "WebKit 未返回规则列表" : nil
                self.loadedAt = Date()
            } catch {
                self.isReady = false
                self.compiledList = nil
                self.lastError = error.localizedDescription
            }
            self.isCompiling = false
            self.onChange?()
        }
    }

    /// Re-applies the current list after the settings changed.
    public func noteSettingsChanged() {
        onChange?()
    }
}
