//
//  OfflinePageRepository.swift
//  Vela
//
//  Persistence for `offline_pages`.
//
//  The table was already part of the schema; this is the read and write side
//  the feature was missing. The archive itself is a file on disk, so a row is
//  metadata plus two paths — deleting a row and deleting its directory are the
//  same operation, and the service does both.
//

import Foundation

public final class OfflinePageRepository: @unchecked Sendable {
    private let database: SQLiteDatabase

    public init(database: SQLiteDatabase) {
        self.database = database
    }

    private static let columns = """
    id, original_url, normalized_url, url_hash, title, site_name, host, saved_at, \
    updated_at, snapshot_path, manifest_path, preview_image_uri, favicon_uri, \
    total_bytes, resource_count, failed_resource_count, save_status, open_status
    """

    private func record(from statement: SQLiteStatement) -> OfflinePageRecord {
        OfflinePageRecord(
            id: statement.string(at: 0),
            originalUrl: statement.string(at: 1),
            normalizedUrl: statement.string(at: 2),
            urlHash: statement.string(at: 3),
            title: statement.string(at: 4),
            siteName: statement.string(at: 5),
            host: statement.string(at: 6),
            savedAt: Date(milliseconds: statement.int(at: 7)),
            updatedAt: Date(milliseconds: statement.int(at: 8)),
            snapshotPath: statement.string(at: 9),
            manifestPath: statement.string(at: 10),
            previewImageUri: statement.optionalString(at: 11),
            faviconUri: statement.optionalString(at: 12),
            totalBytes: statement.int(at: 13),
            resourceCount: Int(statement.int(at: 14)),
            failedResourceCount: Int(statement.int(at: 15)),
            saveStatus: OfflinePageSaveStatus(rawValue: statement.string(at: 16)) ?? .complete,
            openStatus: OfflinePageOpenStatus(rawValue: statement.string(at: 17)) ?? .unread
        )
    }

    public func upsert(_ page: OfflinePageRecord) throws {
        try database.execute(
            """
            INSERT OR REPLACE INTO \(BrowserSchema.offlinePagesTable) (\(Self.columns))
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """,
            [
                .text(page.id),
                .text(page.originalUrl),
                .text(page.normalizedUrl),
                .text(page.urlHash),
                .text(page.title),
                .text(page.siteName),
                .text(page.host),
                .integer(page.savedAt.milliseconds),
                .integer(page.updatedAt.milliseconds),
                .text(page.snapshotPath),
                .text(page.manifestPath),
                page.previewImageUri.map(SQLiteValue.text) ?? .null,
                page.faviconUri.map(SQLiteValue.text) ?? .null,
                .integer(page.totalBytes),
                .integer(Int64(page.resourceCount)),
                .integer(Int64(page.failedResourceCount)),
                .text(page.saveStatus.rawValue),
                .text(page.openStatus.rawValue)
            ]
        )
    }

    public func pages(limit: Int = 500) throws -> [OfflinePageRecord] {
        try database.query(
            """
            SELECT \(Self.columns) FROM \(BrowserSchema.offlinePagesTable)
            ORDER BY saved_at DESC LIMIT ?
            """,
            [.integer(Int64(limit))],
            row: record(from:)
        )
    }

    public func page(id: String) throws -> OfflinePageRecord? {
        try database.query(
            """
            SELECT \(Self.columns) FROM \(BrowserSchema.offlinePagesTable)
            WHERE id = ?
            """,
            [.text(id)],
            row: record(from:)
        ).first
    }

    public func page(normalizedUrl: String) throws -> OfflinePageRecord? {
        try database.query(
            """
            SELECT \(Self.columns) FROM \(BrowserSchema.offlinePagesTable)
            WHERE normalized_url = ?
            ORDER BY saved_at DESC LIMIT 1
            """,
            [.text(normalizedUrl)],
            row: record(from:)
        ).first
    }

    public func remove(id: String) throws {
        try database.execute(
            "DELETE FROM \(BrowserSchema.offlinePagesTable) WHERE id = ?",
            [.text(id)]
        )
    }

    public func markOpened(id: String) throws {
        try database.execute(
            """
            UPDATE \(BrowserSchema.offlinePagesTable)
            SET open_status = ?, updated_at = ?
            WHERE id = ?
            """,
            [
                .text(OfflinePageOpenStatus.opened.rawValue),
                .integer(Date().milliseconds),
                .text(id)
            ]
        )
    }

    public func clearAll() throws {
        try database.execute("DELETE FROM \(BrowserSchema.offlinePagesTable)")
    }
}
