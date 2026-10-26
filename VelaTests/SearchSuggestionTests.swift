//
//  SearchSuggestionTests.swift
//  VelaTests
//
//  The network suggestion layer that does not need a network: the endpoint
//  table and the response shapes. Both are pure, and both are where a provider
//  change would surface first.
//

import CoreFoundation
import Foundation
import XCTest
@testable import Vela

final class SearchSuggestionTests: XCTestCase {
    // MARK: - Endpoints

    func testKnownEnginesHaveASuggestionEndpoint() {
        for engine in ["bing", "google", "duckduckgo", "baidu", "qihoo", "sogou", "shenma", "yandex"] {
            XCTAssertNotNil(
                SearchSuggestionProvider(engineId: engine)?.url(for: "北京"),
                "\(engine) should have an endpoint"
            )
        }
    }

    func testCustomEngineHasNoEndpoint() {
        XCTAssertNil(SearchSuggestionProvider(engineId: "custom-123"))
    }

    func testBingCarriesTheQueryAsAQueryItem() throws {
        let url = try XCTUnwrap(SearchSuggestionProvider.bing.url(for: "iphone 18"))
        XCTAssertEqual(url.host, "www.bing.com")
        let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?
            .first(where: { $0.name == "query" })
        XCTAssertEqual(query?.value, "iphone 18")
    }

    func testBaiduUsesTheJsonVariant() throws {
        let url = try XCTUnwrap(SearchSuggestionProvider.baidu.url(for: "北京"))
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        XCTAssertEqual(items.first(where: { $0.name == "json" })?.value, "1")
        XCTAssertEqual(items.first(where: { $0.name == "wd" })?.value, "北京")
    }

    // MARK: - Responses

    func testPairResponse() {
        let data = Data(#"["iphone",["iphone 18","iphone 17"],[],{"google:suggestsubtypes":[[1]]}]"#.utf8)
        XCTAssertEqual(
            SearchSuggestionParser.parse(data: data, charset: "utf-8"),
            ["iphone 18", "iphone 17"]
        )
    }

    func testCallbackWrappedPairResponse() {
        let data = Data(#"window.sogou.sug(["iphone",["iphone 18","iphone 17"],["0;15"],[""]]);"#.utf8)
        XCTAssertEqual(
            SearchSuggestionParser.parse(data: data, charset: "utf-8"),
            ["iphone 18", "iphone 17"]
        )
    }

    func testCallbackWrappedObjectResponse() {
        let data = Data(#"window.baidu.sug({"q":"iphone","p":false,"s":["iphone 18","iphone 17"]});"#.utf8)
        XCTAssertEqual(
            SearchSuggestionParser.parse(data: data, charset: "utf-8"),
            ["iphone 18", "iphone 17"]
        )
    }

    func testResultObjectResponse() {
        let data = Data(
            #"{"errorcode":0,"result":[{"word":"iphone 官网"},{"word":"iphone 18"}]}"#.utf8
        )
        XCTAssertEqual(
            SearchSuggestionParser.parse(data: data, charset: "utf-8"),
            ["iphone 官网", "iphone 18"]
        )
    }

    func testPhraseObjectResponse() {
        let data = Data(#"[{"phrase":"iphone 18"},{"phrase":"iphone 17"}]"#.utf8)
        XCTAssertEqual(
            SearchSuggestionParser.parse(data: data, charset: "utf-8"),
            ["iphone 18", "iphone 17"]
        )
    }

    func testGBKResponseDecodesChineseSuggestions() throws {
        let json = #"{"q":"北京","s":["北京天气","北京时间"]}"#
        let data = try XCTUnwrap(gbkData(json))
        XCTAssertEqual(
            SearchSuggestionParser.parse(data: data, charset: "GBK"),
            ["北京天气", "北京时间"]
        )
    }

    func testMalformedResponseIsEmptyRatherThanACrash() {
        let data = Data("<html>blocked</html>".utf8)
        XCTAssertEqual(SearchSuggestionParser.parse(data: data, charset: "utf-8"), [])
    }

    // MARK: - Sanitising

    func testSanitiserDropsTheQueryItselfAndDuplicates() {
        let words = SearchSuggestionParser.sanitize(
            ["iphone", "Iphone", "  iphone 18 ", "", "iphone 18", "iphone 17"],
            query: "iPhone"
        )
        XCTAssertEqual(words, ["iphone 18", "iphone 17"])
    }

    func testSanitiserCapsTheList() {
        let raw = (0..<20).map { "query \($0)" }
        XCTAssertEqual(SearchSuggestionParser.sanitize(raw, query: "q").count, 8)
    }

    private func gbkData(_ string: String) -> Data? {
        let cfEncoding = CFStringConvertIANACharSetNameToEncoding("GBK" as CFString)
        guard cfEncoding != kCFStringEncodingInvalidId else { return nil }
        let encoding = String.Encoding(
            rawValue: CFStringConvertEncodingToNSStringEncoding(cfEncoding)
        )
        return string.data(using: encoding)
    }
}
