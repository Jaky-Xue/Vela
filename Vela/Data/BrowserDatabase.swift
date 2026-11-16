//
//  BrowserDatabase.swift
//  Vela
//
//  Connection ownership and the schema-version ladder.
//
//  Schema creation, additive repair and the version update commit atomically.
//  An error rolls back every change and leaves the original database intact.
//

import Foundation

/// Owns the single database connection for the process.
public final class BrowserDatabase: @unchecked Sendable {
    public static let shared = BrowserDatabase()

    private let lock = NSLock()
    private var database: SQLiteDatabase?

    private let path: String?
    public init(path: String? = nil) { self.path = path }

    enum MigrationError: Error, LocalizedError {
        case unsupportedVersion(Int)
        case invalidVersion(String)
        var errorDescription: String? {
            switch self {
            case .unsupportedVersion(let version): return "数据库版本 \(version) 高于当前支持版本 \(BrowserSchema.velaSchemaVersion)，请更新应用。原始数据未被重置。"
            case .invalidVersion: return "数据库版本记录无效，迁移已停止。原始数据未被重置。"
            }
        }
    }

    static func migrate(_ database: SQLiteDatabase) throws {
        try database.transaction {
            let hasState = try database.scalarInt("SELECT COUNT(*) FROM sqlite_master WHERE type = 'table' AND name = ?", [.text(BrowserSchema.stateTable)]) > 0
            if hasState {
                let value = try database.query("SELECT value FROM \(BrowserSchema.stateTable) WHERE key = 'schema_version'") { $0.string(at: 0) }.first
                if let value {
                    guard let version = Int(value), version >= 0 else { throw MigrationError.invalidVersion(value) }
                    guard version <= BrowserSchema.velaSchemaVersion else { throw MigrationError.unsupportedVersion(version) }
                }
            }
            let migrator = BrowserDatabase()
            try migrator.createTables(in: database)
            try migrator.reconcileSchemaVersion(in: database)
        }
    }

    /// Directory holding the database and its WAL sidecars.
    ///
    /// Application Support, which is backed up and not user-visible in the Files
    /// app.
    public static var storeDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let directory = base.appendingPathComponent("Vela", isDirectory: true)
        if !FileManager.default.fileExists(atPath: directory.path) {
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        return directory
    }

    public static var databasePath: String {
        storeDirectory.appendingPathComponent("browser.db").path
    }

    /// Opens the database, creating and migrating it when needed.
    ///
    /// Private browsing never opens a second database: private mode is expressed
    /// as a data boundary that suppresses writes, matching ADR 0065
    /// ("private browsing uses effect policy") rather than a separate store.
    @discardableResult
    public func open() throws -> SQLiteDatabase {
        lock.lock()
        defer { lock.unlock() }

        if let database { return database }

        let opened = try SQLiteDatabase(path: path ?? Self.databasePath)
        try Self.migrate(opened)
        database = opened
        return opened
    }

    /// The live connection, opening it when necessary.
    public func connection() throws -> SQLiteDatabase {
        try open()
    }

    /// Runs every `CREATE TABLE IF NOT EXISTS` statement.
    ///
    /// The full creation script runs on every open, not only on first launch.
    /// That is what lets a database created by an older build pick up a table
    /// added by a newer one without a dedicated migration step.
    private func createTables(in database: SQLiteDatabase) throws {
        for statement in BrowserSchema.creationStatements {
            try database.execute(statement)
        }
        try ensureColumn("window_id", in: BrowserSchema.downloadsTable, definition: "TEXT", database: database)
        try ensureColumn("private_session_id", in: BrowserSchema.downloadsTable, definition: "TEXT", database: database)
        try database.execute("CREATE INDEX IF NOT EXISTS idx_downloads_owner ON \(BrowserSchema.downloadsTable)(window_id, private_session_id, privacy_mode)")
        // `CREATE TABLE IF NOT EXISTS` does not add a column to a table that
        // already exists, so columns introduced after the first release are
        // added here. SQLite has no portable `ADD COLUMN IF NOT EXISTS`, hence
        // the PRAGMA check.
        try ensureColumn(
            "last_checked_at",
            in: BrowserSchema.userScriptsTable,
            definition: "INTEGER",
            database: database
        )
        try ensureColumn(
            "resource_declarations",
            in: BrowserSchema.userScriptsTable,
            definition: "TEXT NOT NULL DEFAULT '[]'",
            database: database
        )
        try ensureColumn(
            "metadata_block",
            in: BrowserSchema.userScriptsTable,
            definition: "TEXT NOT NULL DEFAULT ''",
            database: database
        )
    }

    private func ensureColumn(
        _ column: String,
        in table: String,
        definition: String,
        database: SQLiteDatabase
    ) throws {
        let columns = try database.query("PRAGMA table_info(\(table))") {
            $0.string(at: 1)
        }
        guard !columns.contains(column) else { return }
        try database.execute("ALTER TABLE \(table) ADD COLUMN \(column) \(definition)")
    }

    /// Reads and updates the version row in `browser_schema_state`.
    ///
    /// Called only after the version has been validated and all DDL succeeded,
    /// inside the migration transaction. Future versions are rejected before DDL.
    private func reconcileSchemaVersion(in database: SQLiteDatabase) throws {
        let key = "schema_version"
        let existing = try database.query(
            "SELECT value FROM \(BrowserSchema.stateTable) WHERE key = ?",
            [.text(key)]
        ) { $0.string(at: 0) }.first

        let now = Int64(Date().timeIntervalSince1970 * 1000)

        guard let existing, let version = Int(existing) else {
            try database.execute(
                "INSERT INTO \(BrowserSchema.stateTable) (key, value, updated_at) VALUES (?, ?, ?)",
                [.text(key), .text(String(BrowserSchema.velaSchemaVersion)), .integer(now)]
            )
            return
        }

        guard version < BrowserSchema.velaSchemaVersion else { return }

        try database.execute(
            "UPDATE \(BrowserSchema.stateTable) SET value = ?, updated_at = ? WHERE key = ?",
            [.text(String(BrowserSchema.velaSchemaVersion)), .integer(now), .text(key)]
        )
    }

    /// The schema version currently recorded in the database.
    public func recordedSchemaVersion() throws -> Int {
        let database = try open()
        let value = try database.query(
            "SELECT value FROM \(BrowserSchema.stateTable) WHERE key = ?",
            [.text("schema_version")]
        ) { $0.string(at: 0) }.first
        return value.flatMap(Int.init) ?? 0
    }

    /// Deletes every row in every table without deleting the file, which keeps
    /// the open connection valid. Used by "清除浏览数据".
    public func eraseAllData() throws {
        let database = try open()
        let tables = [
            BrowserSchema.bookmarkOrdersTable,
            BrowserSchema.bookmarkNodesTable,
            BrowserSchema.bookmarkRootsTable,
            BrowserSchema.historyVisitsTable,
            BrowserSchema.historyUrlsTable,
            BrowserSchema.searchQueryHistoryTable,
            BrowserSchema.offlinePagesTable,
            BrowserSchema.tabSessionsTable,
            BrowserSchema.recentlyClosedTabsTable,
            BrowserSchema.siteIconsTable,
            BrowserSchema.downloadsTable,
            BrowserSchema.userScriptValuesTable
        ]
        try database.transaction {
            for table in tables {
                try database.execute("DELETE FROM \(table)")
            }
        }
    }
}
