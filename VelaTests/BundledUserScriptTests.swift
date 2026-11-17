//
//  BundledUserScriptTests.swift
//  VelaTests
//
//  Vela ships one user script — Immersive Translate — and installs it once on
//  the first launch. This checks the half a unit test can check: the file is
//  in the app bundle, and it is a script the installer can read.
//

import XCTest
@testable import Vela

final class BundledUserScriptTests: XCTestCase {
    func testImmersiveTranslateShipsWithTheApp() throws {
        let url = try XCTUnwrap(
            Bundle(for: AppServices.self).url(
                forResource: "ImmersiveTranslate.user",
                withExtension: "js"
            ),
            "the bundled userscript must be copied into the app bundle"
        )
        let text = try String(contentsOf: url, encoding: .utf8)
        XCTAssertGreaterThan(text.count, 100_000, "the bundled script must be the real file, not a stub")

        let result = UserScriptParser.parse(text, installSource: .file)
        XCTAssertTrue(result.valid)
        let candidate = try XCTUnwrap(result.candidate)
        XCTAssertEqual(candidate.name, "Immersive Translate: AI Web, PDF & Video Translator")
        XCTAssertTrue(candidate.matches.contains("*://*/*"))
        XCTAssertFalse(candidate.updateUrl.isEmpty)
    }
}
