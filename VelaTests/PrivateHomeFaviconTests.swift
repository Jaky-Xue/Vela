import XCTest
@testable import Vela

@MainActor
final class PrivateHomeFaviconTests: XCTestCase {
    func testPrivateHomeAllowsOnlySiteCandidates() {
        let urls = SiteIconView.candidates(host: "example.com", faviconUrl: "https://www.google.com/s2/favicons?domain=example.com", allowsThirdParty: false).compactMap { $0 }
        XCTAssertFalse(urls.isEmpty)
        XCTAssertTrue(urls.allSatisfy { $0.host == "example.com" })
    }
    func testRegularHomeRetainsGoogleFallback() {
        XCTAssertTrue(SiteIconView.candidates(host: "example.com", faviconUrl: nil, allowsThirdParty: true).compactMap { $0 }.contains { $0.host == "www.google.com" })
    }
}
