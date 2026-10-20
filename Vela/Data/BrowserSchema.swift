//
//  BrowserSchema.swift
//  Vela
//
//  The table definitions: columns, types, defaults, indexes and the
//  schema-version ladder.
//
//  The ladder keeps the numbering of the baseline it was derived from rather
//  than restarting at 1, so an external database can be compared against this
//  one directly.
//
//  Three tables exist because of how iOS sandboxes an app: downloads, user
//  scripts and ad-block subscriptions are stored here rather than in the
//  preferences document a shared path would have allowed, and the migration
//  note is recorded next to each.
//

import Foundation

public enum BrowserSchema {
    /// The current schema version.
    ///
    /// The ladder keeps the numbering of the schema it derived from rather than
    /// restarting at 1, so a database written by another build of this lineage
    /// can be compared against this one directly. Additions live above this
    /// number.
    public static let currentSchemaVersion = 7

    /// The first version this schema ever shipped.
    public static let initialSchemaVersion = 1

    /// The first revision above the derived baseline. Introduces the iOS-native
    /// tables.
    public static let velaSchemaVersion = 13

    public static let stateTable = "browser_schema_state"
    public static let bookmarksTable = "bookmarks"
    public static let bookmarkRootsTable = "bookmark_roots"
    public static let bookmarkNodesTable = "bookmark_nodes"
    public static let bookmarkOrdersTable = "bookmark_orders"
    public static let historyUrlsTable = "history_urls"
    public static let historyVisitsTable = "history_visits"
    public static let searchQueryHistoryTable = "search_query_history"
    public static let offlinePagesTable = "offline_pages"
    public static let tabSessionsTable = "tab_sessions"
    public static let recentlyClosedTabsTable = "recently_closed_tabs"
    public static let siteIconsTable = "site_icons"
    public static let downloadsTable = "downloads"
    public static let userScriptsTable = "user_scripts"
    public static let userScriptValuesTable = "user_script_values"
    public static let adBlockSourcesTable = "adblock_rule_sources"
    public static let novelBooksTable = "novel_books"
    public static let novelChaptersTable = "novel_chapters"
    public static let novelTOCEntriesTable = "novel_toc_entries"
    public static let novelTOCSourcesTable = "novel_toc_sources"

