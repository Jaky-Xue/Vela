//
//  UserScriptRepository.swift
//  Vela
//
//  Persistence for installed user scripts and the GM_ value store.
//
//  Rows rather than a preferences document, for two reasons: the `@match` sets
//  can be indexed, and `GM_setValue` becomes a single-row write instead of a
//  read-modify-write of a whole document. Nothing here is synced — user scripts
//  stay local to the device by design.
//

import Foundation

public final class UserScriptRepository: @unchecked Sendable {
    private let database: SQLiteDatabase

    public init(database: SQLiteDatabase) {
        self.database = database
    }

    private static let columns = """
    id, name, namespace, version, description, icon_url, source, source_url, update_url, \
    download_url, enabled, matches, includes, exclude_matches, excludes, grants, require_urls, \
    require_sources, resources, connect_rules, noframes, run_at, install_source, position, \
    created_at, updated_at
    """

    private func decodeStringArray(_ raw: String) -> [String] {
        guard let data = raw.data(using: .utf8),
              let decoded = try? JSONDecoder().decode([String].self, from: data) else { return [] }
        return decoded
    }

    private func decodeResources(_ raw: String) -> [UserScriptResourceRecord] {
        guard let data = raw.data(using: .utf8),
              let decoded = try? JSONDecoder().decode([UserScriptResourceRecord].self, from: data) else {
            return []
        }
        return decoded
    }

    private func encode<T: Encodable>(_ value: T, fallback: String) -> String {
        guard let data = try? JSONEncoder().encode(value),
              let text = String(data: data, encoding: .utf8) else { return fallback }
        return text
    }

    private func script(from statement: SQLiteStatement) -> InstalledUserScriptState {
        InstalledUserScriptState(
            id: statement.string(at: 0),
            name: statement.string(at: 1),
            namespace: statement.string(at: 2),
            version: statement.string(at: 3),
            description: statement.string(at: 4),
            iconUrl: statement.string(at: 5),
            source: statement.string(at: 6),
            sourceUrl: statement.string(at: 7),
            updateUrl: statement.string(at: 8),
            downloadUrl: statement.string(at: 9),
            enabled: statement.bool(at: 10),
            matches: decodeStringArray(statement.string(at: 11)),
            includes: decodeStringArray(statement.string(at: 12)),
            excludeMatches: decodeStringArray(statement.string(at: 13)),
            excludes: decodeStringArray(statement.string(at: 14)),
            grants: decodeStringArray(statement.string(at: 15)).map { UserScriptGrant(token: $0) },
            requireUrls: decodeStringArray(statement.string(at: 16)),
            requireSources: decodeStringArray(statement.string(at: 17)),
            resources: decodeResources(statement.string(at: 18)),
            connectRules: decodeStringArray(statement.string(at: 19)),
            noframes: statement.bool(at: 20),
            runAt: UserScriptRunAt(rawValue: statement.string(at: 21)) ?? .documentIdle,
            installSource: UserScriptInstallSource(rawValue: statement.string(at: 22)) ?? .paste,
            createdAt: Date(milliseconds: statement.int(at: 24)),
            updatedAt: Date(milliseconds: statement.int(at: 25))
        )
    }

    // MARK: - Scripts

    public func upsert(_ script: InstalledUserScriptState) throws {
        let position = try nextPosition(excluding: script.id)
        try database.execute(
            """
            INSERT OR REPLACE INTO \(BrowserSchema.userScriptsTable) (\(Self.columns))
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """,
            [
                .text(script.id),
                .text(script.name),
                .text(script.namespace),
                .text(script.version),
                .text(script.description),
                .text(script.iconUrl),
                .text(script.source),
                .text(script.sourceUrl),
                .text(script.updateUrl),
                .text(script.downloadUrl),
                .integer(script.enabled ? 1 : 0),
                .text(encode(script.matches, fallback: "[]")),
                .text(encode(script.includes, fallback: "[]")),
                .text(encode(script.excludeMatches, fallback: "[]")),
                .text(encode(script.excludes, fallback: "[]")),
                .text(encode(script.grants.map(\.rawValue), fallback: "[]")),
                .text(encode(script.requireUrls, fallback: "[]")),
                .text(encode(script.requireSources, fallback: "[]")),
                .text(encode(script.resources, fallback: "[]")),
                .text(encode(script.connectRules, fallback: "[]")),
                .integer(script.noframes ? 1 : 0),
                .text(script.runAt.rawValue),
                .text(script.installSource.rawValue),
                .integer(Int64(position)),
                .integer(script.createdAt.milliseconds),
                .integer(script.updatedAt.milliseconds)
            ]
        )
    }

