import XCTest
@testable import Vela

final class DownloadRepositoryTests: XCTestCase {
    func testOwnerRoundTripAndResumeDataSurvivesUpdates() throws {
        let db = try SQLiteDatabase(path: ":memory:")
        try BrowserDatabase.migrate(db)
        let repository = DownloadRepository(database: db)
        var task = DownloadTask(windowId: "a", privateSessionId: "one", privacyMode: .private, dataScope: .sessionEphemeral, requestUrl: "https://example.com", suggestedFileName: "file")
        try repository.upsert(task)
        let resume = Data([1,2,3])
        try repository.storeResumeData(resume, guid: task.guid)
        task.status = .paused
        try repository.upsert(task)
        XCTAssertEqual(try repository.task(guid: task.guid)?.windowId, "a")
        XCTAssertEqual(try repository.task(guid: task.guid)?.privateSessionId, "one")
        XCTAssertEqual(try repository.task(guid: task.guid)?.status, .paused)
        XCTAssertEqual(try repository.resumeData(guid: task.guid), resume)
    }
    func testClearingMoreThanOnePageIsScopedToExactSession() throws {
        let db = try SQLiteDatabase(path: ":memory:")
        try BrowserDatabase.migrate(db)
        let repository = DownloadRepository(database: db)
        for index in 0..<305 {
            try repository.upsert(DownloadTask(guid: "a-\(index)", windowId: "a", privateSessionId: "old", privacyMode: .private, requestUrl: "https://example.com", suggestedFileName: "file"))
        }
        for (guid, window, session, mode) in [("b", "b", "one", BrowserSessionPrivacyMode.private), ("new", "a", "new", .private), ("regular", "a", "old", .regular)] {
            try repository.upsert(DownloadTask(guid: guid, windowId: window, privateSessionId: session, privacyMode: mode, requestUrl: "https://example.com", suggestedFileName: "file"))
        }
        XCTAssertEqual(try repository.privateTasks(windowId: "a", sessionId: "old").count, 305)
        try repository.clearPrivateRecords(windowId: "a", sessionId: "old")
        XCTAssertEqual(Set(try repository.allTasks().map(\.guid)), Set(["b", "new", "regular"]))
    }
    func testLegacyDownloadDocumentStillDecodes() throws {
        let task = DownloadTask(requestUrl: "https://example.com", suggestedFileName: "file")
        let data = try JSONEncoder().encode(task)
        let decoded = try JSONDecoder().decode(DownloadTask.self, from: data)
        XCTAssertNil(decoded.windowId)
        XCTAssertNil(decoded.privateSessionId)
    }
}
