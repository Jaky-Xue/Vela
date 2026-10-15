//
//  AdBlockModels.swift
//  Vela
//
//  The ad-block settings and rule-source model: subscribed lists, custom rules,
//  per-site exceptions and the statistics the settings screen reports.
//
//  Content blocking on iOS means `WKContentRuleList`, the only rule engine a
//  `WKWebView` permits, so this model describes what the user configured rather
//  than what any one engine can execute. See `AdBlockRuleCompiler` for the
//  Adblock Plus subset that maps onto WebKit's rule format, and for the syntax
//  that has no representation there.
//

import Foundation

public enum AdBlockCustomRuleSourceType: String, Codable, Sendable, CaseIterable {
    /// Shipped with the app.
    case system
    /// Fetched from a subscription URL.
    case remote
    /// Typed in by the user or imported from a file.
    case local
}

/// the protection statistics surface.
public enum AdBlockResourceType: String, Codable, Sendable, CaseIterable, Identifiable {
    case advertisement
    case tracker
    case social
    case annoyance
    case other

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .advertisement: return "广告"
        case .tracker: return "跟踪器"
        case .social: return "社交组件"
        case .annoyance: return "干扰元素"
        case .other: return "其他"
        }
    }
}

public struct AdBlockSiteException: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var host: String
    public var createdAt: Date

    public init(id: String = UUID().uuidString, host: String, createdAt: Date = Date()) {
        self.id = id
        self.host = host
        self.createdAt = createdAt
    }
}

public struct AdBlockCustomRuleSource: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var name: String
    public var url: String
    public var sourceType: AdBlockCustomRuleSourceType
    public var enabled: Bool
    public var ruleCount: Int
    public var lastUpdatedAt: Date?
    public var lastError: String

    public init(
        id: String = UUID().uuidString,
        name: String,
        url: String = "",
        sourceType: AdBlockCustomRuleSourceType,
        enabled: Bool = true,
        ruleCount: Int = 0,
        lastUpdatedAt: Date? = nil,
        lastError: String = ""
    ) {
        self.id = id
        self.name = name
        self.url = url
        self.sourceType = sourceType
        self.enabled = enabled
        self.ruleCount = ruleCount
        self.lastUpdatedAt = lastUpdatedAt
        self.lastError = lastError
    }

    /// The subscription list offered in settings. The ids are fixed so a user's
    /// selection survives an update to the app.
    public static let catalog: [AdBlockCustomRuleSource] = [
        AdBlockCustomRuleSource(
            id: "easylist-china",
            name: "EasyList China",
            url: "https://easylist-downloads.adblockplus.org/easylistchina.txt",
            sourceType: .remote
        ),
        AdBlockCustomRuleSource(
            id: "easylist",
            name: "EasyList",
            url: "https://easylist-downloads.adblockplus.org/easylist.txt",
            sourceType: .remote
        ),
        AdBlockCustomRuleSource(
            id: "easyprivacy",
            name: "EasyPrivacy",
            url: "https://easylist-downloads.adblockplus.org/easyprivacy.txt",
            sourceType: .remote
        ),
        AdBlockCustomRuleSource(
            id: "cjx-annoyance",
            name: "烦人元素清单",
            url: "https://raw.githubusercontent.com/cjx82630/cjxlist/master/cjx-annoyance.txt",
            sourceType: .remote
        )
    ]
}

public struct AdBlockStats: Codable, Equatable, Sendable {
    public var totalBlocked: Int
    public var todayBlocked: Int
    /// Milliseconds since the epoch of the last rule-list refresh.
    public var lastUpdatedAt: Date?
    public var byType: [String: Int]

    public init(
        totalBlocked: Int = 0,
        todayBlocked: Int = 0,
        lastUpdatedAt: Date? = nil,
        byType: [String: Int] = [:]
    ) {
        self.totalBlocked = totalBlocked
        self.todayBlocked = todayBlocked
        self.lastUpdatedAt = lastUpdatedAt
        self.byType = byType
    }

    public static let empty = AdBlockStats()

    public func count(for type: AdBlockResourceType) -> Int {
        byType[type.rawValue] ?? 0
    }
}

