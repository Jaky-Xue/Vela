import XCTest
@testable import Vela

@MainActor
final class ScriptUpdateReviewTests: XCTestCase {
    private func fixture() throws -> (UserScriptService, SettingsService, URL, String) {
        let name = "ScriptReview-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        let settings = SettingsService(defaults: defaults)
        let db = try SQLiteDatabase(path: ":memory:")
        for statement in BrowserSchema.creationStatements { try db.execute(statement) }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(name)
        let service = UserScriptService(repository: UserScriptRepository(database: db), settings: settings, versionDirectory: directory)
        return (service, settings, directory, name)
    }
    private func source(_ version: String, grant: String = "none") -> String {
        "// ==UserScript==\n// @name Review Fixture\n// @namespace review.tests\n// @version \(version)\n// @match https://example.test/*\n// @grant \(grant)\n// ==/UserScript==\nwindow.fixtureVersion = '\(version)';"
    }
    private func install(_ service: UserScriptService) async throws -> InstalledUserScriptState {
        guard case let .success(outcome) = await service.install(text: source("1"), source: .paste, sourceUrl: "") else {
            throw UserScriptServiceError.parseFailed("fixture install failed")
        }
        return try XCTUnwrap(service.script(id: outcome.script.id))
    }

    func testExpandedUpdateRequiresExactReviewedCandidateAndCanRollBack() async throws {
        let (service, settings, directory, suite) = try fixture()
        defer { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: directory) }
        var original = try await install(service)
        service.setEnabled(false, id: original.id)
        original = try XCTUnwrap(service.script(id: original.id))
        try service.repository.setValue("42", key: "kept", scriptId: original.id)
        let candidate = try XCTUnwrap(UserScriptParser.parse(source("2", grant: "GM_setClipboard")).candidate)
        let staged = try await service.stageUpdate(candidate, for: original)
        XCTAssertEqual(staged, .pendingConfirmation("2"))
        XCTAssertEqual(service.script(id: original.id)?.version, "1")
        let pending = try XCTUnwrap(service.pendingUpdate(for: original.id))
        let wrong = await service.applyPendingUpdate(for: original.id, expectedHash: String(repeating: "0", count: 64))
        XCTAssertFalse(wrong)
        let applied = await service.applyPendingUpdate(for: original.id, expectedHash: pending.candidateHash)
        XCTAssertTrue(applied)
        XCTAssertEqual(service.script(id: original.id)?.version, "2")
        XCTAssertEqual(service.script(id: original.id)?.enabled, false)
        XCTAssertNil(service.pendingUpdate(for: original.id))
        let previous = try XCTUnwrap(service.previousVersion(for: original.id))
        XCTAssertEqual(previous.version, "1")
        let restoredService = UserScriptService(repository: service.repository, settings: settings, versionDirectory: directory)
        let rolledBack = await restoredService.restorePreviousVersion(for: original.id, expectedHash: previous.snapshotHash)
        XCTAssertTrue(rolledBack)
        XCTAssertEqual(restoredService.script(id: original.id)?.version, "1")
        XCTAssertEqual(restoredService.script(id: original.id)?.enabled, false)
        XCTAssertEqual(try service.repository.value(key: "kept", scriptId: original.id), "42")
        XCTAssertEqual(restoredService.previousVersion(for: original.id)?.version, "2")
    }

    func testChangedPendingCandidateAndChangedActiveScriptRejectStaleApproval() async throws {
        let (service, _, directory, suite) = try fixture()
        defer { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: directory) }
        let original = try await install(service)
        let two = try XCTUnwrap(UserScriptParser.parse(source("2", grant: "GM_setClipboard")).candidate)
        _ = try await service.stageUpdate(two, for: original)
        let first = try XCTUnwrap(service.pendingUpdate(for: original.id))
        let three = try XCTUnwrap(UserScriptParser.parse(source("3", grant: "GM_cookie")).candidate)
        _ = try await service.stageUpdate(three, for: original)
        let stale = await service.applyPendingUpdate(for: original.id, expectedHash: first.candidateHash)
        XCTAssertFalse(stale)
        XCTAssertEqual(service.script(id: original.id)?.version, "1")
        let latest = try XCTUnwrap(service.pendingUpdate(for: original.id))
        var changed = original
        changed.updatedAt = original.updatedAt.addingTimeInterval(1)
        changed.source = "window.edited = true;"
        try service.repository.upsert(changed); service.reload()
        let rejected = await service.applyPendingUpdate(for: original.id, expectedHash: latest.candidateHash)
        XCTAssertFalse(rejected)
        XCTAssertEqual(service.script(id: original.id)?.source, changed.source)
    }

    func testCorruptRollbackFileCannotReplaceActiveSource() async throws {
        let (service, _, directory, suite) = try fixture()
        defer { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: directory) }
        let original = try await install(service)
        guard case .success = await service.install(text: source("2"), source: .paste, sourceUrl: "", replacingId: original.id) else { return XCTFail("update failed") }
        let previous = try XCTUnwrap(service.previousVersion(for: original.id))
        try Data("tampered".utf8).write(to: directory.appendingPathComponent(previous.snapshotHash + ".json"))
        let restored = await service.restorePreviousVersion(for: original.id, expectedHash: previous.snapshotHash)
        XCTAssertFalse(restored)
        XCTAssertEqual(service.script(id: original.id)?.version, "2")
        XCTAssertTrue(service.lastError?.contains("校验") ?? false)
    }

    func testMenuLabelsStayWithinFourCharactersWithoutChangingShortcutData() {
        for action in VelaMenuAction.allCases { XCTAssertLessThanOrEqual(action.title.count, 4) }
        let shortcut = MenuShortcut(title: "这是一个很长的快捷方式名称", url: "https://example.test", symbolName: "star")
        let tile = MenuTile.shortcut(shortcut)
        XCTAssertEqual(tile.menuTitle.count, 4)
        XCTAssertEqual(tile.shortcut?.title, shortcut.title)
    }
}
