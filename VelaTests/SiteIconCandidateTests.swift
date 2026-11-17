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

    /// A page's declared icons outrank the fixed-path guesses, and the
    /// favicon service stays behind them: it answers with a small favicon
    /// upscaled to whatever size was asked for, which reads as sharp and
    /// looks like mush.
    func testDeclaredIconsComeAfterThePageIconAndBeforeTheGuesses() {
        let declared = [
            URL(string: "https://example.com/icon-512.png")!,
            URL(string: "https://example.com/icon-192.png")!
        ]
        let urls = SiteIconView.candidates(
            host: "example.com",
            faviconUrl: "https://example.com/page-icon.png",
            allowsThirdParty: true,
            declaredIcons: declared
        ).compactMap { $0?.absoluteString }

        XCTAssertEqual(Array(urls.prefix(3)), [
            "https://example.com/page-icon.png",
            "https://example.com/icon-512.png",
            "https://example.com/icon-192.png"
        ])
        let service = urls.firstIndex(of: "https://www.google.com/s2/favicons?sz=256&domain=example.com")
        let touch = urls.firstIndex(of: "https://example.com/apple-touch-icon.png")
        XCTAssertNotNil(service)
        XCTAssertNotNil(touch)
        XCTAssertGreaterThan(service ?? 0, touch ?? 0)
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
