//
//  SearchEngineCatalog.swift
//  Vela
//
//  The search engines the omnibox can use, and the shapes that identify their
//  result pages.
//
//  The result-page shapes drive the post-search fallback: after a search lands,
//  the shell checks whether the document really is a results page, and if it is
//  not it offers the next engine rather than leaving the user on a blank tab.
//  That is the whole mechanism behind a blocked or unreachable engine being
//  survivable.
//

import Foundation

public enum BuiltInSearchEngineId: String, Codable, Sendable, CaseIterable, Identifiable {
    case bing
    case google
    case duckduckgo
    case baidu
    case qihoo
    case sogou
    case shenma
    case brave
    case startpage
    case ecosia
    case yandex

    public var id: String { rawValue }
}

public typealias SearchEngineId = String

public enum SearchEngineKind: String, Codable, Sendable, CaseIterable {
    case builtIn = "built_in"
    case custom
}

public struct SearchEngineResultPageShape: Codable, Equatable, Sendable {
    public var hosts: [String]
    public var pathSuffixes: [String]
    public var queryKeys: [String]

    public init(hosts: [String], pathSuffixes: [String], queryKeys: [String]) {
        self.hosts = hosts
        self.pathSuffixes = pathSuffixes
        self.queryKeys = queryKeys
    }

    /// `BrowserQuickSearchContinuationService`. A navigation is a genuine result
    /// page when the host matches, the path matches, and the query still carries
    /// the search term under one of the engine's known keys.
    public func matches(_ url: URL) -> Bool {
        guard let host = url.host?.lowercased() else { return false }
        let hostMatches = hosts.contains { host == $0 || host.hasSuffix("." + $0) }
        guard hostMatches else { return false }

        let pathMatches = pathSuffixes.isEmpty || pathSuffixes.contains { url.path.hasSuffix($0) }
        guard pathMatches else { return false }

        guard !queryKeys.isEmpty else { return true }
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return false
        }
        let query = components.queryItems ?? []
        return query.contains { item in
            guard queryKeys.contains(item.name) else { return false }
            return !(item.value ?? "").isEmpty
        }
    }
}

public struct SearchEngineOption: Codable, Equatable, Sendable, Identifiable {
    public var id: SearchEngineId
    public var name: String
    public var searchUrlTemplate: String
    public var homepageUrl: String
    public var availabilityProbeUrl: String?
    public var availabilityExpectedStatus: Int?
    public var kind: SearchEngineKind
    public var isEditable: Bool
    public var resultPageShape: SearchEngineResultPageShape?

    public init(
        id: SearchEngineId,
        name: String,
        searchUrlTemplate: String,
        homepageUrl: String,
        availabilityProbeUrl: String? = nil,
        availabilityExpectedStatus: Int? = nil,
        kind: SearchEngineKind,
        isEditable: Bool,
        resultPageShape: SearchEngineResultPageShape? = nil
    ) {
        self.id = id
        self.name = name
        self.searchUrlTemplate = searchUrlTemplate
        self.homepageUrl = homepageUrl
        self.availabilityProbeUrl = availabilityProbeUrl
        self.availabilityExpectedStatus = availabilityExpectedStatus
        self.kind = kind
        self.isEditable = isEditable
        self.resultPageShape = resultPageShape
    }
}

