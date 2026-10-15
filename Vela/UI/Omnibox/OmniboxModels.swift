//
//  OmniboxModels.swift
//  Vela
//
//  The omnibox's value types: sections, rows, the matched-substring highlight
//  and the clipboard hint.
//
//  The list is grouped and collapsible, the matched substring is highlighted, and
//  every row carries the identity the delete and engine-switch gestures need.
//  Those three facts are what the types in this file exist to carry.
//

import SwiftUI

// MARK: - Sections

/// One group of suggestions.
///
/// The case order *is* the priority order: it is the order the suggestion
/// sources are merged in, and the order the card renders in.
public enum OmniboxSection: String, CaseIterable, Codable, Sendable, Identifiable {
    /// A URL the input already resolves to — including a LAN address.
    case directAccess
    case openTabs
    case bookmarks
    case searchHistory
    case browsingHistory
    /// Remote/engine suggestions. Always last: it is the only section that is
    /// always present, so putting it anywhere else would push real matches down.
    case search

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .directAccess: return "直接访问"
        case .openTabs: return "已打开标签"
        case .bookmarks: return "书签"
        case .searchHistory: return "搜索记录"
        case .browsingHistory: return "历史记录"
        case .search: return "搜索"
        }
    }

    public var symbolName: String {
        switch self {
        case .directAccess: return "arrow.up.forward.app"
        case .openTabs: return "square.on.square"
        case .bookmarks: return "bookmark.fill"
        case .searchHistory: return "magnifyingglass.circle"
        case .browsingHistory: return "clock.arrow.circlepath"
        case .search: return "magnifyingglass"
        }
    }

    /// Whether a row in this section can be swiped away.
    ///
    /// Only the two history sections: a bookmark is a deliberate save and an
    /// open tab is live state, so a swipe that silently deleted either would be
    /// a data loss the user did not ask for.
    public var isDeletable: Bool {
        switch self {
        case .searchHistory, .browsingHistory: return true
        default: return false
        }
    }

    /// Whether a row in this section can be re-run on a different engine.
    public var supportsEngineSwitch: Bool { self == .search }

    /// Sections that are never collapsed by the "first three with content"
    /// rule, because collapsing them would hide the input the user just typed.
    public var isPinnedOpen: Bool { self == .directAccess }
}

// MARK: - Suggestions

/// One row in the suggestion list.
public struct OmniboxSuggestion: Identifiable, Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        case search(engineId: SearchEngineId)
        case url
        case openTab(tabId: String)
        case bookmark(nodeId: String)
        case history(urlId: String)
        case pastQuery(queryId: String)

        /// The section a kind belongs to. Derived rather than stored, so a row
        /// can never disagree with the header it is drawn under.
        public var section: OmniboxSection {
            switch self {
            case .url: return .directAccess
            case .openTab: return .openTabs
            case .bookmark: return .bookmarks
            case .pastQuery: return .searchHistory
            case .history: return .browsingHistory
            case .search: return .search
            }
        }
    }

    public var id: String
    public var kind: Kind
    public var title: String
    public var subtitle: String
    public var host: String
    /// The string the omnibox inserts when the row is chosen.
    public var completion: String
    /// A short trailing label — the engine name on a search row, the visit
    /// count on a history row.
    public var accessoryText: String?

    public init(
        id: String,
        kind: Kind,
        title: String,
        subtitle: String,
        host: String,
        completion: String,
        accessoryText: String? = nil
    ) {
        self.id = id
        self.kind = kind
        self.title = title
        self.subtitle = subtitle
        self.host = host
        self.completion = completion
        self.accessoryText = accessoryText
    }

    public var section: OmniboxSection { kind.section }

    public var iconName: String {
        switch kind {
        case .search: return "magnifyingglass"
        case .url: return "globe"
        case .openTab: return "square.on.square"
        case .bookmark: return "bookmark.fill"
        case .history: return "clock.arrow.circlepath"
        case .pastQuery: return "magnifyingglass.circle"
        }
    }

    /// True when the row is a real destination rather than a search fallback.
    /// The list uses it to decide whether a row gets a favicon.
    public var hasSiteIdentity: Bool { !host.isEmpty }
}

/// A section with its rows, ready to render.
public struct OmniboxSuggestionGroup: Identifiable, Equatable, Sendable {
    public var section: OmniboxSection
    public var suggestions: [OmniboxSuggestion]

    public var id: String { section.rawValue }
    public var count: Int { suggestions.count }
}

// MARK: - Match highlighting

