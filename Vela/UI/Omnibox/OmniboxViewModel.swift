//
//  OmniboxViewModel.swift
//  Vela
//
//  The omnibox's state machine: the suggestion sources, their merge order, and
//  everything to do with a suggestion session.
//
//  The merge order is the part users notice:
//
//    1. A URL the user is typing — always first, because it is what they mean.
//    2. Open tabs — cheapest to offer, and most likely to be what a second tab
//       was opened for.
//    3. Bookmarks — a deliberate save, so it outranks mere history.
//    4. Past queries and browsing history, ranked by the repository's score.
//    5. Search — always last, always present, so pressing return with nothing
//       highlighted does something predictable.
//
//  Remote suggestions are off by default and stay off unless the user enables
//  them: nothing here sends keystrokes to a provider.
//
//  The session — input debounce, the keyboard-highlighted row, per-section
//  disclosure that survives a relaunch, row deletion — is one observable object
//  rather than several, because all of it mutates the same list and splitting it
//  would mean several owners of one array.
//

import Foundation
import SwiftUI
import UIKit
import Observation

// MARK: - Suggestion engine

/// Builds the suggestion list.
///
/// Kept as a pure function of
/// its inputs rather than a live observer so the omnibox can build a list for
/// the text currently in the field.
@MainActor
struct OmniboxSuggestionEngine {
    let settings: SettingsService
    let history: HistoryService
    let bookmarks: BookmarkService
    let searchHistory: SearchHistoryRepository
    let tabManager: TabManager

    /// How many rows each source may contribute.
    private enum Limit {
        static let openTabs = 4
        static let bookmarks = 4
        static let pastQueries = 4
        static let browsingHistory = 5
        /// Rows offered before the user has typed anything.
        static let idleQueries = 6
    }

