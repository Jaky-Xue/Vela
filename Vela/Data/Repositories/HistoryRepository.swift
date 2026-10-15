//
//  HistoryRepository.swift
//  Vela
//
//  Persistence for browsing history. Ported from
//  `AiraBrowser/entry/src/main/ets/data/repositories/` (history half) and
//  `data/database/BrowserDatabase.ets` (Aira Browser 3.7.4, GPL-3.0).
//
//  Every write takes a `BrowserDataBoundary` rather than reading privacy mode
//  off the calling tab. That is the port of ADR 0065 ("private browsing uses
//  effect policy"): a private session suppresses the write at the repository,
//  so no caller can forget the check.
//

import Foundation

public final class HistoryRepository: @unchecked Sendable {
    private let database: SQLiteDatabase

    public init(database: SQLiteDatabase) {
        self.database = database
    }

    private static let urlColumns = """
    id, url, normalized_url, url_hash, origin, host, title, visit_count, typed_count, \
    last_visit_at, hidden, favicon_key, created_at, updated_at
    """

    private static let visitColumns = """
    id, url_id, visited_at, from_visit_id, transition, visit_duration_ms, source, device_id, \
    session_id, profile_id, data_scope, sync_id, sync_account_uid, sync_origin
    """

    private func url(from statement: SQLiteStatement) -> HistoryUrl {
        HistoryUrl(
            id: statement.string(at: 0),
            url: statement.string(at: 1),
            normalizedUrl: statement.string(at: 2),
            urlHash: statement.string(at: 3),
            origin: statement.string(at: 4),
            host: statement.string(at: 5),
            title: statement.string(at: 6),
            visitCount: Int(statement.int(at: 7)),
            typedCount: Int(statement.int(at: 8)),
            lastVisitAt: Date(milliseconds: statement.int(at: 9)),
            hidden: statement.bool(at: 10),
            faviconKey: statement.string(at: 11),
            createdAt: Date(milliseconds: statement.int(at: 12)),
            updatedAt: Date(milliseconds: statement.int(at: 13))
        )
    }

    private func visit(from statement: SQLiteStatement) -> HistoryVisit {
        HistoryVisit(
            id: statement.string(at: 0),
            urlId: statement.string(at: 1),
            visitedAt: Date(milliseconds: statement.int(at: 2)),
            fromVisitId: statement.optionalString(at: 3),
            transition: HistoryTransition(rawValue: statement.string(at: 4)) ?? .link,
            visitDurationMs: Int(statement.int(at: 5)),
            source: statement.string(at: 6),
            deviceId: statement.string(at: 7),
            sessionId: statement.string(at: 8),
            profileId: statement.string(at: 9),
            dataScope: BrowserDataScope(rawValue: statement.string(at: 10)) ?? .profilePersistent,
            syncId: statement.string(at: 11),
            syncAccountUid: statement.string(at: 12),
            syncOrigin: statement.string(at: 13)
        )
    }

    // MARK: - Recording

