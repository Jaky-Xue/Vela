//
//  TabSessionRepository.swift
//  Vela
//
//  Persistence for the saved tab list and the recently-closed list. Ported from
//  the `tab_sessions` / `recently_closed_tabs` tables in
//  `AiraBrowser/entry/src/main/ets/data/database/BrowserDatabase.ets`
//  (Aira Browser 3.7.4, GPL-3.0).
//
//  Private tabs are written here like any other tab. Aira does the same, and the
//  reason is that "private" means "no durable browsing *history*", not "the app
//  forgets what is open" — killing the app mid-session and reopening it into an
//  empty private window would be a worse outcome than the row existing for the
//  seconds between suspend and the cleanup pass at quit, which
//  `BrowserPrivateSessionCleanupCoordinator` performs.
//

import Foundation

public final class TabSessionRepository: @unchecked Sendable {
    public static let defaultWindowId = "window-main"

    private let database: SQLiteDatabase

    public init(database: SQLiteDatabase) {
        self.database = database
    }

    // MARK: - Tabs

    private static let tabColumns = """
    id, window_id, profile_id, title, url, is_active, is_pinned, last_active_at, tab_order, \
    is_home, runtime_state, last_error, scroll_offset_y, last_good_url, last_good_title, \
    last_restore_reason, last_discard_reason, last_crash_reason, privacy_mode, data_scope, open_source
    """

    /// Replaces the saved session in one transaction.
    ///
    /// Ported from `BrowserTabSessionPersistenceCoordinator`. The write is a
    /// full replace rather than a diff: the tab list is small, and a replace
    /// cannot leave an orphan row behind from a tab that was closed while the
    /// app was being suspended.
    public func saveSession(_ snapshot: BrowserSessionSnapshot, windowId: String = defaultWindowId) throws {
        try database.transaction {
            try database.execute(
                "DELETE FROM \(BrowserSchema.tabSessionsTable) WHERE window_id = ?",
                [.text(windowId)]
            )
            for (index, tab) in snapshot.tabs.enumerated() {
                try database.execute(
                    """
                    INSERT INTO \(BrowserSchema.tabSessionsTable) (\(Self.tabColumns))
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    """,
                    [
                        .text(tab.id),
                        .text(windowId),
                        .text(tab.profileId),
                        .text(tab.title),
                        .text(tab.url),
                        .integer(tab.id == snapshot.activeTabId ? 1 : 0),
                        .integer(tab.pinned ? 1 : 0),
                        .integer(tab.lastActiveAt.milliseconds),
                        .integer(Int64(index)),
                        .integer(tab.isHome ? 1 : 0),
                        .text(TabRuntimeState.cold.rawValue),
                        .text(""),
                        .real(tab.scrollOffsetY),
                        .text(tab.lastGoodUrl),
                        .text(tab.lastGoodTitle),
                        .text(TabRestoreReason.none.rawValue),
                        .text(TabDiscardReason.none.rawValue),
                        .text(TabCrashReason.none.rawValue),
                        .text(tab.privacyMode.rawValue),
                        .text(tab.dataScope.rawValue),
                        .text(tab.openSource.rawValue)
                    ]
                )
            }
        }
    }