    /// The full list, in priority order.
    ///
    /// `remoteSuggestions` are the engine's 联网搜索推荐 rows, already fetched
    /// and sanitised. They belong to the search section, after the row for the
    /// text the user actually typed: return still does the predictable thing,
    /// and a recommendation is one tap away.
    func suggestions(
        for rawInput: String,
        privacyMode: BrowserSessionPrivacyMode,
        remoteSuggestions: [String] = []
    ) -> [OmniboxSuggestion] {
        // The master switch of the 搜索建议 section: off, the omnibox offers
        // nothing at all rather than a list that ignores part of its own
        // settings — the idle list included.
        guard settings.preferences.searchEngine.searchSuggestions.regularEnabled else {
            return []
        }

        let input = rawInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !input.isEmpty else { return idleSuggestions(privacyMode: privacyMode) }

        var results: [OmniboxSuggestion] = []
        var seen = Set<String>()
        let preferences = settings.preferences.searchEngine.searchSuggestions

        // 1. A direct URL, when the input already looks like one.
        if let url = BrowserUrlResolver.resolveDirectUrl(input) {
            let host = url.host ?? ""
            results.append(
                OmniboxSuggestion(
                    id: "url:\(url.absoluteString)",
                    kind: .url,
                    title: url.absoluteString,
                    subtitle: Self.isLanHost(host) ? "打开局域网地址" : "打开网址",
                    host: host,
                    completion: url.absoluteString
                )
            )
            seen.insert(url.absoluteString.lowercased())
        }

        // 2. Open tabs.
        if preferences.openTabsEnabled {
            for tab in tabManager.tabs where !tab.isHome {
                guard tab.privacyMode == privacyMode else { continue }
                let title = tab.displayTitle
                guard title.localizedCaseInsensitiveContains(input)
                    || tab.url.localizedCaseInsensitiveContains(input) else { continue }
                guard seen.insert("tab:\(tab.id)").inserted else { continue }
                results.append(
                    OmniboxSuggestion(
                        id: "tab:\(tab.id)",
                        kind: .openTab(tabId: tab.id),
                        title: title,
                        subtitle: "已打开的标签页",
                        host: tab.displayHost,
                        completion: tab.url
                    )
                )
                if results.count >= Limit.openTabs + 1 { break }
            }
        }

        // 3. Bookmarks.
        if preferences.bookmarksEnabled {
            for node in bookmarks.search(input).prefix(Limit.bookmarks) {
                let url = node.url ?? ""
                guard seen.insert("bookmark:\(node.id)").inserted else { continue }
                results.append(
                    OmniboxSuggestion(
                        id: "bookmark:\(node.id)",
                        kind: .bookmark(nodeId: node.id),
                        title: node.title,
                        subtitle: "书签 · \(node.displayHost)",
                        host: node.displayHost,
                        completion: url
                    )
                )
            }
        }

        // 4. Past queries.
        if preferences.historyEnabled {
            let pastQueries = (try? searchHistory.suggestions(
                prefix: input,
                profileId: browserMainProfileId,
                dataScope: privacyMode == .private ? .sessionEphemeral : .profilePersistent,
                limit: Limit.pastQueries
            )) ?? []
            for record in pastQueries {
                guard seen.insert("query:\(record.id)").inserted else { continue }
                results.append(
                    OmniboxSuggestion(
                        id: "query:\(record.id)",
                        kind: .pastQuery(queryId: record.id),
                        title: record.query,
                        subtitle: record.useCount > 1 ? "搜索记录 · \(record.useCount) 次" : "搜索记录",
                        host: "",
                        completion: record.query
                    )
                )
            }
        }

        // 5. Browsing history.
        if preferences.browsingHistoryEnabled {
            for entry in history.omniboxSuggestions(input).prefix(Limit.browsingHistory) {
                guard seen.insert("history:\(entry.id)").inserted else { continue }
                results.append(
                    OmniboxSuggestion(
                        id: "history:\(entry.id)",
                        kind: .history(urlId: entry.id),
                        title: entry.displayTitle,
                        subtitle: entry.displayHost,
                        host: entry.displayHost,
                        completion: entry.url,
                        accessoryText: entry.visitCount > 1 ? "\(entry.visitCount)" : nil
                    )
                )
            }
        }

        // 6. Search. Always last, and always present.
        let engine = settings.preferences.searchEngine.activeEngine
        results.append(
            OmniboxSuggestion(
                id: "search:\(engine.id)",
                kind: .search(engineId: engine.id),
                title: input,
                subtitle: "用 \(engine.name) 搜索",
                host: "",
                completion: input,
                accessoryText: engine.name
            )
        )

        // 6b. 联网搜索推荐. After the exact-query row, because that row is the
        // one return resolves and must not be displaced by a suggestion.
        for (index, raw) in remoteSuggestions.enumerated() {
            let title = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !title.isEmpty,
                  title.compare(input, options: .caseInsensitive) != .orderedSame else { continue }
            guard seen.insert("remote:\(title.lowercased())").inserted else { continue }
            results.append(
                OmniboxSuggestion(
                    id: "remote:\(engine.id):\(index)",
                    kind: .search(engineId: engine.id),
                    title: title,
                    subtitle: "联网搜索推荐",
                    host: "",
                    completion: title
                )
            )
        }

        return results
    }

    /// What the field offers before the user types.
    ///
    /// The field is focused the moment the omnibox opens, so an empty list would
    /// be a blank card — the recent queries are the honest answer to "what would
    /// I type".
    private func idleSuggestions(privacyMode: BrowserSessionPrivacyMode) -> [OmniboxSuggestion] {
        guard settings.preferences.searchEngine.searchSuggestions.historyEnabled else { return [] }
        let recent = (try? searchHistory.recent(
            profileId: browserMainProfileId,
            dataScope: privacyMode == .private ? .sessionEphemeral : .profilePersistent,
            limit: Limit.idleQueries
        )) ?? []

        return recent.map { record in
            OmniboxSuggestion(
                id: "query:\(record.id)",
                kind: .pastQuery(queryId: record.id),
                title: record.query,
                subtitle: "搜索记录",
                host: "",
                completion: record.query
            )
        }
    }

