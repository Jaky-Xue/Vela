import XCTest
import WebKit
@testable import Vela

@MainActor
final class PrivateDownloadIsolationTests: XCTestCase {
    func testEndingOneWindowPreservesOtherWindowAndRegularDownloads() throws {
        let db = try SQLiteDatabase(path: ":memory:")
        try BrowserDatabase.migrate(db)
        let repository = DownloadRepository(database: db)
        let settings = SettingsService(defaults: UserDefaults(suiteName: UUID().uuidString)!)
        let service = DownloadService(repository: repository, settings: settings)
        service.beginPrivateSession(windowId: "a", sessionId: "one")
        service.beginPrivateSession(windowId: "b", sessionId: "two")
        for (guid, window, session, mode) in [("a", "a", "one", BrowserSessionPrivacyMode.private), ("b", "b", "two", .private), ("r", "a", "", .regular)] {
            try repository.upsert(DownloadTask(guid: guid, windowId: window, privateSessionId: session, privacyMode: mode, requestUrl: "https://example.com", suggestedFileName: "file", status: .paused))
        }
        service.reload(privacyMode: .private)
        service.cancel(guid: "b", windowId: "a")
        XCTAssertEqual(try repository.task(guid: "b")?.status, .paused)
        service.clearPrivateRecords(windowId: "a", sessionId: "one")
        XCTAssertNil(try repository.task(guid: "a"))
        XCTAssertNotNil(try repository.task(guid: "r"))
        let b = try XCTUnwrap(repository.task(guid: "b"))
        XCTAssertTrue(service.canControl(b, windowId: "b"))
        XCTAssertFalse(service.canControl(b, windowId: "a"))
        XCTAssertEqual(service.visibleTasks(privacyMode: .private, windowId: "b", sessionId: "two").map(\.guid), ["b"])
        service.reload(privacyMode: .regular)
        XCTAssertEqual(service.visibleTasks(privacyMode: .private, windowId: "b", sessionId: "two").map(\.guid), ["b"])
    }
    func testConfirmationPromptsAreWindowOwnedAndSessionEndInvalidatesOnlyOwner() throws {
        let db = try SQLiteDatabase(path: ":memory:")
        try BrowserDatabase.migrate(db)
        let service = DownloadService(repository: DownloadRepository(database: db), settings: SettingsService(defaults: UserDefaults(suiteName: UUID().uuidString)!))
        let view = WKWebView()
        for window in ["a", "b"] {
            service.beginPrivateSession(windowId: window, sessionId: window)
            let boundary = BrowserDataBoundary(dataScope: .sessionEphemeral, privacyMode: .private, windowId: window, privateSessionId: window)
            service.handleWebDownload(request: URLRequest(url: URL(string: "https://example.com/file")!), boundary: boundary, webView: view, suggestedFileName: window, mimeType: "", totalBytes: 0)
        }
        XCTAssertEqual(service.pendingPrompt(windowId: "a")?.suggestedFileName, "a")
        service.clearPrivateRecords(windowId: "a", sessionId: "a")
        XCTAssertNil(service.pendingPrompt(windowId: "a"))
        XCTAssertEqual(service.pendingPrompt(windowId: "b")?.suggestedFileName, "b")
    }
    func testOldSessionCannotSaveScriptDownloadIntoNewSession() async throws {
        let db = try SQLiteDatabase(path: ":memory:")
        try BrowserDatabase.migrate(db)
        let service = DownloadService(repository: DownloadRepository(database: db), settings: SettingsService(defaults: UserDefaults(suiteName: UUID().uuidString)!))
        service.beginPrivateSession(windowId: "a", sessionId: "new")
        let old = BrowserDataBoundary(dataScope: .sessionEphemeral, privacyMode: .private, windowId: "a", privateSessionId: "old")
        do {
            _ = try await service.saveScriptFile(Data([1]), response: URLResponse(url: URL(string: "https://example.com")!, mimeType: nil, expectedContentLength: 1, textEncodingName: nil), suggestedName: "file", boundary: old)
            XCTFail("retired session must be rejected")
        } catch is CancellationError {} catch { XCTFail("unexpected error: \(error)") }
        XCTAssertTrue(service.tasks.isEmpty)
    }
}