    /// Loads the saved session, or nil when there is nothing to restore.
    ///
    /// Ported from `BrowserStartupTabRestoreCoordinator`. Pinned tabs sort to
    /// the front regardless of their stored order, which is the invariant the
    /// pin operation maintains in memory; enforcing it on read means a session
    /// written by an older build still opens correctly.
    public func loadSession(windowId: String = defaultWindowId) throws -> BrowserSessionSnapshot? {
        let tabs = try database.query(
            """
            SELECT \(Self.tabColumns) FROM \(BrowserSchema.tabSessionsTable)
            WHERE window_id = ? ORDER BY is_pinned DESC, tab_order ASC
            """,
            [.text(windowId)]
        ) { statement in
            (
                TabRecord(
                    id: statement.string(at: 0),
                    profileId: statement.string(at: 2),
                    title: statement.string(at: 3),
                    url: statement.string(at: 4),
                    isHome: statement.bool(at: 9),
                    lastActiveAt: Date(milliseconds: statement.int(at: 7)),
                    pinned: statement.bool(at: 6),
                    privacyMode: BrowserSessionPrivacyMode(rawValue: statement.string(at: 18)) ?? .regular,
                    dataScope: BrowserDataScope(rawValue: statement.string(at: 19)) ?? .profilePersistent,
                    openSource: BrowserTabOpenSource(rawValue: statement.string(at: 20)) ?? .restore,
                    lastGoodUrl: statement.string(at: 13),
                    lastGoodTitle: statement.string(at: 14),
                    scrollOffsetY: statement.double(at: 12)
                ),
                statement.bool(at: 5)
            )
        }

        guard !tabs.isEmpty else { return nil }
        let activeId = tabs.first(where: { $0.1 })?.0.id ?? tabs[0].0.id
        return BrowserSessionSnapshot(
            tabs: tabs.map(\.0),
            activeTabId: activeId,
            tabSequence: tabs.count
        )
    }

    public func removeSession(windowId: String = defaultWindowId) throws {
        try database.execute(
            "DELETE FROM \(BrowserSchema.tabSessionsTable) WHERE window_id = ?",
            [.text(windowId)]
        )
    }

    // MARK: - Recently closed

    /// Ported from `BrowserRecentlyClosedTabsService`. The list is capped so a
    /// long session cannot grow it without bound.
    public static let recentlyClosedLimit = 25

    public func recordClosed(_ record: RecentlyClosedTabRecord) throws {
        try database.transaction {
            try database.execute(
                """
                INSERT OR REPLACE INTO \(BrowserSchema.recentlyClosedTabsTable)
                (id, title, url, closed_at, privacy_mode) VALUES (?, ?, ?, ?, ?)
                """,
                [
                    .text(record.id),
                    .text(record.title),
                    .text(record.url),
                    .integer(record.closedAt.milliseconds),
                    .text(record.privacyMode.rawValue)
                ]
            )
            try database.execute(
                """
                DELETE FROM \(BrowserSchema.recentlyClosedTabsTable)
                WHERE id NOT IN (
                  SELECT id FROM \(BrowserSchema.recentlyClosedTabsTable)
                  ORDER BY closed_at DESC LIMIT ?
                )
                """,
                [.integer(Int64(Self.recentlyClosedLimit))]
            )
        }
    }

    /// Recently closed tabs for one privacy mode.
    ///
    /// The privacy filter is not cosmetic: a private tab's title and URL must
    /// not appear in the list a regular tab shows. Ported from the split in
    /// `BrowserRecentlyClosedApplicationCoordinator`.
    public func recentlyClosed(
        privacyMode: BrowserSessionPrivacyMode,
        limit: Int = 25
    ) throws -> [RecentlyClosedTabRecord] {
        try database.query(
            """
            SELECT id, title, url, closed_at, privacy_mode
            FROM \(BrowserSchema.recentlyClosedTabsTable)
            WHERE privacy_mode = ?
            ORDER BY closed_at DESC LIMIT ?
            """,
            [.text(privacyMode.rawValue), .integer(Int64(limit))]
        ) { statement in
            RecentlyClosedTabRecord(
                id: statement.string(at: 0),
                title: statement.string(at: 1),
                url: statement.string(at: 2),
                closedAt: Date(milliseconds: statement.int(at: 3)),
                privacyMode: BrowserSessionPrivacyMode(rawValue: statement.string(at: 4)) ?? .regular
            )
        }
    }

    public func removeRecentlyClosed(id: String) throws {
        try database.execute(
            "DELETE FROM \(BrowserSchema.recentlyClosedTabsTable) WHERE id = ?",
            [.text(id)]
        )
    }

    /// Clears the recently-closed list for a privacy mode. Called when a private
    /// session ends, so the next private session starts empty.
    public func clearRecentlyClosed(privacyMode: BrowserSessionPrivacyMode) throws {
        try database.execute(
            "DELETE FROM \(BrowserSchema.recentlyClosedTabsTable) WHERE privacy_mode = ?",
            [.text(privacyMode.rawValue)]
        )
    }
}
