//
//  SiteIconCandidateTests.swift
//  VelaTests
//
//  A private tab must keep its host away from the third-party favicon service.
//  The candidate list is pure, so the policy is tested without a network call.
//

import XCTest
@testable import Vela

@MainActor
final class SiteIconCandidateTests: XCTestCase {
    private func strings(_ urls: [URL?]) -> Set<String> {
        Set(urls.compactMap { $0?.absoluteString })
    }

    func testRegularIconsKeepTheThirdPartyFallback() {
        let candidates = strings(
            SiteIconView.candidates(
                host: "example.com",
                faviconUrl: nil,
                allowsThirdParty: true
            )
        )
        XCTAssertTrue(candidates.contains("https://www.google.com/s2/favicons?sz=256&domain=example.com"))
        XCTAssertTrue(candidates.contains("https://example.com/apple-touch-icon.png"))
        XCTAssertTrue(candidates.contains("https://example.com/favicon.ico"))
    }

    func testPrivateIconsDropTheThirdPartyFallback() {
        let candidates = strings(
            SiteIconView.candidates(
                host: "example.com",
                faviconUrl: nil,
                allowsThirdParty: false
            )
        )
        XCTAssertFalse(candidates.contains { $0.contains("google.com") })
        XCTAssertTrue(candidates.contains("https://example.com/apple-touch-icon.png"))
        XCTAssertTrue(candidates.contains("https://example.com/favicon.ico"))
    }

    func testPrivateIconsKeepOnlySameHostExplicitIcons() {
        let sameHost = strings(
            SiteIconView.candidates(
                host: "example.com",
                faviconUrl: "https://example.com/icon.png",
                allowsThirdParty: false
            )
        )
        XCTAssertTrue(sameHost.contains("https://example.com/icon.png"))

        let thirdParty = strings(
            SiteIconView.candidates(
                host: "example.com",
                faviconUrl: "https://cdn.example.net/icon.png",
                allowsThirdParty: false
            )
        )
        XCTAssertFalse(thirdParty.contains("https://cdn.example.net/icon.png"))
    }
}
