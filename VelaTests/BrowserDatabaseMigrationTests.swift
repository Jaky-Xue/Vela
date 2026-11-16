import XCTest
@testable import Vela

final class BrowserDatabaseMigrationTests: XCTestCase {
    private func version(_ db: SQLiteDatabase) throws -> Int64 {
        try db.scalarInt("SELECT CAST(value AS INTEGER) FROM browser_schema_state WHERE key = 'schema_version'")
    }
    func testEmptyDatabaseAndRepeatedMigration() throws {
        let db = try SQLiteDatabase(path: ":memory:")
        try BrowserDatabase.migrate(db)
        try BrowserDatabase.migrate(db)
        XCTAssertEqual(try version(db), Int64(BrowserSchema.velaSchemaVersion))
        XCTAssertEqual(try db.scalarInt("SELECT COUNT(*) FROM pragma_table_info('downloads') WHERE name IN ('window_id','private_session_id')"), 2)
    }
    func testLegacyUpgradePreservesDataAndRepairsMissingColumns() throws {
        let db = try SQLiteDatabase(path: ":memory:")
        for sql in BrowserSchema.creationStatements {
            try db.execute(sql.replacingOccurrences(of: "  window_id TEXT,", with: "").replacingOccurrences(of: "  private_session_id TEXT,", with: ""))
        }
        try db.execute("INSERT INTO browser_schema_state VALUES ('schema_version','13',0)")
        try db.execute("INSERT INTO downloads (guid,request_url,suggested_file_name,status,created_at,updated_at) VALUES ('kept','https://example.com/file','file','paused',0,0)")
        try db.execute("ALTER TABLE user_scripts DROP COLUMN metadata_block")
        try BrowserDatabase.migrate(db)
        XCTAssertEqual(try version(db), 14)
        XCTAssertEqual(try db.scalarInt("SELECT COUNT(*) FROM downloads WHERE guid = 'kept'"), 1)
        XCTAssertEqual(try db.scalarInt("SELECT COUNT(*) FROM pragma_table_info('user_scripts') WHERE name = 'metadata_block'"), 1)
    }
    func testFailureRollsBackDDLAndVersionAndCanRetry() throws {
        let db = try SQLiteDatabase(path: ":memory:")
        try BrowserDatabase.migrate(db)
        try db.execute("UPDATE browser_schema_state SET value = '13'")
        try db.execute("DROP INDEX idx_downloads_owner")
        try db.execute("ALTER TABLE downloads DROP COLUMN window_id")
        try db.execute("ALTER TABLE downloads DROP COLUMN private_session_id")
        try db.execute("ALTER TABLE user_scripts DROP COLUMN metadata_block")
        try db.execute("CREATE TRIGGER reject_version BEFORE UPDATE ON browser_schema_state BEGIN SELECT RAISE(ABORT, 'injected failure'); END")
        XCTAssertThrowsError(try BrowserDatabase.migrate(db))
        XCTAssertEqual(try version(db), 13)
        XCTAssertEqual(try db.scalarInt("SELECT COUNT(*) FROM pragma_table_info('downloads') WHERE name = 'window_id'"), 0)
        try db.execute("DROP TRIGGER reject_version")
        try BrowserDatabase.migrate(db)
        XCTAssertEqual(try version(db), 14)
    }
    func testFutureVersionRejectedBeforeSchemaChanges() throws {
        let db = try SQLiteDatabase(path: ":memory:")
        try db.execute("CREATE TABLE browser_schema_state (key TEXT PRIMARY KEY, value TEXT NOT NULL, updated_at INTEGER NOT NULL)")
        try db.execute("INSERT INTO browser_schema_state VALUES ('schema_version','999',0)")
        XCTAssertThrowsError(try BrowserDatabase.migrate(db))
        XCTAssertEqual(try version(db), 999)
        XCTAssertEqual(try db.scalarInt("SELECT COUNT(*) FROM sqlite_master WHERE name = 'downloads'"), 0)
    }
    func testInterruptedTransactionPreservesUserData() throws {
        let db = try SQLiteDatabase(path: ":memory:")
        try BrowserDatabase.migrate(db)
        try db.execute("INSERT INTO browser_schema_state VALUES ('user-data','retained',0)")
        enum Interrupted: Error { case stopped }
        XCTAssertThrowsError(try db.transaction {
            try db.execute("DELETE FROM browser_schema_state")
            throw Interrupted.stopped
        })
        XCTAssertEqual(try version(db), 14)
        XCTAssertEqual(try db.scalarInt("SELECT COUNT(*) FROM browser_schema_state WHERE value = 'retained'"), 1)
    }
    func testRepeatedOpenReturnsSameConnection() throws {
        let store = BrowserDatabase(path: ":memory:")
        XCTAssertTrue(try store.open() === store.open())
    }
}