    /// Records a page view.
    ///
    /// Ported from `BrowserHistoryVisitPersistenceCoordinator`. The visit row is
    /// the durable fact; the URL row is derived state that the same call upserts.
    /// A visit whose URL cannot be normalised (a `data:` or `javascript:` URL, a
    /// search-engine internal page) is dropped rather than stored unhashed,
    /// because the unique index on `url_hash` is what guarantees one row per URL.
    @discardableResult
    public func recordVisit(
        url rawUrl: String,
        title: String,
        transition: HistoryTransition = .link,
        boundary: BrowserDataBoundary,
        sessionId: String = "",
        fromVisitId: String? = nil
    ) throws -> HistoryUrl? {
        guard boundary.persists else { return nil }
        guard let normalized = HistoryUrlNormalizer.normalize(rawUrl),
              let parsed = URL(string: normalized) else { return nil }

        // Internal surfaces are not history. Ported from the guard in Aira's
        // visit coordinator, extended with Vela's own home scheme.
        let scheme = parsed.scheme?.lowercased() ?? ""
        guard scheme == "http" || scheme == "https" else { return nil }

        let hash = HistoryUrlNormalizer.hash(normalized)
        let now = Date()
        let host = parsed.host?.lowercased() ?? ""
        let origin = HistoryUrlNormalizer.origin(of: parsed)

        let existing = try database.query(
            "SELECT \(Self.urlColumns) FROM \(BrowserSchema.historyUrlsTable) WHERE url_hash = ?",
            [.text(hash)],
            row: url(from:)
        ).first

        let urlRow: HistoryUrl
        if var current = existing {
            current.visitCount += 1
            if transition.countsAsIntent { current.typedCount += 1 }
            current.lastVisitAt = now
            current.updatedAt = now
            // A page that only now reported a title keeps it; an empty title
            // never overwrites a known one.
            let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { current.title = trimmed }
            // Recording a visit un-hides the URL: visiting a page the user
            // previously deleted from history is a deliberate return.
            current.hidden = false
            urlRow = current

            try database.execute(
                """
                UPDATE \(BrowserSchema.historyUrlsTable)
                SET title = ?, visit_count = ?, typed_count = ?, last_visit_at = ?,
                    hidden = 0, updated_at = ?
                WHERE id = ?
                """,
                [
                    .text(current.title),
                    .integer(Int64(current.visitCount)),
                    .integer(Int64(current.typedCount)),
                    .integer(current.lastVisitAt.milliseconds),
                    .integer(now.milliseconds),
                    .text(current.id)
                ]
            )
        } else {
            let created = HistoryUrl(
                url: normalized,
                normalizedUrl: normalized,
                urlHash: hash,
                origin: origin,
                host: host,
                title: title.trimmingCharacters(in: .whitespacesAndNewlines),
                visitCount: 1,
                typedCount: transition.countsAsIntent ? 1 : 0,
                lastVisitAt: now,
                hidden: false,
                faviconKey: host,
                createdAt: now,
                updatedAt: now
            )
            urlRow = created
            try database.execute(
                """
                INSERT INTO \(BrowserSchema.historyUrlsTable) (\(Self.urlColumns))
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """,
                [
                    .text(created.id),
                    .text(created.url),
                    .text(created.normalizedUrl),
                    .text(created.urlHash),
                    .text(created.origin),
                    .text(created.host),
                    .text(created.title),
                    .integer(Int64(created.visitCount)),
                    .integer(Int64(created.typedCount)),
                    .integer(created.lastVisitAt.milliseconds),
                    .integer(0),
                    .text(created.faviconKey),
                    .integer(created.createdAt.milliseconds),
                    .integer(created.updatedAt.milliseconds)
                ]
            )
        }

        let visit = HistoryVisit(
            urlId: urlRow.id,
            visitedAt: now,
            fromVisitId: fromVisitId,
            transition: transition,
            source: "browser",
            sessionId: sessionId,
            profileId: boundary.profileId,
            dataScope: boundary.dataScope
        )
        try database.execute(
            """
            INSERT INTO \(BrowserSchema.historyVisitsTable) (\(Self.visitColumns))
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """,
            [
                .text(visit.id),
                .text(visit.urlId),
                .integer(visit.visitedAt.milliseconds),
                visit.fromVisitId.map { SQLiteValue.text($0) } ?? .null,
                .text(visit.transition.rawValue),
                .integer(Int64(visit.visitDurationMs)),
                .text(visit.source),
                .text(visit.deviceId),
                .text(visit.sessionId),
                .text(visit.profileId),
                .text(visit.dataScope.rawValue),
                .text(visit.syncId),
                .text(visit.syncAccountUid),
                .text(visit.syncOrigin)
            ]
        )

        // A transition from a known predecessor closes the duration of that
        // visit, which is how the history list shows time-on-page. Ported from
        // the duration backfill in the visit coordinator.
        if let fromVisitId {
            let elapsed = try database.query(
                "SELECT visited_at FROM \(BrowserSchema.historyVisitsTable) WHERE id = ?",
                [.text(fromVisitId)]
            ) { $0.int(at: 0) }.first
            if let elapsed {
                let duration = max(0, visit.visitedAt.milliseconds - elapsed)
                try database.execute(
                    """
                    UPDATE \(BrowserSchema.historyVisitsTable)
                    SET visit_duration_ms = ? WHERE id = ?
                    """,
                    [.integer(duration), .text(fromVisitId)]
                )
            }
        }

        try purgeIfNeeded(profileId: boundary.profileId)
        return urlRow
    }

    // MARK: - Reading

    /// Most recent live URL for a profile, newest first.
    public func recentUrls(profileId: BrowserProfileId, limit: Int = 500) throws -> [HistoryUrl] {
        try database.query(
            """
            SELECT \(Self.urlColumns) FROM \(BrowserSchema.historyUrlsTable)
            WHERE hidden = 0
            ORDER BY last_visit_at DESC LIMIT ?
            """,
            [.integer(Int64(limit))],
            row: url(from:)
        )
    }