public let searchEngineOptions: [SearchEngineOption] = [
    SearchEngineOption(
        id: "bing",
        name: "Bing",
        searchUrlTemplate: "https://www.bing.com/search?q={searchTerms}",
        homepageUrl: "https://www.bing.com",
        availabilityProbeUrl: "https://www.bing.com",
        kind: .builtIn,
        isEditable: false
    ),
    SearchEngineOption(
        id: "google",
        name: "Google",
        searchUrlTemplate: "https://www.google.com/search?q={searchTerms}",
        homepageUrl: "https://www.google.com",
        availabilityProbeUrl: "https://www.google.com/generate_204",
        availabilityExpectedStatus: 204,
        kind: .builtIn,
        isEditable: false
    ),
    SearchEngineOption(
        id: "duckduckgo",
        name: "DuckDuckGo",
        searchUrlTemplate: "https://duckduckgo.com/?q={searchTerms}",
        homepageUrl: "https://duckduckgo.com",
        kind: .builtIn,
        isEditable: false
    ),
    SearchEngineOption(
        id: "baidu",
        name: "Baidu",
        searchUrlTemplate: "https://www.baidu.com/s?wd={searchTerms}",
        homepageUrl: "https://www.baidu.com",
        availabilityProbeUrl: "https://www.baidu.com",
        kind: .builtIn,
        isEditable: false,
        resultPageShape: SearchEngineResultPageShape(
            hosts: ["baidu.com", "m.baidu.com"],
            pathSuffixes: ["/s"],
            queryKeys: ["wd", "word"]
        )
    ),
    SearchEngineOption(
        id: "qihoo",
        name: "360 搜索",
        searchUrlTemplate: "https://www.so.com/s?q={searchTerms}",
        homepageUrl: "https://www.so.com",
        kind: .builtIn,
        isEditable: false
    ),
    SearchEngineOption(
        id: "sogou",
        name: "搜狗",
        searchUrlTemplate: "https://www.sogou.com/web?query={searchTerms}",
        homepageUrl: "https://www.sogou.com",
        kind: .builtIn,
        isEditable: false
    ),
    SearchEngineOption(
        id: "shenma",
        name: "神马",
        searchUrlTemplate: "https://m.sm.cn/s?q={searchTerms}",
        homepageUrl: "https://m.sm.cn",
        kind: .builtIn,
        isEditable: false
    ),
    SearchEngineOption(
        id: "brave",
        name: "Brave Search",
        searchUrlTemplate: "https://search.brave.com/search?q={searchTerms}",
        homepageUrl: "https://search.brave.com",
        kind: .builtIn,
        isEditable: false
    ),
    SearchEngineOption(
        id: "startpage",
        name: "Startpage",
        searchUrlTemplate: "https://www.startpage.com/sp/search?query={searchTerms}",
        homepageUrl: "https://www.startpage.com",
        kind: .builtIn,
        isEditable: false
    ),
    SearchEngineOption(
        id: "ecosia",
        name: "Ecosia",
        searchUrlTemplate: "https://www.ecosia.org/search?q={searchTerms}",
        homepageUrl: "https://www.ecosia.org",
        kind: .builtIn,
        isEditable: false
    ),
    SearchEngineOption(
        id: "yandex",
        name: "Yandex",
        searchUrlTemplate: "https://yandex.com/search/?text={searchTerms}",
        homepageUrl: "https://yandex.com",
        kind: .builtIn,
        isEditable: false
    )
]

public let defaultSearchEngineId: SearchEngineId = SearchEngineSettings.defaultEngineId

public let defaultEnabledBuiltInSearchEngineIds: [BuiltInSearchEngineId] = [
    .bing, .google, .duckduckgo, .baidu, .yandex
]

/// A persisted engine row. Built-in engines are materialised into this shape on
/// first launch, so the settings list, the ordering and the custom-engine editor
/// all read one homogeneous collection.
public struct SearchEngineRecord: Codable, Equatable, Sendable, Identifiable {
    public var id: SearchEngineId
    public var kind: SearchEngineKind
    public var name: String
    public var searchUrlTemplate: String
    public var homepageUrl: String
    public var iconUrl: String?
    public var availabilityProbeUrl: String?
    public var availabilityExpectedStatus: Int?
    public var isEditable: Bool
    public var position: Int
    public var createdAt: Date
    public var updatedAt: Date