    /// Every statement needed to bring an empty database to `velaSchemaVersion`.
    public static let creationStatements: [String] = [
        """
        CREATE TABLE IF NOT EXISTS \(stateTable) (
          key TEXT PRIMARY KEY,
          value TEXT NOT NULL,
          updated_at INTEGER NOT NULL
        )
        """,

        // MARK: Bookmarks

        // `role` is the root identity the
        // bookmark manager shows as top-level sections; `sync_enabled` survives
        // the port because the WebDAV and Personal Server providers use it.
        """
        CREATE TABLE IF NOT EXISTS \(bookmarkRootsTable) (
          role TEXT PRIMARY KEY,
          node_id TEXT NOT NULL,
          title TEXT NOT NULL,
          position INTEGER NOT NULL,
          sync_enabled INTEGER NOT NULL DEFAULT 0
        )
        """,
        """
        CREATE UNIQUE INDEX IF NOT EXISTS idx_bookmark_roots_node_id
        ON \(bookmarkRootsTable)(node_id)
        """,

        // Folders and bookmarks share one
        // table, discriminated by `type`, with the ordering held separately in
        // `bookmark_orders` so a reorder never rewrites node rows.
        """
        CREATE TABLE IF NOT EXISTS \(bookmarkNodesTable) (
          id TEXT PRIMARY KEY,
          scope TEXT NOT NULL DEFAULT 'regular',
          type TEXT NOT NULL,
          title TEXT NOT NULL,
          url TEXT,
          created_at INTEGER NOT NULL,
          updated_at INTEGER NOT NULL,
          sync_state TEXT NOT NULL,
          sync_source TEXT NOT NULL,
          last_modified_at INTEGER NOT NULL,
          last_modified_by TEXT NOT NULL,
          device_id TEXT NOT NULL,
          origin_id TEXT,
          deleted_at INTEGER
        )
        """,
        "CREATE INDEX IF NOT EXISTS idx_bookmark_nodes_type ON \(bookmarkNodesTable)(type)",
        "CREATE INDEX IF NOT EXISTS idx_bookmark_nodes_url ON \(bookmarkNodesTable)(url)",
        "CREATE INDEX IF NOT EXISTS idx_bookmark_nodes_origin_id ON \(bookmarkNodesTable)(origin_id)",
        "CREATE INDEX IF NOT EXISTS idx_bookmark_nodes_deleted_at ON \(bookmarkNodesTable)(deleted_at)",

        // A child appears at most once, so
        // `child_id` is the primary key and a move is an update, not an insert.
        """
        CREATE TABLE IF NOT EXISTS \(bookmarkOrdersTable) (
          parent_id TEXT,
          child_id TEXT NOT NULL PRIMARY KEY,
          position INTEGER NOT NULL,
          updated_at INTEGER NOT NULL
        )
        """,
        """
        CREATE INDEX IF NOT EXISTS idx_bookmark_orders_parent_position
        ON \(bookmarkOrdersTable)(parent_id, position)
        """,

        // MARK: History

        // One row per distinct URL; repeat
        // visits increment `visit_count` and append to `history_visits`.
        // `hidden` is the tombstone the history manager uses for "delete this
        // entry" without breaking the visit rows that reference it.
        """
        CREATE TABLE IF NOT EXISTS \(historyUrlsTable) (
          id TEXT PRIMARY KEY,
          url TEXT NOT NULL,
          normalized_url TEXT NOT NULL,
          url_hash TEXT NOT NULL,
          origin TEXT NOT NULL,
          host TEXT NOT NULL,
          title TEXT NOT NULL,
          visit_count INTEGER NOT NULL,
          typed_count INTEGER NOT NULL,
          last_visit_at INTEGER NOT NULL,
          hidden INTEGER NOT NULL DEFAULT 0,
          favicon_key TEXT NOT NULL,
          created_at INTEGER NOT NULL,
          updated_at INTEGER NOT NULL
        )
        """,
        "CREATE UNIQUE INDEX IF NOT EXISTS idx_history_urls_hash ON \(historyUrlsTable)(url_hash)",
        "CREATE INDEX IF NOT EXISTS idx_history_urls_last_visit ON \(historyUrlsTable)(last_visit_at DESC)",
        "CREATE INDEX IF NOT EXISTS idx_history_urls_host_last_visit ON \(historyUrlsTable)(host, last_visit_at DESC)",
        "CREATE INDEX IF NOT EXISTS idx_history_urls_title ON \(historyUrlsTable)(title)",
        """
        CREATE INDEX IF NOT EXISTS idx_history_urls_visible_last_visit
        ON \(historyUrlsTable)(hidden, last_visit_at DESC)
        """,

        // The `sync_*` columns are retained
        // for WebDAV and Personal Server history sync; the partial unique index
        // on `sync_id` is what makes a re-pushed visit idempotent.
        """
        CREATE TABLE IF NOT EXISTS \(historyVisitsTable) (
          id TEXT PRIMARY KEY,
          url_id TEXT NOT NULL,
          visited_at INTEGER NOT NULL,
          from_visit_id TEXT,
          transition TEXT NOT NULL DEFAULT 'link',
          visit_duration_ms INTEGER NOT NULL DEFAULT 0,
          source TEXT NOT NULL,
          device_id TEXT NOT NULL,
          session_id TEXT NOT NULL,
          profile_id TEXT NOT NULL DEFAULT 'profile-main',
          data_scope TEXT NOT NULL DEFAULT 'profile_persistent',
          sync_id TEXT NOT NULL DEFAULT '',
          sync_account_uid TEXT NOT NULL DEFAULT '',
          sync_origin TEXT NOT NULL DEFAULT ''
        )
        """,
        "CREATE INDEX IF NOT EXISTS idx_history_visits_url_time ON \(historyVisitsTable)(url_id, visited_at DESC)",
        "CREATE INDEX IF NOT EXISTS idx_history_visits_visited_at ON \(historyVisitsTable)(visited_at DESC)",
        "CREATE INDEX IF NOT EXISTS idx_history_visits_from_visit ON \(historyVisitsTable)(from_visit_id)",
        "CREATE INDEX IF NOT EXISTS idx_history_visits_session ON \(historyVisitsTable)(session_id, visited_at DESC)",
        """
        CREATE INDEX IF NOT EXISTS idx_history_visits_profile_scope
        ON \(historyVisitsTable)(profile_id, data_scope, visited_at DESC)
        """,
        """
        CREATE UNIQUE INDEX IF NOT EXISTS idx_history_visits_sync_id
        ON \(historyVisitsTable)(sync_id) WHERE sync_id <> ''
        """,
        """
        CREATE INDEX IF NOT EXISTS idx_history_visits_sync_account
        ON \(historyVisitsTable)(sync_account_uid, sync_origin)
        """,

        // MARK: Search

        // Three normalisations are
        // stored so omnibox matching can be exact, case-insensitive and
        // whitespace-insensitive without a collation per query.
        """
        CREATE TABLE IF NOT EXISTS \(searchQueryHistoryTable) (
          id TEXT PRIMARY KEY,
          query TEXT NOT NULL,
          normalized_query TEXT NOT NULL,
          compact_query TEXT NOT NULL,
          search_engine_id TEXT NOT NULL,
          use_count INTEGER NOT NULL DEFAULT 1,
          first_searched_at INTEGER NOT NULL,
          last_searched_at INTEGER NOT NULL,
          profile_id TEXT NOT NULL DEFAULT 'profile-main',
          data_scope TEXT NOT NULL DEFAULT 'profile_persistent'
        )
        """,
        """
        CREATE INDEX IF NOT EXISTS idx_search_query_history_recent
        ON \(searchQueryHistoryTable)(profile_id, data_scope, last_searched_at DESC)
        """,
        """
        CREATE INDEX IF NOT EXISTS idx_search_query_history_normalized
        ON \(searchQueryHistoryTable)(profile_id, data_scope, normalized_query)
        """,
        """
        CREATE INDEX IF NOT EXISTS idx_search_query_history_compact
        ON \(searchQueryHistoryTable)(profile_id, data_scope, compact_query)
        """,

        // MARK: Offline pages

        """
        CREATE TABLE IF NOT EXISTS \(offlinePagesTable) (
          id TEXT PRIMARY KEY,
          original_url TEXT NOT NULL,
          normalized_url TEXT NOT NULL,
          url_hash TEXT NOT NULL,
          title TEXT NOT NULL,
          site_name TEXT NOT NULL,
          host TEXT NOT NULL,
          saved_at INTEGER NOT NULL,
          updated_at INTEGER NOT NULL,
          snapshot_path TEXT NOT NULL,
          manifest_path TEXT NOT NULL,
          preview_image_uri TEXT,
          favicon_uri TEXT,
          total_bytes INTEGER NOT NULL,
          resource_count INTEGER NOT NULL,
          failed_resource_count INTEGER NOT NULL,
          save_status TEXT NOT NULL,
          open_status TEXT NOT NULL
        )
        """,
        "CREATE INDEX IF NOT EXISTS idx_offline_pages_saved_at ON \(offlinePagesTable)(saved_at DESC)",
        "CREATE INDEX IF NOT EXISTS idx_offline_pages_url_hash ON \(offlinePagesTable)(url_hash)",
        "CREATE INDEX IF NOT EXISTS idx_offline_pages_host_saved_at ON \(offlinePagesTable)(host, saved_at DESC)",

        // MARK: Tab sessions

        // The columns that describe a serialised web-node state
        // (`web_state_path`, `form_draft`, `page_runtime_signals`) are absent:
        // `WKWebView` has no equivalent to store, and a restore here navigates to
        // the URL, so those columns would only hold values nothing reads back.
        """
        CREATE TABLE IF NOT EXISTS \(tabSessionsTable) (
          id TEXT PRIMARY KEY,
          window_id TEXT NOT NULL,
          profile_id TEXT NOT NULL DEFAULT 'profile-main',
          title TEXT NOT NULL,
          url TEXT NOT NULL,
          is_active INTEGER NOT NULL,
          is_pinned INTEGER NOT NULL,
          last_active_at INTEGER NOT NULL,
          tab_order INTEGER NOT NULL DEFAULT 0,
          is_home INTEGER NOT NULL DEFAULT 0,
          runtime_state TEXT NOT NULL DEFAULT 'cold',
          last_error TEXT NOT NULL DEFAULT '',
          scroll_offset_y REAL NOT NULL DEFAULT 0,
          last_good_url TEXT NOT NULL DEFAULT '',
          last_good_title TEXT NOT NULL DEFAULT '',
          last_restore_reason TEXT NOT NULL DEFAULT 'none',
          last_discard_reason TEXT NOT NULL DEFAULT 'none',
          last_crash_reason TEXT NOT NULL DEFAULT 'none',
          privacy_mode TEXT NOT NULL DEFAULT 'regular',
          data_scope TEXT NOT NULL DEFAULT 'profile_persistent',
          open_source TEXT NOT NULL DEFAULT 'user'
        )
        """,
        "CREATE INDEX IF NOT EXISTS idx_tab_sessions_order ON \(tabSessionsTable)(window_id, tab_order)",
        "CREATE INDEX IF NOT EXISTS idx_tab_sessions_active ON \(tabSessionsTable)(window_id, is_active)",

        """
        CREATE TABLE IF NOT EXISTS \(recentlyClosedTabsTable) (
          id TEXT PRIMARY KEY,
          title TEXT NOT NULL,
          url TEXT NOT NULL,
          closed_at INTEGER NOT NULL,
          privacy_mode TEXT NOT NULL DEFAULT 'regular'
        )
        """,
        "CREATE INDEX IF NOT EXISTS idx_recently_closed_closed_at ON \(recentlyClosedTabsTable)(closed_at DESC)",

        // MARK: Site icons

        // `file_uri` holds a filename inside Application Support rather than a
        // cache URI owned by the web engine.
        """
        CREATE TABLE IF NOT EXISTS \(siteIconsTable) (
          domain TEXT PRIMARY KEY,
          icon_url TEXT NOT NULL,
          source TEXT NOT NULL,
          extension TEXT NOT NULL,
          file_uri TEXT NOT NULL,
          quality_score INTEGER NOT NULL,
          width INTEGER NOT NULL DEFAULT 0,
          height INTEGER NOT NULL DEFAULT 0,
          last_accessed_at INTEGER NOT NULL,
          updated_at INTEGER NOT NULL
        )
        """,
        "CREATE INDEX IF NOT EXISTS idx_site_icons_last_accessed_at ON \(siteIconsTable)(last_accessed_at)",
        "CREATE INDEX IF NOT EXISTS idx_site_icons_updated_at ON \(siteIconsTable)(updated_at)",
        "CREATE INDEX IF NOT EXISTS idx_site_icons_source ON \(siteIconsTable)(source)",

        // MARK: Vela-native: downloads

        // Migration note: download records live in the relational database
        // rather than a preferences-backed JSON document, because `WKDownload`
        // resume data is binary and a preferences value is the wrong container
        // for it.
        """
        CREATE TABLE IF NOT EXISTS \(downloadsTable) (
          guid TEXT PRIMARY KEY,
          profile_id TEXT NOT NULL DEFAULT 'profile-main',
          privacy_mode TEXT NOT NULL DEFAULT 'regular',
          data_scope TEXT NOT NULL DEFAULT 'profile_persistent',
          request_url TEXT NOT NULL,
          final_url TEXT NOT NULL DEFAULT '',
          suggested_file_name TEXT NOT NULL,
          resolved_file_name TEXT NOT NULL DEFAULT '',
          mime_type TEXT NOT NULL DEFAULT '',
          status TEXT NOT NULL,
          received_bytes INTEGER NOT NULL DEFAULT 0,
          total_bytes INTEGER NOT NULL DEFAULT 0,
          written_bytes INTEGER NOT NULL DEFAULT 0,
          destination_path TEXT NOT NULL DEFAULT '',
          resume_data BLOB,
          failure_reason TEXT NOT NULL DEFAULT '',
          created_at INTEGER NOT NULL,
          updated_at INTEGER NOT NULL,
          completed_at INTEGER
        )
        """,
        "CREATE INDEX IF NOT EXISTS idx_downloads_status ON \(downloadsTable)(status)",
        "CREATE INDEX IF NOT EXISTS idx_downloads_created_at ON \(downloadsTable)(created_at DESC)",
        "CREATE INDEX IF NOT EXISTS idx_downloads_profile_scope ON \(downloadsTable)(profile_id, data_scope, created_at DESC)",

        // MARK: Vela-native: user scripts

        // Migration note: user scripts live in tables rather than a preferences
        // document, so the `@match` patterns can be indexed and the GM_ value
        // store gets per-key atomic writes. They stay local to the device either
        // way.
        """
        CREATE TABLE IF NOT EXISTS \(userScriptsTable) (
          id TEXT PRIMARY KEY,
          name TEXT NOT NULL,
          namespace TEXT NOT NULL DEFAULT '',
          version TEXT NOT NULL DEFAULT '',
          description TEXT NOT NULL DEFAULT '',
          icon_url TEXT NOT NULL DEFAULT '',
          source TEXT NOT NULL,
          source_url TEXT NOT NULL DEFAULT '',
          update_url TEXT NOT NULL DEFAULT '',
          download_url TEXT NOT NULL DEFAULT '',
          enabled INTEGER NOT NULL DEFAULT 1,
          matches TEXT NOT NULL DEFAULT '[]',
          includes TEXT NOT NULL DEFAULT '[]',
          exclude_matches TEXT NOT NULL DEFAULT '[]',
          excludes TEXT NOT NULL DEFAULT '[]',
          grants TEXT NOT NULL DEFAULT '[]',
          require_urls TEXT NOT NULL DEFAULT '[]',
          require_sources TEXT NOT NULL DEFAULT '[]',
          resource_declarations TEXT NOT NULL DEFAULT '[]',
          resources TEXT NOT NULL DEFAULT '[]',
          connect_rules TEXT NOT NULL DEFAULT '[]',
          noframes INTEGER NOT NULL DEFAULT 0,
          run_at TEXT NOT NULL DEFAULT 'document-idle',
          install_source TEXT NOT NULL DEFAULT 'paste',
          position INTEGER NOT NULL DEFAULT 0,
          created_at INTEGER NOT NULL,
          updated_at INTEGER NOT NULL,
          last_checked_at INTEGER,
          metadata_block TEXT NOT NULL DEFAULT ''
        )
        """,
        "CREATE INDEX IF NOT EXISTS idx_user_scripts_enabled ON \(userScriptsTable)(enabled, position)",

        // `GM_setValue`. Keyed by script id plus key name.
        """
        CREATE TABLE IF NOT EXISTS \(userScriptValuesTable) (
          script_id TEXT NOT NULL,
          key TEXT NOT NULL,
          value TEXT NOT NULL,
          updated_at INTEGER NOT NULL,
          PRIMARY KEY (script_id, key)
        )
        """,
        "CREATE INDEX IF NOT EXISTS idx_user_script_values_script ON \(userScriptValuesTable)(script_id)",

        // MARK: Vela-native: ad-block rule sources

        // Migration note: the subscription metadata lives in a table and the rule
        // text stays on disk, because the compiled `WKContentRuleList` identifier
        // has to be tracked and invalidated.
        """
        CREATE TABLE IF NOT EXISTS \(adBlockSourcesTable) (
          id TEXT PRIMARY KEY,
          name TEXT NOT NULL,
          url TEXT NOT NULL DEFAULT '',
          source_type TEXT NOT NULL,
          enabled INTEGER NOT NULL DEFAULT 1,
          rule_count INTEGER NOT NULL DEFAULT 0,
          last_updated_at INTEGER NOT NULL DEFAULT 0,
          last_error TEXT NOT NULL DEFAULT '',
          content_rule_list_identifier TEXT NOT NULL DEFAULT ''
        )
        """,
        """
        CREATE INDEX IF NOT EXISTS idx_adblock_sources_enabled
        ON \(adBlockSourcesTable)(enabled, source_type)
        """,

        // MARK: Vela-native: the novel shelf

        // Migration note: a book is the shelf's unit and a chapter is its
        // content. Chapters are rows rather than files because the reader
        // already asks for one by (book, url) and SQLite's row cache makes a
        // revisited chapter instant; the shelf prunes old chapters per book.
        """
        CREATE TABLE IF NOT EXISTS \(novelBooksTable) (
          id TEXT PRIMARY KEY,
          title TEXT NOT NULL,
          author TEXT NOT NULL DEFAULT '',
          source_url TEXT NOT NULL DEFAULT '',
          current_chapter_url TEXT NOT NULL DEFAULT '',
          current_chapter_title TEXT NOT NULL DEFAULT '',
          chapter_index INTEGER NOT NULL DEFAULT 0,
          progress REAL NOT NULL DEFAULT 0,
          added_at INTEGER NOT NULL,
          updated_at INTEGER NOT NULL,
          last_read_at INTEGER NOT NULL
        )
        """,
        """
        CREATE INDEX IF NOT EXISTS idx_novel_books_last_read
        ON \(novelBooksTable)(last_read_at DESC)
        """,

        // A chapter is identified by its book and its source URL: the same
        // URL reached twice is the same chapter, whatever the index says.
        """
        CREATE TABLE IF NOT EXISTS \(novelChaptersTable) (
          book_id TEXT NOT NULL,
          url TEXT NOT NULL,
          chapter_index INTEGER NOT NULL DEFAULT 0,
          title TEXT NOT NULL DEFAULT '',
          content_html TEXT NOT NULL,
          previous_url TEXT NOT NULL DEFAULT '',
          next_url TEXT NOT NULL DEFAULT '',
          fetched_at INTEGER NOT NULL,
          PRIMARY KEY (book_id, url)
        )
        """,
        """
        CREATE INDEX IF NOT EXISTS idx_novel_chapters_book_index
        ON \(novelChaptersTable)(book_id, chapter_index)
        """,

        // The table of contents is its own pair of tables: the entries are
        // replaced when a TOC page is re-read, and the source row remembers
        // where to read it from without changing the book record.
        """
        CREATE TABLE IF NOT EXISTS \(novelTOCEntriesTable) (
          book_id TEXT NOT NULL,
          url TEXT NOT NULL,
          title TEXT NOT NULL,
          position INTEGER NOT NULL,
          PRIMARY KEY (book_id, url)
        )
        """,
        """
        CREATE INDEX IF NOT EXISTS idx_novel_toc_entries_book_position
        ON \(novelTOCEntriesTable)(book_id, position)
        """,
        """
        CREATE TABLE IF NOT EXISTS \(novelTOCSourcesTable) (
          book_id TEXT PRIMARY KEY,
          toc_url TEXT NOT NULL,
          fetched_at INTEGER NOT NULL
        )
        """
    ]
}
