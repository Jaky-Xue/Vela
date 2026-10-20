//
//  UserScriptTests.swift
//  VelaTests
//
//  The script manager's pure decisions: version ordering, dependency metadata,
//  and the bootstrap the web view receives.
//

import XCTest
@testable import Vela

@MainActor
final class UserScriptTests: XCTestCase {
    func testVersionComparisonUsesNumericSegments() {
        XCTAssertTrue(UserScriptService.isNewer("1.10", than: "1.9"))
        XCTAssertTrue(UserScriptService.isNewer("2.0.1", than: "2.0"))
        XCTAssertFalse(UserScriptService.isNewer("1.0", than: "1.0"))
        XCTAssertFalse(UserScriptService.isNewer("1.0", than: "1.1"))
        XCTAssertTrue(UserScriptService.isNewer("1.1", than: ""))
        XCTAssertFalse(UserScriptService.isNewer("", than: "1.1"))
    }

    func testMetadataKeepsRequireAndResourceDeclarations() throws {
        let text = """
        // ==UserScript==
        // @name Test Script
        // @namespace vela.tests
        // @version 1.2.3
        // @match https://example.com/*
        // @require https://cdn.example.com/lib.js
        // @resource logo https://cdn.example.com/logo.png
        // @grant GM_xmlhttpRequest
        // ==/UserScript==
        console.log('hello');
        """
        let result = UserScriptParser.parse(text)
        XCTAssertTrue(result.valid)
        let candidate = try XCTUnwrap(result.candidate)
        XCTAssertEqual(candidate.requireUrls, ["https://cdn.example.com/lib.js"])
        XCTAssertEqual(candidate.resourceDeclarations.count, 1)
        XCTAssertEqual(candidate.resourceDeclarations.first?.name, "logo")
        XCTAssertTrue(candidate.grants.contains(.gmXmlhttpRequest))
        XCTAssertTrue(UserScriptGrant.gmXmlhttpRequest.isSupportedByVela)
    }

    func testBootstrapIncludesRequirementsResourcesAndBridge() throws {
        let script = InstalledUserScriptState(
            name: "Injection Test",
            version: "1.0",
            source: "window.__velaBodyRan = true;",
            matches: ["*://*/*"],
            grants: [.gmXmlhttpRequest],
            requireUrls: ["https://cdn.example.com/lib.js"],
            requireSources: ["var __velaRequiredMarker = 42;"],
            resourceDeclarations: [
                UserScriptResourceDeclaration(name: "logo", url: "https://cdn.example.com/logo.png")
            ],
            resources: [
                UserScriptResourceRecord(
                    name: "logo",
                    url: "https://cdn.example.com/logo.png",
                    mimeType: "image/png",
                    contentBase64: "aGVsbG8="
                )
            ],
            runAt: .documentStart
        )
        let built = UserScriptInjector.makeUserScripts(
            for: [script],
            url: try XCTUnwrap(URL(string: "https://example.com/")),
            valuesByScriptId: [:],
            tabId: "tab-1"
        )
        XCTAssertEqual(built.scripts.count, 1)
        let source = try XCTUnwrap(built.scripts.first?.source)
        XCTAssertTrue(source.contains("__velaRequiredMarker"))
        XCTAssertTrue(source.contains("window.__velaBodyRan = true;"))
        XCTAssertTrue(source.contains("GM_xmlhttpRequest"))
        XCTAssertTrue(source.contains("GM_getResourceURL"))
        XCTAssertTrue(source.contains("tab-1"))
        XCTAssertTrue(source.contains("resolve(scriptId, requestId, payload)"))
    }
}