public struct AdBlockDailyProtectionActivity: Codable, Equatable, Sendable, Identifiable {
    public var id: String { dayKey }
    public var dayKey: String
    public var blockedCount: Int

    public init(dayKey: String, blockedCount: Int) {
        self.dayKey = dayKey
        self.blockedCount = blockedCount
    }
}

public struct AdBlockPreferences: Codable, Equatable, Sendable {
    public var enabled: Bool
    /// Cosmetic filtering (element hiding), the `##selector` half of a list.
    public var cosmeticFilteringEnabled: Bool
    /// Return an empty document instead of letting a known ad request resolve.
    public var blockDocumentRequests: Bool
    /// Allow listed hosts to load ads anyway.
    public var siteExceptions: [AdBlockSiteException]
    /// Rules the user typed in by hand.
    public var localRules: [String]

    public init(
        enabled: Bool = true,
        cosmeticFilteringEnabled: Bool = true,
        blockDocumentRequests: Bool = false,
        siteExceptions: [AdBlockSiteException] = [],
        localRules: [String] = []
    ) {
        self.enabled = enabled
        self.cosmeticFilteringEnabled = cosmeticFilteringEnabled
        self.blockDocumentRequests = blockDocumentRequests
        self.siteExceptions = siteExceptions
        self.localRules = localRules
    }

    public static let `default` = AdBlockPreferences()

    public func isExcepted(host: String) -> Bool {
        let normalized = host.lowercased()
        return siteExceptions.contains { exception in
            let candidate = exception.host.lowercased()
            return candidate == normalized || normalized.hasSuffix("." + candidate)
        }
    }
}

public struct AdBlockSettings: Codable, Equatable, Sendable {
    public var preferences: AdBlockPreferences
    public var ruleSources: [AdBlockCustomRuleSource]
    public var stats: AdBlockStats
    public var updatedAt: Date

    public init(
        preferences: AdBlockPreferences = .default,
        ruleSources: [AdBlockCustomRuleSource] = [],
        stats: AdBlockStats = .empty,
        updatedAt: Date = Date()
    ) {
        self.preferences = preferences
        self.ruleSources = ruleSources
        self.stats = stats
        self.updatedAt = updatedAt
    }

    public static let `default` = AdBlockSettings()

    /// Sources that should currently contribute rules, in a stable order:
    /// the built-in list first, then enabled subscriptions, then local rules.
    public var activeSources: [AdBlockCustomRuleSource] {
        ruleSources.filter(\.enabled).sorted { lhs, rhs in
            if lhs.sourceType == rhs.sourceType { return lhs.name < rhs.name }
            return lhs.sourceType == .system
        }
    }
}

/// One entry per element the user pointed
/// at with the element picker.
public struct ManualElementHideRule: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var selector: String
    public var createdAt: Date

    public init(id: String = UUID().uuidString, selector: String, createdAt: Date = Date()) {
        self.id = id
        self.selector = selector
        self.createdAt = createdAt
    }
}

public struct ManualElementHideSiteRules: Codable, Equatable, Sendable, Identifiable {
    public var id: String { host }
    public var host: String
    public var rules: [ManualElementHideRule]

    public init(host: String, rules: [ManualElementHideRule] = []) {
        self.host = host
        self.rules = rules
    }
}

public struct ManualElementHideSettings: Codable, Equatable, Sendable {
    public var sites: [ManualElementHideSiteRules]

    public init(sites: [ManualElementHideSiteRules] = []) {
        self.sites = sites
    }

    public static let `default` = ManualElementHideSettings()

    public func rules(for host: String) -> [ManualElementHideRule] {
        sites.first { $0.host == host }?.rules ?? []
    }

    /// Every selector that applies to `host`, including hosts that are a suffix
    /// of it — a rule added on `news.example.com` also applies to a subdomain.
    public func effectiveSelectors(for host: String) -> [String] {
        let normalized = host.lowercased()
        return sites
            .filter { normalized == $0.host || normalized.hasSuffix("." + $0.host) }
            .flatMap { $0.rules.map(\.selector) }
    }
}