    /// Groups the list by section, dropping empty sections and preserving the
    /// priority order of `OmniboxSection.allCases`.
    func groups(
        for rawInput: String,
        privacyMode: BrowserSessionPrivacyMode,
        remoteSuggestions: [String] = []
    ) -> [OmniboxSuggestionGroup] {
        let all = suggestions(
            for: rawInput,
            privacyMode: privacyMode,
            remoteSuggestions: remoteSuggestions
        )
        guard !all.isEmpty else { return [] }

        return OmniboxSection.allCases.compactMap { section in
            let rows = all.filter { $0.section == section }
            return rows.isEmpty ? nil : OmniboxSuggestionGroup(section: section, suggestions: rows)
        }
    }

    /// True for `localhost`, a `.local` name, or an RFC 1918 address.
    ///
    /// Used only for the subtitle on the direct-access row: a user typing
    /// `192.168.1.1` is doing something different from a user typing a domain,
    /// and saying so is the cheapest way to make the row trustworthy.
    static func isLanHost(_ host: String) -> Bool {
        let value = host.lowercased()
        if value == "localhost" || value.hasSuffix(".local") { return true }
        let parts = value.split(separator: ".").compactMap { Int($0) }
        guard parts.count == 4 else { return false }
        if parts[0] == 10 || parts[0] == 127 { return true }
        if parts[0] == 192 && parts[1] == 168 { return true }
        if parts[0] == 172 && (16...31).contains(parts[1]) { return true }
        return false
    }
}

// MARK: - View model

/// The omnibox's observable state.
///
/// `OmniboxView` renders the field and nothing else; everything about what the
/// field *offers* lives here, which is what makes the list testable without a
/// window and keeps the shell out of the suggestion business.
@MainActor
@Observable
public final class OmniboxViewModel {

    // MARK: Input

    /// What is in the field.
    ///
    /// Setting it re-runs the suggestion pass behind the debounce — but only
    /// while the omnibox is open. Outside a session the field is just showing
    /// the page's address, and rebuilding a suggestion list nobody can see would
    /// be a database query per navigation.
    public var text: String = "" {
        didSet {
            guard text != oldValue, isEditing else { return }
            scheduleRefresh()
        }
    }

    /// Whether the omnibox is expanded over the page.
    public var isEditing: Bool = false

    /// The address of the page the omnibox is attached to. The shell keeps it
    /// current; it is what the field falls back to when a session ends without
    /// navigating.
    public var currentPageUrl: String = ""

    // MARK: Suggestions

    public private(set) var groups: [OmniboxSuggestionGroup] = []
    /// The privacy mode the current suggestion set was built for. The list
    /// uses it to keep a private host away from third-party icon services.
    public private(set) var activePrivacyMode: BrowserSessionPrivacyMode = .regular
    /// The rows of the expanded sections, in render order. Keyboard navigation
    /// walks this, so a collapsed section's rows are correctly unreachable.
    public private(set) var visibleSuggestions: [OmniboxSuggestion] = []
    /// The row the keyboard has selected. `nil` means "nothing selected", in
    /// which case return resolves the typed text the way it always has.
    public private(set) var highlightedId: String?

    /// Sections the user has explicitly collapsed or expanded.
    public private(set) var collapsedSections: Set<OmniboxSection> = []

    // MARK: Chrome

    public private(set) var clipboardHint: OmniboxClipboardHint?
    public private(set) var availableEngines: [SearchEngineRecord] = []
    public private(set) var activeEngineName: String = ""

    // MARK: Wiring

    /// Called when the user picks a row.
    public var onSelectSuggestion: ((OmniboxSuggestion) -> Void)?
    /// Called when return is pressed with no row highlighted.
    public var onCommitText: ((String) -> Void)?
    /// Called when the omnibox is dismissed without navigating.
    public var onCancel: (() -> Void)?

    private let engine: OmniboxSuggestionEngine
    private let settings: SettingsService
    private let searchHistory: SearchHistoryRepository
    private let history: HistoryService
    private let tabManager: TabManager
    private let suggestionClient: any SearchSuggestionProviding