    public init(
        id: SearchEngineId,
        kind: SearchEngineKind,
        name: String,
        searchUrlTemplate: String,
        homepageUrl: String,
        iconUrl: String? = nil,
        availabilityProbeUrl: String? = nil,
        availabilityExpectedStatus: Int? = nil,
        isEditable: Bool,
        position: Int,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.kind = kind
        self.name = name
        self.searchUrlTemplate = searchUrlTemplate
        self.homepageUrl = homepageUrl
        self.iconUrl = iconUrl
        self.availabilityProbeUrl = availabilityProbeUrl
        self.availabilityExpectedStatus = availabilityExpectedStatus
        self.isEditable = isEditable
        self.position = position
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    /// Builds the persisted row for a built-in option.
    public init(option: SearchEngineOption, position: Int) {
        self.init(
            id: option.id,
            kind: option.kind,
            name: option.name,
            searchUrlTemplate: option.searchUrlTemplate,
            homepageUrl: option.homepageUrl,
            iconUrl: nil,
            availabilityProbeUrl: option.availabilityProbeUrl,
            availabilityExpectedStatus: option.availabilityExpectedStatus,
            isEditable: option.isEditable,
            position: position
        )
    }

    public var resultPageShape: SearchEngineResultPageShape? {
        searchEngineOptions.first { $0.id == id }?.resultPageShape
    }

    /// Substitutes `{searchTerms}` with a percent-encoded query.
    ///
    /// A custom engine whose template lacks the placeholder cannot express a
    /// query, so it is treated as unavailable rather than silently searched.
    ///
    /// `%` is removed from the allowed set along with the delimiters. It is the
    /// one character in `urlQueryAllowed` that cannot be passed through: a query
    /// containing `%20` means the four characters `%`, `2`, `0`, not a space, and
    /// leaving it alone would both send the wrong term and produce a URL a
    /// template's own `%` escapes collide with. Encoding it costs nothing and
    /// makes the substitution idempotent.
    public func searchUrl(for query: String) -> URL? {
        guard searchUrlTemplate.contains("{searchTerms}") else { return nil }
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "&+=?#%")
        guard let encoded = query.addingPercentEncoding(withAllowedCharacters: allowed) else {
            return nil
        }
        let expanded = searchUrlTemplate.replacingOccurrences(of: "{searchTerms}", with: encoded)
        return URL(string: expanded)
    }
}

public struct SearchSuggestionPreferences: Codable, Equatable, Sendable {
    public var regularEnabled: Bool
    public var privateEnabled: Bool
    public var openTabsEnabled: Bool
    public var bookmarksEnabled: Bool
    public var historyEnabled: Bool
    public var browsingHistoryEnabled: Bool
    public var navigationSuggestionsChosen: Bool
    /// Remote (network) suggestions. Off by default: nothing here sends
    /// keystrokes to a search provider unless the user opts in.
    public var remoteEnabled: Bool

    public init(
        regularEnabled: Bool = true,
        privateEnabled: Bool = false,
        openTabsEnabled: Bool = true,
        bookmarksEnabled: Bool = true,
        historyEnabled: Bool = true,
        browsingHistoryEnabled: Bool = true,
        navigationSuggestionsChosen: Bool = false,
        remoteEnabled: Bool = false
    ) {
        self.regularEnabled = regularEnabled
        self.privateEnabled = privateEnabled
        self.openTabsEnabled = openTabsEnabled
        self.bookmarksEnabled = bookmarksEnabled
        self.historyEnabled = historyEnabled
        self.browsingHistoryEnabled = browsingHistoryEnabled
        self.navigationSuggestionsChosen = navigationSuggestionsChosen
        self.remoteEnabled = remoteEnabled
    }

    public static let `default` = SearchSuggestionPreferences()
}

public struct SearchEngineFallbackSettings: Codable, Equatable, Sendable {
    public var enabled: Bool
    public var fallbackSearchEngineId: SearchEngineId
    public var noticeEnabled: Bool

    public init(
        enabled: Bool = true,
        fallbackSearchEngineId: SearchEngineId = "duckduckgo",
        noticeEnabled: Bool = true
    ) {
        self.enabled = enabled
        self.fallbackSearchEngineId = fallbackSearchEngineId
        self.noticeEnabled = noticeEnabled
    }

    public static let `default` = SearchEngineFallbackSettings()
}

public struct SearchEngineSettings: Codable, Equatable, Sendable {
    public var defaultSearchEngineId: SearchEngineId
    public var builtInEngineOrder: [SearchEngineId]
    public var enabledBuiltInEngineIds: [SearchEngineId]
    public var customEngines: [SearchEngineRecord]
    public var searchSuggestions: SearchSuggestionPreferences
    public var fallbackSearch: SearchEngineFallbackSettings
    public var updatedAt: Date

