//
//  TranslationParsingTests.swift
//  VelaTests
//
//  Provider answers differ in where the translated text and the detected
//  language live. These tests pin the adapters so a 429 workaround or a new
//  endpoint shape cannot silently turn a translated page into an empty one.
//

import XCTest
@testable import Vela

final class TranslationParsingTests: XCTestCase {
    func testGoogleArrayShape() throws {
        let data = #"[[["你好","Hello",null,null,10]],null,"en"]"#.data(using: .utf8)!
        let parsed = try TranslationService.parseGoogleResponse(data)
        XCTAssertEqual(parsed.html, "你好")
        XCTAssertEqual(parsed.detectedLanguage, "en")
    }

    func testGoogleDictionaryShape() throws {
        let data = #"{"translatedText":"你好"}"#.data(using: .utf8)!
        let parsed = try TranslationService.parseGoogleResponse(data)
        XCTAssertEqual(parsed.html, "你好")
        XCTAssertNil(parsed.detectedLanguage)

        let sentences = #"{"sentences":[["你好","Hello"]],"src":"en"}"#.data(using: .utf8)!
        let second = try TranslationService.parseGoogleResponse(sentences)
        XCTAssertEqual(second.html, "你好")
        XCTAssertEqual(second.detectedLanguage, "en")
    }

    func testGoogleDetectedLanguageCanLiveAtTheEnd() throws {
        let data = #"[[["你好","Hello"]],null,null,null,null,null,null,null,[["en"]]]"#
            .data(using: .utf8)!
        XCTAssertEqual(try TranslationService.parseGoogleResponse(data).detectedLanguage, "en")
    }

    func testGoogleEmptyAnswerIsAReportableFailure() {
        let data = #"[[[]],null,"en"]"#.data(using: .utf8)!
        XCTAssertThrowsError(try TranslationService.parseGoogleResponse(data))
    }

    func testLanguageTagsAreNormalised() {
        XCTAssertEqual(TranslationService.normalizedLanguageCode("zh-Hant-TW"), "zh-TW")
        XCTAssertEqual(TranslationService.normalizedLanguageCode("zh_Hans_CN"), "zh-CN")
        XCTAssertEqual(TranslationService.normalizedLanguageCode("en-US"), "en")
        XCTAssertEqual(TranslationService.normalizedLanguageCode("iw"), "he")
        XCTAssertEqual(TranslationService.normalizedLanguageCode("in-ID"), "id")
    }

    func testDeclaredPageLanguageBeatsAShortSample() {
        let detected = TranslationService.detected(fromLanguageTag: "zh-Hant-TW")
        XCTAssertEqual(detected?.code, "zh-TW")
        XCTAssertEqual(detected?.confidence, 0.85)
        XCTAssertNil(TranslationService.detected(fromLanguageTag: "123"))
    }

    func testRateLimitedMessageIsActionable() {
        let message = TranslationError.rateLimited(12).localizedDescription
        XCTAssertTrue(message.contains("429"))
        XCTAssertTrue(message.contains("12"))
        XCTAssertTrue(message.contains("服务商"))
    }

    func testOpenAIContentShapes() {
        let message: [String: Any] = ["message": ["content": "你好"]]
        XCTAssertEqual(TranslationService.openAIContent(from: message), "你好")

        let text: [String: Any] = ["text": "你好"]
        XCTAssertEqual(TranslationService.openAIContent(from: text), "你好")

        let parts: [String: Any] = [
            "message": [
                "content": [
                    ["type": "text", "text": "你"],
                    ["type": "text", "text": "好"]
                ]
            ]
        ]
        XCTAssertEqual(TranslationService.openAIContent(from: parts), "你好")
    }
}