    private var refreshTask: Task<Void, Never>?
    /// The 联网搜索推荐 request in flight. Cancelled on every new keystroke and
    /// when the session ends, so a slow answer cannot land on a newer query.
    private var remoteTask: Task<Void, Never>?
    /// False until the first non-empty input arrives, so the idle list is shown
    /// the instant the field focuses rather than after a debounce.
    private var hasLoadedOnce = false

    /// 100 ms is below the threshold where a list feels laggy, while still
    /// collapsing a fast typist's keystrokes into one query.
    private static let debounce: Duration = .milliseconds(100)

    /// The store the collapse state lives in.
    ///
    /// The key and the store are exactly what `@AppStorage` writes to, so the
    /// value is interchangeable with an `@AppStorage` property of the same name
    /// — the view model holds it because the *list* needs it as well as the
    /// view, and one owner is better than two.
    private static let collapseKey = "org.vela.browser.omnibox-collapsed-sections"

    init(
        settings: SettingsService,
        history: HistoryService,
        bookmarks: BookmarkService,
        searchHistory: SearchHistoryRepository,
        tabManager: TabManager,
        suggestionClient: (any SearchSuggestionProviding)? = nil
    ) {
        self.settings = settings
        self.history = history
        self.searchHistory = searchHistory
        self.tabManager = tabManager
        self.suggestionClient = suggestionClient ?? SearchSuggestionClient()
        self.engine = OmniboxSuggestionEngine(
            settings: settings,
            history: history,
            bookmarks: bookmarks,
            searchHistory: searchHistory,
            tabManager: tabManager
        )
        self.collapsedSections = Self.loadCollapsedSections()
        self.activeEngineName = settings.preferences.searchEngine.activeEngine.name
        self.availableEngines = settings.preferences.searchEngine.selectableEngines
    }

    // MARK: - Session

    /// Opens the omnibox over the current page.
    ///
    /// The field already holds the page's address and the field caret is
    /// selected on focus, which is what makes the omnibox usable one-handed:
    /// typing replaces the URL instead of appending to it.
    public func beginEditing() {
        guard !isEditing else { return }
        isEditing = true
        highlightedId = nil
        refreshEngines()
        // The idle list and the pasteboard check are both immediate: the user is
        // looking at an empty card at this moment, and a debounce's worth of
        // nothing would be visible.
        refreshNow()
        refreshClipboardHint()
    }

    /// Closes the omnibox and drops the session's transient state.
    ///
    /// The field is restored to the current page's address — not cleared to the
    /// placeholder, which is what the pre-refactor bar did and why the address
    /// of the page being read was never on screen.
    public func endEditing() {
        isEditing = false
        refreshTask?.cancel()
        refreshTask = nil
        remoteTask?.cancel()
        remoteTask = nil
        groups = []
        visibleSuggestions = []
        highlightedId = nil
        clipboardHint = nil
        hasLoadedOnce = false
        text = currentPageUrl
    }

    /// Cancels the session without navigating.
    public func cancel() {
        endEditing()
        onCancel?()
    }

    // MARK: - Input actions