    /// The engine selected on first launch.
    ///
    /// Held on the type as well as in the module-level `DEFAULT_SEARCH_ENGINE_ID`
    /// port below, because an initialiser default argument cannot refer to a
    /// global that shares its name with the property being initialised — the
    /// property wins the name lookup.
    public static let defaultEngineId: SearchEngineId = "bing"

    public init(
        defaultSearchEngineId: SearchEngineId = SearchEngineSettings.defaultEngineId,
        builtInEngineOrder: [SearchEngineId] = searchEngineOptions.map(\.id),
        enabledBuiltInEngineIds: [SearchEngineId] = defaultEnabledBuiltInSearchEngineIds.map(\.rawValue),
        customEngines: [SearchEngineRecord] = [],
        searchSuggestions: SearchSuggestionPreferences = .default,
        fallbackSearch: SearchEngineFallbackSettings = .default,
        updatedAt: Date = Date()
    ) {
        self.defaultSearchEngineId = defaultSearchEngineId
        self.builtInEngineOrder = builtInEngineOrder
        self.enabledBuiltInEngineIds = enabledBuiltInEngineIds
        self.customEngines = customEngines
        self.searchSuggestions = searchSuggestions
        self.fallbackSearch = fallbackSearch
        self.updatedAt = updatedAt
    }

    public static let `default` = SearchEngineSettings()

    /// Every engine the user can pick, in display order: enabled built-ins
    /// (honouring the user's order) followed by custom engines.
    ///
    public var selectableEngines: [SearchEngineRecord] {
        let builtIns = searchEngineOptions
            .filter { enabledBuiltInEngineIds.contains($0.id) }
            .sorted { lhs, rhs in
                let li = builtInEngineOrder.firstIndex(of: lhs.id) ?? Int.max
                let ri = builtInEngineOrder.firstIndex(of: rhs.id) ?? Int.max
                return li < ri
            }
            .enumerated()
            .map { SearchEngineRecord(option: $0.element, position: $0.offset) }

        let customs = customEngines.sorted { $0.position < $1.position }
        return builtIns + customs
    }

    /// The active engine, falling back to the shipped default when the selected
    /// id no longer resolves — which is what happens when a custom engine is
    /// deleted while it is selected.
    public var activeEngine: SearchEngineRecord {
        if let selected = selectableEngines.first(where: { $0.id == defaultSearchEngineId }) {
            return selected
        }
        let fallbackId = defaultSearchEngineId
        if let builtIn = searchEngineOptions.first(where: { $0.id == fallbackId }) {
            return SearchEngineRecord(option: builtIn, position: 0)
        }
        return SearchEngineRecord(option: searchEngineOptions[0], position: 0)
    }

    public var fallbackEngine: SearchEngineRecord? {
        guard fallbackSearch.enabled else { return nil }
        guard fallbackSearch.fallbackSearchEngineId != defaultSearchEngineId else { return nil }
        if let found = selectableEngines.first(where: { $0.id == fallbackSearch.fallbackSearchEngineId }) {
            return found
        }
        if let builtIn = searchEngineOptions.first(where: { $0.id == fallbackSearch.fallbackSearchEngineId }) {
            return SearchEngineRecord(option: builtIn, position: 0)
        }
        return nil
    }
}

// MARK: - Search query history

public struct SearchQueryHistoryRecord: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var query: String
    public var normalizedQuery: String
    public var compactQuery: String
    public var searchEngineId: SearchEngineId
    public var useCount: Int
    public var firstSearchedAt: Date
    public var lastSearchedAt: Date
    public var profileId: BrowserProfileId
    public var dataScope: BrowserDataScope
}

/// Lowercased and whitespace-collapsed for `normalizedQuery`; whitespace removed
/// entirely for `compactQuery`, which is what makes "hello world" and
/// "helloworld" collapse into one suggestion.
public func normalizeSearchQuery(_ raw: String) -> (normalized: String, compact: String) {
    let collapsed = raw
        .trimmingCharacters(in: .whitespacesAndNewlines)
        .split(whereSeparator: { $0.isWhitespace })
        .joined(separator: " ")
    let normalized = collapsed.lowercased()
    let compact = normalized.filter { !$0.isWhitespace }
    return (normalized, compact)
}
