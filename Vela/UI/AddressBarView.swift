//
//  AddressBarView.swift
//  Vela
//
//  The omnibox. Ported from `AiraBrowser/entry/src/main/ets/core/browser/`
//  — `BrowserSearchSuggestionCoordinator.ets`, `BrowserAddressDisplayCoordinator.ets`,
//  `AddressDisplayFormatter.ets` and `BrowserRootAddressInputSessionCoordinator.ets`
//  (Aira Browser 3.7.4, GPL-3.0).
//
//  The suggestion list merges four sources in a fixed priority order, which is
//  the behaviour Aira's coordinator produces:
//
//    1. A URL the user is typing — always first, because it is what they mean.
//    2. Open tabs — cheapest to offer and most likely to be what a second tab
//       was opened for.
//    3. Bookmarks — a deliberate save, so it outranks mere history.
//    4. History and past queries, ranked by the repository's relevance score.
//
//  Remote suggestions are off by default and stay off unless the user enables
//  them: Aira Community does not send keystrokes to a provider, and neither does
//  Vela.
//

import SwiftUI
import UIKit

/// One row in the suggestion list.
struct OmniboxSuggestion: Identifiable, Equatable {
    enum Kind: Equatable {
        case search(engineId: SearchEngineId)
        case url
        case openTab(tabId: String)
        case bookmark(nodeId: String)
        case history(urlId: String)
        case pastQuery(queryId: String)
    }

    var id: String
    var kind: Kind
    var title: String
    var subtitle: String
    var host: String
    /// The string the omnibox inserts when the row is chosen.
    var completion: String

    var iconName: String {
        switch kind {
        case .search: return "magnifyingglass"
        case .url: return "globe"
        case .openTab: return "square.on.square"
        case .bookmark: return "bookmark.fill"
        case .history: return "clock.arrow.circlepath"
        case .pastQuery: return "magnifyingglass.circle"
        }
    }
}

/// Builds the suggestion list.
///
/// Ported from `BrowserSearchSuggestionCoordinator`. Kept as a pure function of
/// its inputs rather than a live observer so the omnibox can build a list for
/// the text currently in the field without debouncing against the store.
@MainActor
struct OmniboxSuggestionEngine {
    let settings: SettingsService
    let history: HistoryService
    let bookmarks: BookmarkService
    let searchHistory: SearchHistoryRepository
    let tabManager: TabManager

    func suggestions(for rawInput: String, privacyMode: BrowserSessionPrivacyMode) -> [OmniboxSuggestion] {
        let input = rawInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !input.isEmpty else { return [] }

        var results: [OmniboxSuggestion] = []
        var seen = Set<String>()
        let preferences = settings.preferences.searchEngine.searchSuggestions

        // 1. A direct URL, when the input already looks like one.
        if let url = BrowserUrlResolver.resolveDirectUrl(input) {
            results.append(
                OmniboxSuggestion(
                    id: "url:\(url.absoluteString)",
                    kind: .url,
                    title: url.absoluteString,
                    subtitle: "打开网址",
                    host: url.host ?? "",
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
            }
        }

        // 3. Bookmarks.
        if preferences.bookmarksEnabled {
            for node in bookmarks.search(input).prefix(4) {
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
                limit: 3
            )) ?? []
            for record in pastQueries {
                guard seen.insert("query:\(record.id)").inserted else { continue }
                results.append(
                    OmniboxSuggestion(
                        id: "query:\(record.id)",
                        kind: .pastQuery(queryId: record.id),
                        title: record.query,
                        subtitle: "搜索记录",
                        host: "",
                        completion: record.query
                    )
                )
            }
        }

        // 5. Browsing history.
        if preferences.browsingHistoryEnabled {
            for entry in history.omniboxSuggestions(input).prefix(5) {
                guard seen.insert("history:\(entry.id)").inserted else { continue }
                results.append(
                    OmniboxSuggestion(
                        id: "history:\(entry.id)",
                        kind: .history(urlId: entry.id),
                        title: entry.displayTitle,
                        subtitle: entry.displayHost,
                        host: entry.displayHost,
                        completion: entry.url
                    )
                )
            }
        }

        // 6. Search. Always last, and always present, so pressing return with no
        //    highlighted row does something predictable.
        let engine = settings.preferences.searchEngine.activeEngine
        results.append(
            OmniboxSuggestion(
                id: "search:\(engine.id)",
                kind: .search(engineId: engine.id),
                title: input,
                subtitle: "用 \(engine.name) 搜索",
                host: "",
                completion: input
            )
        )

        return results
    }
}

/// Turns typed text into a URL, or decides it is a query.
///
/// Ported from the resolution in `BrowserUnifiedLinkLogic` /
/// `BrowserAddressDisplayCoordinator`. The rules, in order:
///
/// * An input with a scheme Vela can load is a URL.
/// * An input with no spaces that contains a dot and a plausible TLD is a URL,
///   with `https://` assumed.
/// * A bare localhost or an IP address is a URL.
/// * Anything else is a search query.
enum BrowserUrlResolver {
    /// Schemes Vela will navigate to directly from the address bar.
    private static let loadableSchemes: Set<String> = ["http", "https", "file", "about", "data"]
    /// Schemes that are meaningful but are handed to the system rather than
    /// loaded, so typing one does not produce a blank page.
    static let externalSchemes: Set<String> = [
        "mailto", "tel", "sms", "facetime", "itms-apps", "alipays", "weixin", "taobao", "mqq"
    ]