    private func nextPosition(excluding id: String) throws -> Int {
        let current = try database.query(
            "SELECT position FROM \(BrowserSchema.userScriptsTable) WHERE id = ?",
            [.text(id)]
        ) { Int($0.int(at: 0)) }.first
        if let current { return current }
        return Int(try database.scalarInt(
            "SELECT COALESCE(MAX(position), -1) FROM \(BrowserSchema.userScriptsTable)"
        )) + 1
    }

    /// Every installed script in display order.
    public func allScripts() throws -> [InstalledUserScriptState] {
        try database.query(
            """
            SELECT \(Self.columns) FROM \(BrowserSchema.userScriptsTable)
            ORDER BY position ASC, created_at ASC
            """,
            row: script(from:)
        )
    }

    /// Enabled scripts only — the set the injector considers.
    ///
    /// The `enabled` filter is applied in SQL rather than in Swift so the
    /// injector's per-navigation query is the cheap one; a user with a large
    /// script collection pays nothing for the disabled half.
    public func enabledScripts() throws -> [InstalledUserScriptState] {
        try database.query(
            """
            SELECT \(Self.columns) FROM \(BrowserSchema.userScriptsTable)
            WHERE enabled = 1 ORDER BY position ASC, created_at ASC
            """,
            row: script(from:)
        )
    }

    public func script(id: String) throws -> InstalledUserScriptState? {
        try database.query(
            "SELECT \(Self.columns) FROM \(BrowserSchema.userScriptsTable) WHERE id = ?",
            [.text(id)],
            row: script(from:)
        ).first
    }

    public func setEnabled(_ enabled: Bool, id: String) throws {
        try database.execute(
            "UPDATE \(BrowserSchema.userScriptsTable) SET enabled = ?, updated_at = ? WHERE id = ?",
            [.integer(enabled ? 1 : 0), .integer(Date().milliseconds), .text(id)]
        )
    }

    /// Removes a script and its value store together.
    ///
    /// behind would let a later reinstall of the same script see stale data it
    /// never wrote in this install.
    public func remove(id: String) throws {
        try database.transaction {
            try database.execute(
                "DELETE FROM \(BrowserSchema.userScriptsTable) WHERE id = ?",
                [.text(id)]
            )
            try database.execute(
                "DELETE FROM \(BrowserSchema.userScriptValuesTable) WHERE script_id = ?",
                [.text(id)]
            )
        }
    }

    public func reorder(orderedIds: [String]) throws {
        let now = Date().milliseconds
        try database.transaction {
            for (index, id) in orderedIds.enumerated() {
                try database.execute(
                    """
                    UPDATE \(BrowserSchema.userScriptsTable)
                    SET position = ?, updated_at = ? WHERE id = ?
                    """,
                    [.integer(Int64(index)), .integer(now), .text(id)]
                )
            }
        }
    }

    // MARK: - GM_ value store

    /// Values are
    /// JSON-encoded so a script can round-trip an object, not just a string —
    /// which is what the `GM_setValue(name, object)` overload requires.
    public func setValue(_ jsonValue: String, key: String, scriptId: String) throws {
        try database.execute(
            """
            INSERT OR REPLACE INTO \(BrowserSchema.userScriptValuesTable)
            (script_id, key, value, updated_at) VALUES (?, ?, ?, ?)
            """,
            [.text(scriptId), .text(key), .text(jsonValue), .integer(Date().milliseconds)]
        )
    }

    public func value(key: String, scriptId: String) throws -> String? {
        try database.query(
            """
            SELECT value FROM \(BrowserSchema.userScriptValuesTable)
            WHERE script_id = ? AND key = ?
            """,
            [.text(scriptId), .text(key)]
        ) { $0.string(at: 0) }.first
    }

    /// Every stored key for a script, as a JSON object. Backs `GM_listValues`
    /// and the bulk read `GM_getValues` performs.
    public func allValues(scriptId: String) throws -> [String: String] {
        let rows = try database.query(
            """
            SELECT key, value FROM \(BrowserSchema.userScriptValuesTable) WHERE script_id = ?
            """,
            [.text(scriptId)]
        ) { ($0.string(at: 0), $0.string(at: 1)) }
        return Dictionary(uniqueKeysWithValues: rows)
    }

    public func removeValue(key: String, scriptId: String) throws {
        try database.execute(
            """
            DELETE FROM \(BrowserSchema.userScriptValuesTable)
            WHERE script_id = ? AND key = ?
            """,
            [.text(scriptId), .text(key)]
        )
    }

    public func removeAllValues(scriptId: String) throws {
        try database.execute(
            "DELETE FROM \(BrowserSchema.userScriptValuesTable) WHERE script_id = ?",
            [.text(scriptId)]
        )
    }
}
