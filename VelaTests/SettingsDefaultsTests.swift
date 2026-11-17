//
//  SettingsDefaultsTests.swift
//  VelaTests
//
//  4.0.65 re-tuned three shipped defaults: Google is the engine selected on
//  first launch, 允许双指缩放 is on, and user scripts check for updates on
//  their own. An install that still holds the old shipped values moves over
//  once; a value the user has chosen since is left alone.
//

import XCTest
import Foundation
@testable import Vela

@MainActor
final class SettingsDefaultsTests: XCTestCase {
    private var suiteName = ""
    private var defaults: UserDefaults!

    private let preferencesKey = "org.vela.browser.preferences"
    private let userScriptsKey = "org.vela.browser.userscripts"

    override func setUp() async throws {
        try await super.setUp()
        suiteName = "SettingsDefaultsTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        defaults.removePersistentDomain(forName: suiteName)
    }

    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        try await super.tearDown()
    }

    private func store<T: Encodable>(_ value: T, key: String) throws {
        defaults.set(try JSONEncoder().encode(value), forKey: key)
    }

    private func legacyPreferences(engine: String) -> BrowserPreferences {
        var legacy = BrowserPreferences.default
        legacy.searchEngine.defaultSearchEngineId = engine
        legacy.forcedZoomEnabled = false
        return legacy
    }

    func testAFreshInstallStartsWithGooglePinchZoomAndScriptUpdateChecks() {
        let settings = SettingsService(defaults: defaults)
        XCTAssertEqual(settings.preferences.searchEngine.defaultSearchEngineId, "google")
        XCTAssertEqual(settings.preferences.searchEngine.activeEngine.name, "Google")
        XCTAssertTrue(settings.preferences.allowsPinchZoom)
        XCTAssertTrue(settings.userScriptSettings.autoUpdateEnabled)
    }

    func testTheOldShippedDefaultsMoveOverOnce() throws {
        try store(legacyPreferences(engine: "bing"), key: preferencesKey)
        try store(UserScriptSettings(autoUpdateEnabled: false), key: userScriptsKey)

        let migrated = SettingsService(defaults: defaults)
        XCTAssertEqual(migrated.preferences.searchEngine.defaultSearchEngineId, "google")
        XCTAssertTrue(migrated.preferences.allowsPinchZoom)

        // Written through, not just held in memory for this launch.
        let reloaded = SettingsService(defaults: defaults)
        XCTAssertEqual(reloaded.preferences.searchEngine.defaultSearchEngineId, "google")
        XCTAssertEqual(reloaded.preferences.forcedZoomEnabled, true)
        XCTAssertTrue(reloaded.userScriptSettings.autoUpdateEnabled)
    }

    func testAnEngineTheUserChoseIsNotReplaced() throws {
        try store(legacyPreferences(engine: "duckduckgo"), key: preferencesKey)

        let settings = SettingsService(defaults: defaults)
        XCTAssertEqual(settings.preferences.searchEngine.defaultSearchEngineId, "duckduckgo")
    }

    func testAChangeMadeAfterTheMigrationSurvivesTheNextLaunch() throws {
        try store(legacyPreferences(engine: "bing"), key: preferencesKey)
        _ = SettingsService(defaults: defaults)

        let chosen = SettingsService(defaults: defaults)
        chosen.update { preferences in
            preferences.searchEngine.defaultSearchEngineId = "bing"
            preferences.forcedZoomEnabled = false
        }
        chosen.updateUserScriptSettings { $0.autoUpdateEnabled = false }

        let next = SettingsService(defaults: defaults)
        XCTAssertEqual(next.preferences.searchEngine.defaultSearchEngineId, "bing")
        XCTAssertFalse(next.preferences.allowsPinchZoom)
        XCTAssertFalse(next.userScriptSettings.autoUpdateEnabled)
    }
}
