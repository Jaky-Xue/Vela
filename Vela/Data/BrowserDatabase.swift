//
//  BrowserDatabase.swift
//  Vela
//
//  Connection ownership and the schema-version ladder.
//
//  The connection opens lazily and the creation script runs on every open, with
//  the version reconciled afterwards. That order is what makes an interrupted
//  first launch recoverable: tables first, version row second, so a crash
//  between the two leaves a database the next open can finish upgrading rather
//  than one that claims a version it does not have.
//

import Foundation

/// Owns the single database connection for the process.
public final class BrowserDatabase: @unchecked Sendable {
    public static let shared = BrowserDatabase()

    private let lock = NSLock()
    private var database: SQLiteDatabase?

    private init() {}

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

        let opened = try SQLiteDatabase(path: Self.databasePath)
        try createTables(in: opened)
        try reconcileSchemaVersion(in: opened)
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
    }

    /// Reads and updates the version row in `browser_schema_state`.
    ///
    /// Rows added by a newer build are written forward; a database reporting a
    /// version newer than this build understands is left alone rather than
    /// downgraded, because the alternative is destroying data the user has not
    /// seen yet.
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
