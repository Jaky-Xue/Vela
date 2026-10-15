//
//  HistoryModels.swift
//  Vela
//
//  The history model: one row per URL, one row per visit, and the day grouping
//  the history list renders.
//
//  Splitting the URL row from the visit row is what lets the list group by day
//  without a self-join and makes the visit counter a cheap ordering key. The URL
//  row carries the title and the count; the visit row carries the time and the
//  transition it arrived by, which is what gives the list its time-on-page.
//

import Foundation

/// How a visit was arrived at. The set matches Chromium's transition taxonomy,
/// which is what makes a history import from a desktop browser round-trip.
public enum HistoryTransition: String, Codable, Sendable, CaseIterable {
    case link
    case typed
    case autoBookmark = "auto_bookmark"
    case autoSubframe = "auto_subframe"
    case manualSubframe = "manual_subframe"
    case generated
    case autoToplevel = "auto_toplevel"
    case formSubmit = "form_submit"
    case reload
    case keyword
    case keywordGenerated = "keyword_generated"
    /// Navigations restored from the saved session. The restore path writes a
    /// visit, so it has to be distinguishable from a user-initiated load in the
    /// history list.
    case restore

    public var displayName: String {
        switch self {
        case .link: return "链接"
        case .typed: return "地址栏"
        case .autoBookmark: return "书签"
        case .autoSubframe, .manualSubframe: return "子框架"
        case .generated: return "生成"
        case .autoToplevel: return "自动跳转"
        case .formSubmit: return "表单提交"
        case .reload: return "刷新"
        case .keyword, .keywordGenerated: return "关键词"
        case .restore: return "会话恢复"
        }
    }

    /// True when the navigation says something about intent, which is what
    /// drives the "常访问" ranking in the omnibox.
    public var countsAsIntent: Bool {
        switch self {
        case .typed, .keyword, .autoBookmark, .formSubmit: return true
        default: return false
        }
    }
}

/// Ported from the `history_urls` row.
public struct HistoryUrl: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var url: String
    public var normalizedUrl: String
    public var urlHash: String
    public var origin: String
    public var host: String
    public var title: String
    public var visitCount: Int
    public var typedCount: Int
    public var lastVisitAt: Date
    /// Ported from the `hidden` column: the history manager's soft delete.
    public var hidden: Bool
    public var faviconKey: String
    public var createdAt: Date
    public var updatedAt: Date

    public init(
        id: String = UUID().uuidString,
        url: String,
        normalizedUrl: String,
        urlHash: String,
        origin: String,
        host: String,
        title: String,
        visitCount: Int = 1,
        typedCount: Int = 0,
        lastVisitAt: Date = Date(),
        hidden: Bool = false,
        faviconKey: String = "",
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.url = url
        self.normalizedUrl = normalizedUrl
        self.urlHash = urlHash
        self.origin = origin
        self.host = host
        self.title = title
        self.visitCount = visitCount
        self.typedCount = typedCount
        self.lastVisitAt = lastVisitAt
        self.hidden = hidden
        self.faviconKey = faviconKey
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    public var displayTitle: String {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { return trimmed }
        return host
    }

    public var displayHost: String {
        host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }
}

/// Ported from the `history_visits` row.
public struct HistoryVisit: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var urlId: String
    public var visitedAt: Date
    /// The visit the user came from, when there was one.
    public var fromVisitId: String?
    public var transition: HistoryTransition
    public var visitDurationMs: Int
    public var source: String
    public var deviceId: String
    public var sessionId: String
    public var profileId: BrowserProfileId
    public var dataScope: BrowserDataScope
    /// Non-empty on a synced visit; the partial unique index keys off it.
    public var syncId: String
    public var syncAccountUid: String
    public var syncOrigin: String

    public init(
        id: String = UUID().uuidString,
        urlId: String,
        visitedAt: Date = Date(),
        fromVisitId: String? = nil,
        transition: HistoryTransition = .link,
        visitDurationMs: Int = 0,
        source: String = "browser",
        deviceId: String = BrowserIdentity.deviceId,
        sessionId: String = "",
        profileId: BrowserProfileId = browserMainProfileId,
        dataScope: BrowserDataScope = .profilePersistent,
        syncId: String = "",
        syncAccountUid: String = "",
        syncOrigin: String = ""
    ) {
        self.id = id
        self.urlId = urlId
        self.visitedAt = visitedAt
        self.fromVisitId = fromVisitId
        self.transition = transition
        self.visitDurationMs = visitDurationMs
        self.source = source
        self.deviceId = deviceId
        self.sessionId = sessionId
        self.profileId = profileId
        self.dataScope = dataScope
        self.syncId = syncId
        self.syncAccountUid = syncAccountUid
        self.syncOrigin = syncOrigin
    }
}

