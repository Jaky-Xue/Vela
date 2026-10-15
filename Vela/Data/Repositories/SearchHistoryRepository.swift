//
//  SearchHistoryRepository.swift
//  Vela
//
//  Persistence for the omnibox query log. Ported from the
//  `search_query_history` table and its readers in
//  `AiraBrowser/entry/src/main/ets/data/database/BrowserDatabase.ets`
//  (Aira Browser 3.7.4, GPL-3.0).
//
//  The three stored normalisations (verbatim, lowercased, whitespace-stripped)
//  exist so omnibox matching can be exact, case-insensitive and
//  whitespace-insensitive without a per-query collation. `use_count` is what
//  ranks the suggestion list.
//

import Foundation

public final class SearchHistoryRepository: @unchecked Sendable {
    private let database: SQLiteDatabase

    public init(database: SQLiteDatabase) {
        self.database = database
    }

    private static let columns = """
    id, query, normalized_query, compact_query, search_engine_id, use_count, \
    first_searched_at, last_searched_at, profile_id, data_scope
    """

    private func record(from statement: SQLiteStatement) -> SearchQueryHistoryRecord {
        SearchQueryHistoryRecord(
            id: statement.string(at: 0),
            query: statement.string(at: 1),
            normalizedQuery: statement.string(at: 2),
            compactQuery: statement.string(at: 3),
            searchEngineId: statement.string(at: 4),
            useCount: Int(statement.int(at: 5)),
            firstSearchedAt: Date(milliseconds: statement.int(at: 6)),
            lastSearchedAt: Date(milliseconds: statement.int(at: 7)),
            profileId: statement.string(at: 8),
            dataScope: BrowserDataScope(rawValue: statement.string(at: 9)) ?? .profilePersistent
        )
    }

    /// Records a query, incrementing the counter when the same query has been
    /// run before. Ported from the upsert in `SearchEngineSelectionService`.
    public func record(
        query: String,
        searchEngineId: SearchEngineId,
        boundary: BrowserDataBoundary
    ) throws {
        guard boundary.persists else { return }
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        let (normalized, compact) = normalizeSearchQuery(trimmed)
        let now = Date()

        let existing = try database.query(
            """
            SELECT \(Self.columns) FROM \(BrowserSchema.searchQueryHistoryTable)
            WHERE profile_id = ? AND data_scope = ? AND normalized_query = ?
            LIMIT 1
            """,
            [.text(boundary.profileId), .text(boundary.dataScope.rawValue), .text(normalized)],
            row: record(from:)
        ).first

        if var current = existing {
            current.useCount += 1
            current.lastSearchedAt = now
            // The most recent spelling wins: a user who corrects a typo should
            // see the corrected form suggested, not the original.
            current.query = trimmed
            current.searchEngineId = searchEngineId
            try database.execute(
                """
                UPDATE \(BrowserSchema.searchQueryHistoryTable)
                SET query = ?, compact_query = ?, search_engine_id = ?,
                    use_count = ?, last_searched_at = ?
                WHERE id = ?
                """,
                [
                    .text(current.query),
                    .text(compact),
                    .text(current.searchEngineId),
                    .integer(Int64(current.useCount)),
                    .integer(current.lastSearchedAt.milliseconds),
                    .text(current.id)
                ]
            )
        } else {
            try database.execute(
                """
                INSERT INTO \(BrowserSchema.searchQueryHistoryTable) (\(Self.columns))
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """,
                [
                    .text(UUID().uuidString),
                    .text(trimmed),
                    .text(normalized),
                    .text(compact),
                    .text(searchEngineId),
                    .integer(1),
                    .integer(now.milliseconds),
                    .integer(now.milliseconds),
                    .text(boundary.profileId),
                    .text(boundary.dataScope.rawValue)
                ]
            )
        }
    }

    /// Query completions ranked by use count then recency.
    ///
    /// Ported from the suggestion read in `BrowserSearchSuggestionCoordinator`.
    /// Matching runs against both normalisations so "hello world" matches a
    /// stored "helloworld" and vice versa.
    public func suggestions(
        prefix: String,
        profileId: BrowserProfileId,
        dataScope: BrowserDataScope,
        limit: Int = 6
    ) throws -> [SearchQueryHistoryRecord] {
        let trimmed = prefix.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        let (normalized, compact) = normalizeSearchQuery(trimmed)
        let normalizedPattern = "%\(normalized)%"
        let compactPattern = "%\(compact)%"

        return try database.query(
            """
            SELECT \(Self.columns) FROM \(BrowserSchema.searchQueryHistoryTable)
            WHERE profile_id = ? AND data_scope = ?
              AND (normalized_query LIKE ? OR compact_query LIKE ?)
            ORDER BY use_count DESC, last_searched_at DESC
            LIMIT ?
            """,
            [
                .text(profileId),
                .text(dataScope.rawValue),
                .text(normalizedPattern),
                .text(compactPattern),
                .integer(Int64(limit))
            ],
            row: record(from:)
        )
    }

    /// The most recent queries, shown before the user has typed anything.
    public func recent(
        profileId: BrowserProfileId,
        dataScope: BrowserDataScope,
        limit: Int = 6
    ) throws -> [SearchQueryHistoryRecord] {
        try database.query(
            """
            SELECT \(Self.columns) FROM \(BrowserSchema.searchQueryHistoryTable)
            WHERE profile_id = ? AND data_scope = ?
            ORDER BY last_searched_at DESC LIMIT ?
            """,
            [.text(profileId), .text(dataScope.rawValue), .integer(Int64(limit))],
            row: record(from:)
        )
    }

    /// Removes one query. Ported from the per-row delete in the omnibox.
    public func remove(id: String) throws {
        try database.execute(
            "DELETE FROM \(BrowserSchema.searchQueryHistoryTable) WHERE id = ?",
            [.text(id)]
        )
    }

    public func removeAll(profileId: BrowserProfileId) throws {
        try database.execute(
            "DELETE FROM \(BrowserSchema.searchQueryHistoryTable) WHERE profile_id = ?",
            [.text(profileId)]
        )
    }
}
