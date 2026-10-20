//
//  OfflineAndTranslationTests.swift
//  VelaTests
//
//  The pure values the two new features build on: page identity for the
//  offline shelf, and the settings that choose a translation backend.
//

import XCTest
@testable import Vela

final class OfflineAndTranslationTests: XCTestCase {
    @MainActor
    func testOfflineUrlNormalizationDropsTheFragment() {
        let normalized = OfflinePageService.normalizedUrlString(
            "HTTPS://Example.COM/Path?q=1#section"
        )
        XCTAssertEqual(normalized, "https://example.com/Path?q=1")
    }

    @MainActor
    func testOfflineUrlNormalizationGivesABareHostAPath() {
        let normalized = OfflinePageService.normalizedUrlString("https://example.com")
        XCTAssertEqual(normalized, "https://example.com/")
    }

    @MainActor
    func testOfflineHashIsStableAndDistinguishesUrls() {
        let first = OfflinePageService.hash("https://example.com/a")
        let second = OfflinePageService.hash("https://example.com/a")
        let other = OfflinePageService.hash("https://example.com/b")
        XCTAssertEqual(first, second)
        XCTAssertNotEqual(first, other)
        XCTAssertEqual(first.count, 64)
    }

    func testTranslationSettingsUseProviderDefaults() {
        let google = TranslationSettings(provider: .google)
        XCTAssertEqual(google.resolvedEndpoint, TranslationProviderKind.google.defaultEndpoint)
        XCTAssertTrue(google.isUsable)

        let deepL = TranslationSettings(provider: .deepL)
        XCTAssertFalse(deepL.isUsable)

        let chat = TranslationSettings(provider: .openAICompatible, apiKey: "key")
        XCTAssertEqual(chat.resolvedModel, TranslationProviderKind.openAICompatible.defaultModel)
        XCTAssertTrue(chat.isUsable)
    }

    func testTranslationTargetKeepsItsCodeAcrossProviders() {
        XCTAssertEqual(TranslationTargetLanguage.simplifiedChinese.googleCode, "zh-CN")
        XCTAssertEqual(TranslationTargetLanguage.simplifiedChinese.deepLCode, "ZH")
        XCTAssertEqual(TranslationTargetLanguage.traditionalChinese.deepLCode, "ZH-HANT")
    }
}