    /// Return, or the Go key.
    public func submit() {
        if let id = highlightedId,
           let suggestion = visibleSuggestions.first(where: { $0.id == id }) {
            select(suggestion)
            return
        }
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return }
        onCommitText?(value)
    }

    /// Runs a row.
    public func select(_ suggestion: OmniboxSuggestion) {
        onSelectSuggestion?(suggestion)
    }

    /// Moves the highlight by `delta` rows.
    ///
    /// Moving above the first row clears the highlight rather than wrapping,
    /// which is the behaviour that lets a user get back to "just search what I
    /// typed" without reaching for the trackpad.
    public func moveHighlight(by delta: Int) {
        guard !visibleSuggestions.isEmpty else { return }
        guard let current = highlightedId,
              let index = visibleSuggestions.firstIndex(where: { $0.id == current }) else {
            highlightedId = delta > 0 ? visibleSuggestions.first?.id : nil
            return
        }
        let next = index + delta
        if next < 0 {
            highlightedId = nil
        } else if next >= visibleSuggestions.count {
            highlightedId = visibleSuggestions.last?.id
        } else {
            highlightedId = visibleSuggestions[next].id
        }
    }

    /// Replaces the field's contents — the paste affordance and the clear button
    /// both land here.
    public func setText(_ value: String) {
        text = value
    }

    /// Pastes and runs the result in one step.
    public func pasteAndSubmit(_ value: String) {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        text = trimmed
        onCommitText?(trimmed)
    }

    // MARK: - Sections

    /// Whether a section's rows are hidden.
    public func isCollapsed(_ section: OmniboxSection) -> Bool {
        collapsedSections.contains(section)
    }

    public func toggle(_ section: OmniboxSection) {
        if collapsedSections.contains(section) {
            collapsedSections.remove(section)
        } else {
            collapsedSections.insert(section)
        }
        persistCollapsedSections()
        rebuildVisibleSuggestions()
    }

    private func rebuildVisibleSuggestions() {
        visibleSuggestions = groups
            .filter { !collapsedSections.contains($0.section) }
            .flatMap(\.suggestions)

        // A highlight on a row that just disappeared would leave return doing
        // something the user cannot see.
        if let id = highlightedId, !visibleSuggestions.contains(where: { $0.id == id }) {
            highlightedId = nil
        }
    }

    // MARK: - Row actions

    /// Deletes a history row. Bookmarks and open tabs are not deletable this
    /// way; see `OmniboxSection.isDeletable`.
    public func delete(_ suggestion: OmniboxSuggestion) {
        switch suggestion.kind {
        case .pastQuery(let queryId):
            try? searchHistory.remove(id: queryId)
        case .history(let urlId):
            guard let entry = history.allVisited().first(where: { $0.id == urlId }) else { return }
            history.remove(entry)
        default:
            return
        }
        refreshNow()
    }

    /// Re-aims the session at a different engine.
    ///
    /// The switch is a choice that outlives the session: the engine becomes
    /// the default, the same thing picking a search row from the list does.
    /// It must not depend on a search row existing — with an empty field the
    /// idle list has none, and a switcher that only works after the user has
    /// typed is a switcher that fails at exactly the moment it is reached
    /// for. With an empty field the switch alone is the action: the query the
    /// user is about to type lands on the engine they just chose. With text
    /// in the field, that text runs on the new engine at once.
    public func switchEngine(to record: SearchEngineRecord) {
        if settings.preferences.searchEngine.activeEngine.id != record.id {
            settings.setDefaultSearchEngine(id: record.id)
        }
        refreshEngines()

        let query = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return }
        select(
            OmniboxSuggestion(
                id: "search:\(record.id)",
                kind: .search(engineId: record.id),
                title: query,
                subtitle: "用 \(record.name) 搜索",
                host: "",
                completion: query,
                accessoryText: record.name
            )
        )
    }

    // MARK: - Refresh

    private func refreshEngines() {
        availableEngines = settings.preferences.searchEngine.selectableEngines
        activeEngineName = settings.preferences.searchEngine.activeEngine.name
    }

    private func scheduleRefresh() {
        refreshTask?.cancel()
        let snapshot = text
        // The first keystroke is applied at once so the list never appears to
        // lag behind the keyboard; every keystroke after that is debounced.
        let immediate = !hasLoadedOnce
        refreshTask = Task { [weak self] in
            if !immediate {
                try? await Task.sleep(for: OmniboxViewModel.debounce)
                if Task.isCancelled { return }
            }
            guard let self else { return }
            self.apply(input: snapshot)
        }
    }

    /// Applies the suggestion pass now, cancelling any debounce in flight.
    private func refreshNow() {
        refreshTask?.cancel()
        refreshTask = nil
        apply(input: text)
    }

    private func apply(input: String) {
        hasLoadedOnce = true
        refreshEngines()

        let privacyMode = tabManager.activeTab?.privacyMode ?? .regular
        activePrivacyMode = privacyMode
        remoteTask?.cancel()
        remoteTask = nil
        groups = engine.groups(for: input, privacyMode: privacyMode)
        rebuildVisibleSuggestions()
        startRemoteSuggestions(for: input, privacyMode: privacyMode)
    }

    /// Starts the 联网搜索推荐 request for the text now in the field.
    ///
    /// One debounce longer than the local pass, because the network is the
    /// slow half and a fast typist's intermediate strings are not worth a
    /// request. The guards are the privacy contract: the switch must be on, the
    /// tab must be regular, and a URL the user typed is never sent to a search
    /// engine. A custom engine has no endpoint in the table and simply gets no
    /// recommendations.
    private func startRemoteSuggestions(for input: String, privacyMode: BrowserSessionPrivacyMode) {
        let query = input.trimmingCharacters(in: .whitespacesAndNewlines)
        let preferences = settings.preferences.searchEngine.searchSuggestions
        guard preferences.remoteEnabled,
              preferences.regularEnabled,
              privacyMode != .private,
              !query.isEmpty,
              BrowserUrlResolver.resolveDirectUrl(query) == nil else { return }

        let engineRecord = settings.preferences.searchEngine.activeEngine
        guard SearchSuggestionProvider(engineId: engineRecord.id) != nil else { return }

        remoteTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(180))
            guard !Task.isCancelled, let self else { return }

            let words = await self.suggestionClient.suggestions(
                for: query,
                engineId: engineRecord.id
            )
            guard !Task.isCancelled else { return }

            // The session can move on while a request is in flight: the user
            // types, switches engines, switches tabs into a private one, or
            // closes the omnibox. Only the answer to the query on screen may
            // be applied.
            guard self.isEditing,
                  self.text.trimmingCharacters(in: .whitespacesAndNewlines) == query,
                  self.settings.preferences.searchEngine.activeEngine.id == engineRecord.id,
                  self.settings.preferences.searchEngine.searchSuggestions.remoteEnabled,
                  (self.tabManager.activeTab?.privacyMode ?? .regular) == privacyMode else {
                return
            }

            self.groups = self.engine.groups(
                for: input,
                privacyMode: privacyMode,
                remoteSuggestions: words
            )
            self.rebuildVisibleSuggestions()
        }
    }

    // MARK: - Collapse persistence

    /// The sections the user has folded away by hand. Nothing is collapsed by
    /// default: every source the engine found rows for is shown, because a
    /// suggestion the user cannot see is indistinguishable from one that does
    /// not exist.
    private func persistCollapsedSections() {
        UserDefaults.standard.set(
            collapsedSections.map(\.rawValue).sorted(),
            forKey: Self.collapseKey
        )
    }

    private static func loadCollapsedSections() -> Set<OmniboxSection> {
        let raw = UserDefaults.standard.stringArray(forKey: collapseKey) ?? []
        return Set(raw.compactMap(OmniboxSection.init(rawValue:)))
    }

    // MARK: - Clipboard

    /// Classifies the pasteboard and, if there is something to offer, publishes
    /// the hint.
    ///
    /// `detectPatterns` is the only pasteboard read that does not raise the
    /// system paste prompt, because it reports *which patterns are present*
    /// rather than the contents. The contents are read later, by the
    /// `PasteButton` the hint renders.
    ///
    /// The completion-handler overload carries a "deprecated in iOS 15.0"
    /// warning with no replacement offered, and the SDK ships no async
    /// `detectPatterns(for:)` to move to — the compiler rejects one. Given that
    /// the alternative is a paste permission prompt on every focus, the warning
    /// is the cheaper half of the trade.
    private func refreshClipboardHint() {
        let pasteboard = UIPasteboard.general
        guard pasteboard.hasStrings else {
            clipboardHint = nil
            return
        }
        pasteboard.detectPatterns(for: [.probableWebURL]) { result in
            let isUrl: Bool
            switch result {
            case .success(let patterns): isUrl = patterns.contains(.probableWebURL)
            case .failure: isUrl = false
            }
            Task { @MainActor [weak self] in
                guard let self, self.isEditing else { return }
                self.clipboardHint = OmniboxClipboardHint.from(
                    hasProbableWebURL: isUrl,
                    // Re-read rather than trusting the check above: the
                    // detection is asynchronous, and the user can copy something
                    // else while it is in flight.
                    hasStrings: pasteboard.hasStrings
                )
            }
        }
    }
}