    /// Groups recent history into day sections. Ported from the grouping in
    /// `HistoryManagerPage`.
    public func dayGroups(profileId: BrowserProfileId, limit: Int = 1000) throws -> [HistoryDayGroup] {
        let urls = try recentUrls(profileId: profileId, limit: limit)
        let calendar = Calendar.current
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"

        var buckets: [String: [HistoryUrl]] = [:]
        var dates: [String: Date] = [:]
        for url in urls {
            let day = calendar.startOfDay(for: url.lastVisitAt)
            let key = formatter.string(from: day)
            buckets[key, default: []].append(url)
            dates[key] = day
        }

        return buckets
            .map { HistoryDayGroup(dayKey: $0.key, date: dates[$0.key] ?? Date(), entries: $0.value) }
            .sorted { $0.dayKey > $1.dayKey }
    }

    /// Searches titles, URLs and hosts.
    public func search(_ query: String, profileId: BrowserProfileId, limit: Int = 200) throws -> [HistoryUrl] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        let pattern = "%\(trimmed.replacingOccurrences(of: "%", with: "\\%"))%"
        return try database.query(
            """
            SELECT \(Self.urlColumns) FROM \(BrowserSchema.historyUrlsTable)
            WHERE hidden = 0 AND (title LIKE ? OR url LIKE ? OR host LIKE ?)
            ORDER BY visit_count DESC, last_visit_at DESC LIMIT ?
            """,
            [.text(pattern), .text(pattern), .text(pattern), .integer(Int64(limit))],
            row: url(from:)
        )
    }

    /// The ranked suggestion set for the omnibox.
    ///
    /// Ported from the ranking in `BrowserSearchSuggestionCoordinator`: hosts
    /// the user typed or bookmarked outrank frequently-visited ones, and a URL
    /// whose host starts with the query outranks one that merely contains it.
    public func omniboxSuggestions(_ query: String, profileId: BrowserProfileId, limit: Int = 8) throws -> [HistoryUrl] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        let lower = trimmed.lowercased()
        let prefix = "\(lower)%"
        let contains = "%\(lower)%"

        return try database.query(
            """
            SELECT \(Self.urlColumns) FROM \(BrowserSchema.historyUrlsTable)
            WHERE hidden = 0 AND (LOWER(url) LIKE ? OR LOWER(title) LIKE ? OR LOWER(host) LIKE ?)
            ORDER BY
              CASE
                WHEN LOWER(host) LIKE ? THEN 0
                WHEN LOWER(host) LIKE ? THEN 1
                WHEN LOWER(title) LIKE ? THEN 2
                ELSE 3
              END,
              typed_count DESC,
              visit_count DESC,
              last_visit_at DESC
            LIMIT ?
            """,
            [
                .text(contains), .text(contains), .text(contains),
                .text(prefix), .text(contains), .text(prefix),
                .integer(Int64(limit))
            ],
            row: url(from:)
        )
    }

    public func visits(forUrlId urlId: String, limit: Int = 100) throws -> [HistoryVisit] {
        try database.query(
            """
            SELECT \(Self.visitColumns) FROM \(BrowserSchema.historyVisitsTable)
            WHERE url_id = ? ORDER BY visited_at DESC LIMIT ?
            """,
            [.text(urlId), .integer(Int64(limit))],
            row: visit(from:)
        )
    }

    /// The row id for a normalised URL, looked up by its hash.
    ///
    /// A dedicated query rather than a filtered scan of `recentUrls`: this runs
    /// on every page finish, and the `url_hash` unique index makes it a point
    /// lookup instead of reading a few hundred rows to find one.
    public func urlId(forUrl url: String) throws -> String? {
        guard let normalized = HistoryUrlNormalizer.normalize(url) else { return nil }
        let hash = HistoryUrlNormalizer.hash(normalized)
        return try database.query(
            "SELECT id FROM \(BrowserSchema.historyUrlsTable) WHERE url_hash = ? LIMIT 1",
            [.text(hash)]
        ) { $0.string(at: 0) }.first
    }

    public func title(forUrl url: String) throws -> String? {
        guard let normalized = HistoryUrlNormalizer.normalize(url) else { return nil }
        let hash = HistoryUrlNormalizer.hash(normalized)
        return try database.query(
            "SELECT title FROM \(BrowserSchema.historyUrlsTable) WHERE url_hash = ? LIMIT 1",
            [.text(hash)]
        ) { $0.string(at: 0) }.first
    }

    /// Writes a title onto an existing URL row without touching the counters.
    ///
    /// Separate from `recordVisit` because a page reports its title after the
    /// navigation commits: routing that through the visit path would increment
    /// `visit_count` a second time for one page view.
    public func updateTitle(urlId: String, title: String) throws {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        try database.execute(
            """
            UPDATE \(BrowserSchema.historyUrlsTable)
            SET title = ?, updated_at = ? WHERE id = ?
            """,
            [.text(trimmed), .integer(Date().milliseconds), .text(urlId)]
        )
    }

    public func count(profileId: BrowserProfileId) throws -> Int {
        Int(try database.scalarInt(
            "SELECT COUNT(*) FROM \(BrowserSchema.historyUrlsTable) WHERE hidden = 0"
        ))
    }

    // MARK: - Deleting

    /// Applies a removal at the scope the history UI asked for.
    ///
    /// Ported from the removal switch in Aira's history manager. `singleUrl`
    /// stamps `hidden` and keeps the visits — the visits are what a sync peer
    /// reconciles against, so removing them locally would look like new data on
    /// the next pull.
    public func remove(scope: HistoryRemovalScope, url: HistoryUrl? = nil, profileId: BrowserProfileId) throws {
        switch scope {
        case .singleUrl:
            guard let url else { return }
            try database.execute(
                """
                UPDATE \(BrowserSchema.historyUrlsTable)
                SET hidden = 1, updated_at = ? WHERE id = ?
                """,
                [.integer(Date().milliseconds), .text(url.id)]
            )

        case .host:
            guard let url else { return }
            let ids = try database.query(
                "SELECT id FROM \(BrowserSchema.historyUrlsTable) WHERE host = ?",
                [.text(url.host)]
            ) { $0.string(at: 0) }
            try database.transaction {
                for id in ids {
                    try database.execute(
                        "DELETE FROM \(BrowserSchema.historyVisitsTable) WHERE url_id = ?",
                        [.text(id)]
                    )
                    try database.execute(
                        "DELETE FROM \(BrowserSchema.historyUrlsTable) WHERE id = ?",
                        [.text(id)]
                    )
                }
            }

        case .day:
            guard let url else { return }
            let calendar = Calendar.current
            let start = calendar.startOfDay(for: url.lastVisitAt)
            guard let end = calendar.date(byAdding: .day, value: 1, to: start) else { return }
            try deleteRange(from: start, to: end)

        case .all:
            try database.transaction {
                try database.execute("DELETE FROM \(BrowserSchema.historyVisitsTable)")
                try database.execute("DELETE FROM \(BrowserSchema.historyUrlsTable)")
                try database.execute("DELETE FROM \(BrowserSchema.searchQueryHistoryTable)")
            }
        }
    }

    private func deleteRange(from start: Date, to end: Date) throws {
        let ids = try database.query(
            """
            SELECT id FROM \(BrowserSchema.historyUrlsTable)
            WHERE last_visit_at >= ? AND last_visit_at < ?
            """,
            [.integer(start.milliseconds), .integer(end.milliseconds)]
        ) { $0.string(at: 0) }
        try database.transaction {
            for id in ids {
                try database.execute(
                    "DELETE FROM \(BrowserSchema.historyVisitsTable) WHERE url_id = ?",
                    [.text(id)]
                )
                try database.execute(
                    "DELETE FROM \(BrowserSchema.historyUrlsTable) WHERE id = ?",
                    [.text(id)]
                )
            }
        }
    }

    /// Enforces the retention window.
    ///
    /// Ported from `RetentionRuntimePolicySettingsPage`. Retention is applied on
    /// write rather than on a timer because iOS gives no reliable background
    /// execution window for a maintenance task; pruning the tail of the history
    /// during a visit is bounded and needs no scheduler.
    private func purgeIfNeeded(profileId: BrowserProfileId) throws {
        let days = UserDefaults.standard.object(forKey: "org.vela.browser.history-retention-days") as? Int
        guard let days, days > 0 else { return }

        let cutoff = Calendar.current.date(byAdding: .day, value: -days, to: Date()) ?? Date()
        try database.transaction {
            let ids = try database.query(
                "SELECT id FROM \(BrowserSchema.historyUrlsTable) WHERE last_visit_at < ?",
                [.integer(cutoff.milliseconds)]
            ) { $0.string(at: 0) }
            for id in ids {
                try database.execute(
                    "DELETE FROM \(BrowserSchema.historyVisitsTable) WHERE url_id = ?",
                    [.text(id)]
                )
                try database.execute(
                    "DELETE FROM \(BrowserSchema.historyUrlsTable) WHERE id = ?",
                    [.text(id)]
                )
            }
        }
    }
}
