import XCTest
import UIKit
@testable import Vela

@MainActor
final class PreviewLifecycleTests: XCTestCase {
    private func image() -> UIImage {
        UIGraphicsImageRenderer(size: CGSize(width: 24, height: 24)).image { context in
            UIColor.red.setFill()
            context.cgContext.fill(CGRect(x: 0, y: 0, width: 24, height: 24))
        }
    }

    func testRemovingPreviewInvalidatesInFlightPreparation() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = TabPreviewStore(directoryOverride: directory)
        let task = store.store(image(), for: "closed")
        store.remove("closed")
        await task.value
        await store.flushFileOperations()
        XCTAssertNil(store.image(for: "closed"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("closed.jpg").path))
    }

    func testClearInvalidatesOldWorkButAllowsNewPreviews() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = TabPreviewStore(directoryOverride: directory)
        let old = store.store(image(), for: "old")
        store.removeAll()
        let fresh = store.store(image(), for: "new")
        await old.value
        await fresh.value
        await store.flushFileOperations()
        XCTAssertNil(store.image(for: "old"))
        XCTAssertNotNil(store.image(for: "new"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("old.jpg").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: directory.appendingPathComponent("new.jpg").path))
    }

    func testMemoryOnlyPreviewDoesNotCreateFileAndDeleteWins() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = TabPreviewStore(directoryOverride: directory)
        await store.store(image(), for: "private", persistToDisk: false).value
        XCTAssertNotNil(store.image(for: "private"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("private.jpg").path))
        await store.store(image(), for: "regular").value
        store.remove("regular")
        XCTAssertNil(store.image(for: "regular"), "a pending deletion must also block synchronous disk fallback")
        await store.flushFileOperations()
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("regular.jpg").path))
    }

    func testPrivateSnapshotArrivingAfterCloseIsRejected() async throws {
        let harness = try BrowserHarness()
        let tab = harness.tabManager.openTab(url: URL(string: "about:blank")!, privacyMode: .private)
        var reply: CheckedContinuation<UIImage?, Never>?
        let task = try XCTUnwrap(harness.tabManager.capturePreview(for: tab.id) { _ in
            await withCheckedContinuation { reply = $0 }
        })
        await waitUntil("snapshot request started") { reply != nil }
        harness.tabManager.closeTab(id: tab.id)
        reply?.resume(returning: image())
        await task.value
        XCTAssertNil(harness.tabManager.preview(for: tab.id))
    }

    func testSnapshotArrivingAfterRetentionClearIsRejected() async throws {
        let harness = try BrowserHarness()
        let tab = harness.open(URL(string: "about:blank")!)
        var reply: CheckedContinuation<UIImage?, Never>?
        let task = try XCTUnwrap(harness.tabManager.capturePreview(for: tab.id) { _ in
            await withCheckedContinuation { reply = $0 }
        })
        await waitUntil("snapshot request started") { reply != nil }
        harness.tabManager.discardRetainedTabData()
        reply?.resume(returning: image())
        await task.value
        XCTAssertNil(harness.tabManager.preview(for: tab.id))
    }
}