/// Builds the attributed strings the suggestion rows draw.
///
/// Splits a title on the query and renders the matching run in the accent
/// colour. Matching is *per token* rather than on the whole query, because the
/// query in the field is usually still being typed: with "git hu" the user wants
/// both runs marked, not neither.
enum OmniboxTextHighlighter {
    /// - Parameters:
    ///   - text: the string to draw.
    ///   - query: what the user has typed. Empty means "no highlighting".
    ///   - accent: the colour and weight applied to a matched run.
    ///   - base: the colour of everything else.
    ///   - font: the base font. A matched run is the same font at medium weight,
    ///     so highlighting never changes the line's metrics.
    static func highlighted(
        _ text: String,
        query: String,
        accent: Color,
        base: Color,
        font: Font
    ) -> AttributedString {
        let tokens = query
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .split(whereSeparator: { $0.isWhitespace })
            .map(String.init)
            .filter { !$0.isEmpty }

        guard !tokens.isEmpty, !text.isEmpty else { return plain(text, base: base, font: font) }

        let matches = mergedMatchRanges(in: text, tokens: tokens)
        guard !matches.isEmpty else { return plain(text, base: base, font: font) }

        var result = AttributedString()
        var cursor = text.startIndex

        for range in matches {
            if cursor < range.lowerBound {
                result.append(plain(String(text[cursor..<range.lowerBound]), base: base, font: font))
            }
            var run = AttributedString(String(text[range]))
            run.foregroundColor = accent
            run.font = font.weight(.medium)
            result.append(run)
            cursor = range.upperBound
        }

        if cursor < text.endIndex {
            result.append(plain(String(text[cursor...]), base: base, font: font))
        }
        return result
    }

    private static func plain(_ text: String, base: Color, font: Font) -> AttributedString {
        var piece = AttributedString(text)
        piece.foregroundColor = base
        piece.font = font
        return piece
    }

    /// Every occurrence of every token, sorted and de-overlapped.
    ///
    /// A run is capped: a one-letter query against a long URL would otherwise
    /// produce hundreds of segments for a line that shows forty characters.
    private static func mergedMatchRanges(in text: String, tokens: [String]) -> [Range<String.Index>] {
        var found: [Range<String.Index>] = []

        for token in tokens {
            guard token.count <= text.count else { continue }
            var searchStart = text.startIndex
            while searchStart < text.endIndex,
                  let range = text.range(
                      of: token,
                      options: [.caseInsensitive, .diacriticInsensitive],
                      range: searchStart..<text.endIndex
                  ) {
                found.append(range)
                searchStart = range.upperBound
                if found.count >= 64 { break }
            }
            if found.count >= 64 { break }
        }

        guard !found.isEmpty else { return [] }
        found.sort { $0.lowerBound < $1.lowerBound }

        var merged: [Range<String.Index>] = [found[0]]
        for range in found.dropFirst() {
            if let last = merged.last, range.lowerBound < last.upperBound {
                // Overlapping or touching: extend the run in place.
                merged[merged.count - 1] = last.lowerBound..<max(last.upperBound, range.upperBound)
            } else {
                merged.append(range)
            }
        }
        return merged
    }
}

// MARK: - Clipboard

/// What the paste affordance offers, decided from the pasteboard's *shape*.
///
/// Reading the pasteboard from code raises the system paste prompt, so the hint
/// is derived from `detectPatterns`, which
/// classifies the contents without revealing them, and the actual paste is
/// performed by SwiftUI's `PasteButton`, which is the one control the system
/// grants a prompt-free read to. Nothing is read, stored or sent until the user
/// taps the button.
public enum OmniboxClipboardHint: Equatable, Sendable {
    /// The pasteboard holds something the system classifies as a web address.
    case pasteAndGo
    /// The pasteboard holds text, which would be searched.
    case pasteAndSearch

    public var text: String {
        switch self {
        case .pasteAndGo: return "粘贴并前往"
        case .pasteAndSearch: return "粘贴并搜索"
        }
    }

    public var symbolName: String {
        switch self {
        case .pasteAndGo: return "doc.on.clipboard"
        case .pasteAndSearch: return "magnifyingglass"
        }
    }

    /// Classifies the pasteboard from the two facts that do not require reading
    /// it. `nil` means "show no affordance", which is the right answer on an
    /// empty clipboard.
    public static func from(hasProbableWebURL: Bool, hasStrings: Bool) -> OmniboxClipboardHint? {
        guard hasStrings else { return nil }
        return hasProbableWebURL ? .pasteAndGo : .pasteAndSearch
    }
}