/// A URL joined with its visit times — the shape `HistoryManagerPage` groups by
/// day. Ported from `BrowserHistoryVisitPersistenceCoordinator`'s read model.
public struct HistoryDayGroup: Identifiable, Sendable {
    public var id: String { dayKey }
    public var dayKey: String
    public var date: Date
    public var entries: [HistoryUrl]

    public init(dayKey: String, date: Date, entries: [HistoryUrl]) {
        self.dayKey = dayKey
        self.date = date
        self.entries = entries
    }

    /// The section header text: "今天", "昨天", or a date.
    public var displayTitle: String {
        let calendar = Calendar.current
        if calendar.isDateInToday(date) { return "今天" }
        if calendar.isDateInYesterday(date) { return "昨天" }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = calendar.component(.year, from: date) == calendar.component(.year, from: Date())
            ? "M月d日 EEEE"
            : "yyyy年M月d日"
        return formatter.string(from: date)
    }
}

/// Ported from `HistoryRemovalScope` — what "删除" means at each level of the
/// history UI.
public enum HistoryRemovalScope: String, Codable, Sendable, CaseIterable {
    /// Soft-delete one URL: hide it, keep its visits so a sync peer learns about
    /// the deletion through the tombstone.
    case singleUrl = "single_url"
    /// Hard-delete every visit for a host.
    case host
    /// Hard-delete everything in a day.
    case day
    case all
}

/// The normalisation applied before a URL is hashed.
///
/// The hash is what enforces one row per URL, so the normalisation has to be
/// stable: lowercase scheme and host, drop a default port, drop the fragment,
/// drop a trailing slash on a bare path, and keep the query. Anything that
/// keeps a fragment here would make `page` and `page#section` two history rows.
public enum HistoryUrlNormalizer {
    public static func normalize(_ rawUrl: String) -> String? {
        guard var components = URLComponents(string: rawUrl) else { return nil }
        guard let scheme = components.scheme?.lowercased(), scheme == "http" || scheme == "https" else {
            return nil
        }
        components.scheme = scheme
        components.host = components.host?.lowercased()
        components.fragment = nil
        components.user = nil
        components.password = nil

        if let port = components.port, (scheme == "http" && port == 80) || (scheme == "https" && port == 443) {
            components.port = nil
        }
        if components.path == "/" {
            components.path = ""
        }
        components.path = components.path.removingPercentEncoding.map { encodePath($0) } ?? components.path

        var normalized = components.string ?? rawUrl
        while normalized.hasSuffix("?") || normalized.hasSuffix("#") {
            normalized.removeLast()
        }
        return normalized
    }

    private static func encodePath(_ path: String) -> String {
        path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? path
    }

    /// A stable 64-bit hash rendered as hex. Ported from the `url_hash` column.
    /// FNV-1a is used rather than Swift's `hashValue` because the latter is
    /// seeded per process and would produce a different hash on every launch,
    /// breaking the unique index.
    public static func hash(_ value: String) -> String {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in value.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01b3
        }
        return String(hash, radix: 16)
    }

    public static func origin(of url: URL) -> String {
        guard let scheme = url.scheme, let host = url.host else { return "" }
        if let port = url.port {
            return "\(scheme)://\(host):\(port)"
        }
        return "\(scheme)://\(host)"
    }
}
