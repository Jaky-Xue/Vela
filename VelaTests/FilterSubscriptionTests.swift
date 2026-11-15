import XCTest
import Foundation
@testable import Vela

private final class FilterFixtureProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var status = 200
    nonisolated(unsafe) static var body = "||fixture-ad.test^"
    nonisolated(unsafe) static var etag: String? = "fixture-v1"
    nonisolated(unsafe) static var seenETag: String?
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "filters.fixture.test" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.seenETag = request.value(forHTTPHeaderField: "If-None-Match")
        var headers = ["Content-Type": "text/plain"]
        if let etag = Self.etag { headers["ETag"] = etag }
        let response = HTTPURLResponse(url: request.url!, statusCode: Self.status, httpVersion: "HTTP/1.1", headerFields: headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        if Self.status != 304 { client?.urlProtocol(self, didLoad: Data(Self.body.utf8)) }
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

@MainActor
final class FilterSubscriptionTests: XCTestCase {
    func testConditionalUpdateOfflineCacheAndInvalidResponseRollback() async throws {
        let suite = "Subscription-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: directory) }
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [FilterFixtureProtocol.self]
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        let settings = SettingsService(defaults: defaults)
        let blocker = ContentBlocker(settings: settings, cacheDirectory: directory, session: session)
        FilterFixtureProtocol.status = 200
        FilterFixtureProtocol.body = "||fixture-ad.test^"
        let added = await blocker.addSubscription(name: "Fixture", url: "https://filters.fixture.test/list")
        XCTAssertTrue(added)
        let source = try XCTUnwrap(settings.contentBlocker.subscriptions?.first)
        let hash = try XCTUnwrap(source.cacheHash)
        let count = blocker.ruleCount
        FilterFixtureProtocol.status = 304
        await blocker.refreshSubscriptions()
        XCTAssertEqual(FilterFixtureProtocol.seenETag, "fixture-v1")
        XCTAssertEqual(settings.contentBlocker.subscriptions?.first?.cacheHash, hash)
        XCTAssertEqual(blocker.ruleCount, count)
        FilterFixtureProtocol.status = 200
        FilterFixtureProtocol.body = "<!DOCTYPE html><html><body>login</body></html>"
        await blocker.refreshSubscriptions()
        XCTAssertEqual(settings.contentBlocker.subscriptions?.first?.cacheHash, hash)
        XCTAssertNotNil(settings.contentBlocker.subscriptions?.first?.error)
        XCTAssertEqual(blocker.ruleCount, count)
        XCTAssertTrue(blocker.isReady)
        await blocker.setSubscription(source.id, enabled: false)
        XCTAssertEqual(settings.contentBlocker.subscriptions?.first?.enabled, false)
        XCTAssertEqual(blocker.ruleCount, count - 1)
        let persisted = SettingsService(defaults: defaults)
        XCTAssertEqual(persisted.contentBlocker.subscriptions?.first?.cacheHash, hash)
    }
}
