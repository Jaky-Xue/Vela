//
//  SiteIconDiscoveryTests.swift
//  VelaTests
//
//  A site's own markup names the icons it publishes. The tile reads those
//  names so it can fetch the 180- or 512-pixel rendition instead of
//  upscaling a 32-pixel `.ico` found at a guessed path.
//

import XCTest
@testable import Vela

private actor DiscoveryFetchCounter {
    private(set) var count = 0
    func record() -> Int {
        count += 1
        return count
    }
}

final class SiteIconDiscoveryTests: XCTestCase {
    private let pageURL = URL(string: "https://example.com/news/index.html")!

    // MARK: - Reading a page

    func testDeclaredIconsComeLargestFirst() {
        let html = """
        <html><head>
        <link rel="icon" sizes="32x32" href="/icon-32.png">
        <link rel="apple-touch-icon" sizes="180x180" href="/touch.png">
        <link rel="icon" sizes="512x512" href="/icon-512.png">
        </head></html>
        """

        let urls = SiteIconDiscovery
            .sorted(SiteIconDiscovery.declaredIcons(inHTML: html, baseURL: pageURL))
            .map(\.absoluteString)

        XCTAssertEqual(urls, [
            "https://example.com/icon-512.png",
            "https://example.com/touch.png",
            "https://example.com/icon-32.png"
        ])
    }

    func testRelativeAndProtocolRelativeHrefsResolve() {
        let html = """
        <link rel="shortcut icon" href="icons/app.png">
        <link rel="apple-touch-icon-precomposed" href="//cdn.example.net/touch.png">
        """

        let urls = SiteIconDiscovery
            .declaredIcons(inHTML: html, baseURL: pageURL)
            .map(\.url.absoluteString)

        XCTAssertEqual(urls, [
            "https://example.com/news/icons/app.png",
            "https://cdn.example.net/touch.png"
        ])
    }

    func testAnSVGIsSkipped() {
        let html = """
        <link rel="icon" type="image/svg+xml" href="/icon.svg">
        <link rel="mask-icon" href="/mask.svg">
        <link rel="icon" href="/icon.png" sizes="96x96">
        """

        let urls = SiteIconDiscovery
            .declaredIcons(inHTML: html, baseURL: pageURL)
            .map(\.url.absoluteString)

        XCTAssertEqual(urls, ["https://example.com/icon.png"])
    }

    func testOnlyIconLinksAreTaken() {
        let html = """
        <link rel="stylesheet" href="/site.css">
        <link rel="preload" href="/font.woff2" sizes="512x512">
        <link rel="icon" href="data:image/png;base64,AAAA">
        <link rel="icon" href="/icon.png">
        """

        let urls = SiteIconDiscovery
            .declaredIcons(inHTML: html, baseURL: pageURL)
            .map(\.url.absoluteString)

        XCTAssertEqual(urls, ["https://example.com/icon.png"])
    }

    func testASingleQuotedAttributeIsRead() {
        let html = "<link rel='icon' href='/single.png' sizes='128x128'>"

        let urls = SiteIconDiscovery
            .declaredIcons(inHTML: html, baseURL: pageURL)
            .map(\.url.absoluteString)

        XCTAssertEqual(urls, ["https://example.com/single.png"])
    }

    func testAnUndeclaredSizeSortsAfterTheSizedOnes() {
        let html = """
        <link rel="icon" href="/unknown.png">
        <link rel="icon" sizes="64x64" href="/small.png">
        """

        let urls = SiteIconDiscovery
            .sorted(SiteIconDiscovery.declaredIcons(inHTML: html, baseURL: pageURL))
            .map(\.absoluteString)

        XCTAssertEqual(urls, ["https://example.com/small.png", "https://example.com/unknown.png"])
    }

    // MARK: - Reading a manifest

    func testAManifestIsFoundAndItsIconsAreRead() {
        let html = """
        <link rel="manifest" href="/site.webmanifest">
        <link rel="icon" sizes="32x32" href="/icon-32.png">
        """

        let manifest = SiteIconDiscovery.manifestURL(inHTML: html, baseURL: pageURL)
        XCTAssertEqual(manifest?.absoluteString, "https://example.com/site.webmanifest")

        let json = """
        {"icons":[
          {"src":"/icon-192.png","sizes":"192x192","type":"image/png"},
          {"src":"/icon.svg","sizes":"any","type":"image/svg+xml"},
          {"src":"https://cdn.example.net/icon-512.png","sizes":"512x512","type":"image/png"}
        ]}
        """
        let icons = SiteIconDiscovery.declaredIcons(
            inManifest: Data(json.utf8),
            baseURL: URL(string: "https://example.com/site.webmanifest")!
        )

        XCTAssertEqual(
            SiteIconDiscovery.sorted(icons).map(\.absoluteString),
            ["https://cdn.example.net/icon-512.png", "https://example.com/icon-192.png"]
        )
    }

    // MARK: - Discovery is one request per host

    func testOnePageFetchPerHostAndTheManifestIsFollowed() async {
        let counter = DiscoveryFetchCounter()
        let manifestURL = "https://example.com/site.webmanifest"
        let discovery = SiteIconDiscovery(fetch: { url in
            _ = await counter.record()
            if url.absoluteString == manifestURL {
                let json = "{\"icons\":[{\"src\":\"/big.png\",\"sizes\":\"512x512\"}]}"
                return (Data(json.utf8), url)
            }
            let html = """
            <link rel="manifest" href="/site.webmanifest">
            <link rel="icon" sizes="32x32" href="/small.png">
            """
            return (Data(html.utf8), url)
        })

        let first = await discovery.iconUrls(forHost: "example.com")
        XCTAssertEqual(first.map(\.absoluteString), [
            "https://example.com/big.png",
            "https://example.com/small.png"
        ])

        // A second tile of the same host — however the host is spelled — is
        // answered from the first read.
        let second = await discovery.iconUrls(forHost: "Example.COM")
        XCTAssertEqual(second, first)
        let count = await counter.count
        XCTAssertEqual(count, 2, "one page and one manifest, then nothing")
    }

    func testAPageThatDeclaresNothingIsRemembered() async {
        let counter = DiscoveryFetchCounter()
        let discovery = SiteIconDiscovery(fetch: { url in
            _ = await counter.record()
            return (Data("<html><head></head></html>".utf8), url)
        })

        let first = await discovery.iconUrls(forHost: "example.com")
        let second = await discovery.iconUrls(forHost: "example.com")
        XCTAssertEqual(first, [])
        XCTAssertEqual(second, [])
        let count = await counter.count
        XCTAssertEqual(count, 1, "an empty answer must not be re-fetched")
    }

    func testAFailedPageAnswersNothing() async {
        let discovery = SiteIconDiscovery(fetch: { _ in nil })
        let urls = await discovery.iconUrls(forHost: "example.com")
        XCTAssertEqual(urls, [])
    }
}
