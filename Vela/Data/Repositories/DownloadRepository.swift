//
//  DownloadRepository.swift
//  Vela
//
//  Persistence for downloads.
//
//  Records live in a table rather than a preferences document because resume
//  data is an opaque `Data` blob that has to survive a relaunch, and a
//  preferences value is the wrong container for a binary payload. The record
//  fields are otherwise the ones the status machine needs.
//

import Foundation

public final class DownloadRepository: @unchecked Sendable {
    private let database: SQLiteDatabase

    public init(database: SQLiteDatabase) {
        self.database = database
    }

    private static let columns = """
    guid, profile_id, privacy_mode, data_scope, request_url, final_url, suggested_file_name, \
    resolved_file_name, mime_type, status, received_bytes, total_bytes, written_bytes, \
    destination_path, failure_reason, created_at, updated_at, completed_at
    """

    private func task(from statement: SQLiteStatement) -> DownloadTask {
        let failureReason = statement.string(at: 14)
        return DownloadTask(
            guid: statement.string(at: 0),
            profileId: statement.string(at: 1),
            privacyMode: BrowserSessionPrivacyMode(rawValue: statement.string(at: 2)) ?? .regular,
            dataScope: BrowserDataScope(rawValue: statement.string(at: 3)) ?? .profilePersistent,
            requestUrl: statement.string(at: 4),
            finalUrl: statement.string(at: 5),
            suggestedFileName: statement.string(at: 6),
            resolvedFileName: statement.string(at: 7),
            mimeType: statement.string(at: 8),
            status: DownloadStatus(rawValue: statement.string(at: 9)) ?? .pending,
            receivedBytes: statement.int(at: 10),
            totalBytes: statement.int(at: 11),
            writtenBytes: statement.int(at: 12),
            destinationPath: statement.string(at: 13),
            failure: failureReason.isEmpty ? nil : DownloadFailure(reason: failureReason),
            createdAt: Date(milliseconds: statement.int(at: 15)),
            updatedAt: Date(milliseconds: statement.int(at: 16)),
            completedAt: statement.optionalInt(at: 17).map { Date(milliseconds: $0) }
        )
    }

    // MARK: - Writing

    /// Inserts or updates a task.
    public func upsert(_ task: DownloadTask) throws {
        try database.execute(
            """
            INSERT OR REPLACE INTO \(BrowserSchema.downloadsTable) (\(Self.columns))
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """,
            [
                .text(task.guid),
                .text(task.profileId),
                .text(task.privacyMode.rawValue),
                .text(task.dataScope.rawValue),
                .text(task.requestUrl),
                .text(task.finalUrl),
                .text(task.suggestedFileName),
                .text(task.resolvedFileName),
                .text(task.mimeType),
                .text(task.status.rawValue),
                .integer(task.receivedBytes),
                .integer(task.totalBytes),
                .integer(task.writtenBytes),
                .text(task.destinationPath),
                .text(task.failure?.reason ?? ""),
                .integer(task.createdAt.milliseconds),
                .integer(task.updatedAt.milliseconds),
                task.completedAt.map { SQLiteValue.integer($0.milliseconds) } ?? .null
            ]
        )
    }

    /// Stores the resume blob for a paused or interrupted transfer.
    ///
    /// `resume_data` is deliberately outside `DownloadTask`: the blob is only
    /// ever written by the download service and only ever read when resuming,
    /// so keeping it out of the value type means the task can stay `Equatable`
    /// and cheap to publish.
    public func storeResumeData(_ data: Data?, guid: String) throws {
        try database.execute(
            "UPDATE \(BrowserSchema.downloadsTable) SET resume_data = ? WHERE guid = ?",
            [data.map { SQLiteValue.blob($0) } ?? .null, .text(guid)]
        )
    }

    public func resumeData(guid: String) throws -> Data? {
        try database.query(
            "SELECT resume_data FROM \(BrowserSchema.downloadsTable) WHERE guid = ?",
            [.text(guid)]
        ) { $0.value(at: 0).dataValue }.first ?? nil
    }

    /// Persists the security-scoped bookmark for a user-chosen download folder.
    ///
    /// iOS requires a bookmark to regain access to a folder outside the app
    /// container after relaunch, so the choice is recorded here. It lives in
    /// `UserDefaults` rather than a column because there is exactly one, and it
    /// is not per-task despite being recorded while a task is in flight.
    public func storeDestinationBookmark(_ bookmark: Data?) throws {
        if let bookmark {
            UserDefaults.standard.set(bookmark, forKey: "org.vela.browser.download-destination-bookmark")
        } else {
            UserDefaults.standard.removeObject(forKey: "org.vela.browser.download-destination-bookmark")
        }
    }

    public func destinationBookmark() -> Data? {
        UserDefaults.standard.data(forKey: "org.vela.browser.download-destination-bookmark")
    }

    // MARK: - Reading

    /// The download list. Private-mode downloads are filtered out for a regular
    /// session.
    public func tasks(
        privacyMode: BrowserSessionPrivacyMode,
        limit: Int = 300
    ) throws -> [DownloadTask] {
        try database.query(
            """
            SELECT \(Self.columns) FROM \(BrowserSchema.downloadsTable)
            WHERE privacy_mode = ?
            ORDER BY created_at DESC LIMIT ?
            """,
            [.text(privacyMode.rawValue), .integer(Int64(limit))],
            row: task(from:)
        )
    }

    public func task(guid: String) throws -> DownloadTask? {
        try database.query(
            "SELECT \(Self.columns) FROM \(BrowserSchema.downloadsTable) WHERE guid = ?",
            [.text(guid)],
            row: task(from:)
        ).first
    }

    /// Transfers that were in flight when the app stopped. On next launch these
    /// are offered as resumable.
    public func interruptedTasks() throws -> [DownloadTask] {
        try database.query(
            """
            SELECT \(Self.columns) FROM \(BrowserSchema.downloadsTable)
            WHERE status IN ('pending', 'running', 'paused')
            ORDER BY created_at DESC
            """,
            row: task(from:)
        )
    }

    public func activeCount(privacyMode: BrowserSessionPrivacyMode) throws -> Int {
        Int(try database.scalarInt(
            """
            SELECT COUNT(*) FROM \(BrowserSchema.downloadsTable)
            WHERE privacy_mode = ? AND status IN ('pending', 'running', 'paused')
            """,
            [.text(privacyMode.rawValue)]
        ))
    }

    // MARK: - Deleting

    public func remove(guid: String, deleteFile: Bool) throws {
        if deleteFile, let task = try task(guid: guid), let url = task.destinationUrl {
            try? FileManager.default.removeItem(at: url)
        }
        try database.execute(
            "DELETE FROM \(BrowserSchema.downloadsTable) WHERE guid = ?",
            [.text(guid)]
        )
    }

    public func removeCompleted(privacyMode: BrowserSessionPrivacyMode) throws {
        try database.execute(
            """
            DELETE FROM \(BrowserSchema.downloadsTable)
            WHERE privacy_mode = ? AND status IN ('completed', 'cancelled')
            """,
            [.text(privacyMode.rawValue)]
        )
    }

    /// Deletes every private-mode record. Called when a private session ends,
    /// alongside the rest of the private surface.
    public func clearPrivateRecords() throws {
        try database.execute(
            "DELETE FROM \(BrowserSchema.downloadsTable) WHERE privacy_mode = 'private'"
        )
    }
}