    /// The URL an input resolves to, when it resolves to one.
    static func resolveDirectUrl(_ input: String) -> URL? {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        // An explicit loadable scheme wins outright.
        if let schemeRange = trimmed.range(of: "://") {
            let scheme = String(trimmed[trimmed.startIndex..<schemeRange.lowerBound]).lowercased()
            if loadableSchemes.contains(scheme) {
                return URL(string: trimmed)
            }
            if externalSchemes.contains(scheme) {
                return URL(string: trimmed)
            }
        }
        // `about:blank` and friends have no `://`.
        if trimmed.hasPrefix("about:") || trimmed.hasPrefix("data:") {
            return URL(string: trimmed)
        }

        // A single word with no dot is a query, not a host.
        let hasSpace = trimmed.contains(" ")
        guard !hasSpace else { return nil }

        // Strip a trailing slash-only path for the checks below.
        let candidate = trimmed.hasSuffix("/") ? String(trimmed.dropLast()) : trimmed
        guard !candidate.isEmpty else { return nil }

        // localhost and port, e.g. `localhost:8080` or `127.0.0.1:3000`.
        let hostPart = candidate.split(separator: "/").first.map(String.init) ?? candidate
        let hostWithoutPort = hostPart.split(separator: ":").first.map(String.init) ?? hostPart

        if hostWithoutPort == "localhost" { return URL(string: "http://\(candidate)") }
        if isIPv4(hostWithoutPort) { return URL(string: "http://\(candidate)") }
        // A bracketed IPv6 literal.
        if hostWithoutPort.hasPrefix("[") && hostWithoutPort.hasSuffix("]") {
            return URL(string: "http://\(candidate)")
        }

        guard hostWithoutPort.contains(".") else { return nil }
        // Reject a trailing dot or a leading dot, which are typos rather than
        // hosts, and reject a "TLD" of digits (a version number, not a domain).
        guard !hostWithoutPort.hasPrefix("."), !hostWithoutPort.hasSuffix(".") else { return nil }
        let tld = hostWithoutPort.split(separator: ".").last.map(String.init) ?? ""
        guard tld.count >= 2, tld.contains(where: { $0.isLetter }) else { return nil }

        return URL(string: "https://\(candidate)")
    }

    /// True when the input should be searched rather than navigated.
    static func isSearchQuery(_ input: String) -> Bool {
        resolveDirectUrl(input) == nil
    }

    private static func isIPv4(_ value: String) -> Bool {
        let parts = value.split(separator: ".")
        guard parts.count == 4 else { return false }
        return parts.allSatisfy { part in
            guard let number = Int(part), number >= 0, number <= 255 else { return false }
            return true
        }
    }

    /// The URL to load for an omnibox submission.
    ///
    /// Ported from the submit path in `BrowserShellSearchInvocationAdapter`.
    static func resolveNavigation(
        input: String,
        searchEngine: SearchEngineRecord
    ) -> URL? {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if let direct = resolveDirectUrl(trimmed) { return direct }
        return searchEngine.searchUrl(for: trimmed)
    }
}

/// The address bar.
///
/// Ported from `BrowserBottomAddressPanelViewModel`'s presentation: the phone
/// layout puts the address panel at the bottom, above the toolbar, so a
/// one-handed user can reach it. The editing state replaces the panel with a
/// full suggestion list.
struct AddressBarView: View {
    @Environment(\.browserPalette) private var palette

    @Binding var text: String
    @Binding var isEditing: Bool
    var isLoading: Bool
    var progress: Double
    var privacyMode: BrowserSessionPrivacyMode
    /// Shown instead of the URL when the field is not being edited.
    var displayUrl: String
    var onCommit: (String) -> Void
    var onCancel: () -> Void
    var onReload: () -> Void

    @FocusState private var isFocused: Bool

    var body: some View {
        HStack(spacing: 8) {
            // The lock is the only security indicator iOS exposes; WebKit
            // reports it through the page's URL scheme, so the badge is derived
            // from the URL rather than from a certificate inspection.
            Image(systemName: isSecure ? "lock.fill" : "globe")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(isSecure ? .green : .secondary)
                .frame(width: 14)

            TextField("搜索或输入网址", text: $text)
                .textFieldStyle(.plain)
                .font(.system(size: 15))
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .keyboardType(.URL)
                .submitLabel(.go)
                .focused($isFocused)
                .onSubmit {
                    let submitted = text
                    onCommit(submitted)
                }
                .onChange(of: isFocused) { _, focused in
                    isEditing = focused
                    if focused {
                        // Selecting everything is what makes the field usable
                        // one-handed: typing replaces the URL rather than
                        // appending to it.
                        text = displayUrl
                    } else {
                        text = ""
                    }
                }

            if isLoading {
                // A progress ring doubles as the stop button's slot, so the bar
                // does not change width while a page loads.
                ProgressRing(progress: progress)
                    .frame(width: 16, height: 16)
            } else if !displayUrl.isEmpty {
                Button {
                    onReload()
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 13, weight: .semibold))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 12)
        .frame(height: BrowserMetrics.addressBarHeight)
        .background(palette.chromeBackground, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private var isSecure: Bool {
        displayUrl.lowercased().hasPrefix("https://")
    }
}

/// A determinate progress ring.
///
/// Not `ProgressView(.circular)` because the built-in one ignores a fractional
/// value in its circular style on iOS and shows an indeterminate spinner, which
/// for a progress indicator is worse than showing nothing.
struct ProgressRing: View {
    var progress: Double
    var lineWidth: CGFloat = 2

    var body: some View {
        Circle()
            .trim(from: 0, to: max(0.02, min(1, progress)))
            .stroke(
                Color.accentColor,
                style: StrokeStyle(lineWidth: lineWidth, lineCap: .round)
            )
            .rotationEffect(.degrees(-90))
            .animation(.easeOut(duration: 0.15), value: progress)
    }
}
