//
//  DataExchangeTests.swift
//  VelaTests
//
//  The bookmark and history interchange formats, and the ad blocker's
//  whitelist matching. No database, no web view.
//

import XCTest
@testable import Vela

final class DataExchangeTests: XCTestCase {
    func testNetscapeExportAndImportRoundTrip() {
        let bookmark = BookmarkTreeItem(
            node: BookmarkNode(type: .bookmark, title: "Example", url: "https://example.com/"),
            position: 0
        )
        let child = BookmarkTreeItem(
            node: BookmarkNode(type: .bookmark, title: "Child", url: "https://news.example.com/"),
            position: 0
        )
        let folder = BookmarkTreeItem(
            node: BookmarkNode(type: .folder, title: "News"),
            position: 1,
            children: [child]
        )

        let html = BookmarkExchange.netscapeHTML(roots: [("书签栏", [bookmark, folder])])
        let parsed = BookmarkExchange.parseNetscapeHTML(html)

        XCTAssertEqual(parsed.count, 2)
        XCTAssertEqual(parsed[0].url, "https://example.com/")
        XCTAssertEqual(parsed[0].title, "Example")
        XCTAssertEqual(parsed[1].title, "News")
        XCTAssertEqual(parsed[1].children.count, 1)
        XCTAssertEqual(parsed[1].children[0].url, "https://news.example.com/")
    }

    func testImportSkipsNonWebSchemes() {
        let html = """
        <DL><p>
        <DT><A HREF="javascript:alert(1)">bad</A>
        <DT><A HREF="https://example.com/">good</A>
        </DL><p>
        """
        let parsed = BookmarkExchange.parseNetscapeHTML(html)
        XCTAssertEqual(parsed.count, 1)
        XCTAssertEqual(parsed[0].url, "https://example.com/")
    }

    func testImportUnescapesTitles() {
        let html = """
        <DL><p>
        <DT><A HREF="https://example.com/?a=1&amp;b=2">Tom &amp; Jerry &lt;3</A>
        </DL><p>
        """
        let parsed = BookmarkExchange.parseNetscapeHTML(html)
        XCTAssertEqual(parsed.first?.url, "https://example.com/?a=1&b=2")
        XCTAssertEqual(parsed.first?.title, "Tom & Jerry <3")
    }

    func testHistoryJSONRoundTrip() throws {
        let entry = HistoryExchangeEntry(
            url: "https://example.com/",
            title: "Example",
            lastVisitAt: Date(timeIntervalSince1970: 1_700_000_000),
            visitCount: 3
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode([entry])

        let parsed = try HistoryExchange.parse(data)
        XCTAssertEqual(parsed, [entry])
    }

    func testTheBlockerWhitelistCoversSubdomainsAndNotLookalikes() {
        let settings = ContentBlockerSettings(whitelistedHosts: ["example.com"])
        XCTAssertTrue(settings.isExcepted(host: "example.com"))
        XCTAssertTrue(settings.isExcepted(host: "m.example.com"))
        XCTAssertFalse(settings.isExcepted(host: "example.org"))
        XCTAssertFalse(settings.isExcepted(host: "notexample.com"))
    }
}
