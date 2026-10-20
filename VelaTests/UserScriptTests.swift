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

    func testMetadataBlockKeepsUnknownKeysVerbatim() throws {
        // The editor shows the block the user installed, not a rebuild from the
        // parsed fields — so an `@key` the parser does not capture (here
        // `@author`) survives into the editor instead of reading as truncated.
        let text = """
        // ==UserScript==
        // @name Keeps Unknown Keys
        // @namespace vela.tests
        // @match https://example.com/*
        // @author Anon
        // @grant none
        // ==/UserScript==
        console.log('body');
        """
        let result = UserScriptParser.parse(text)
        XCTAssertTrue(result.valid)
        let candidate = try XCTUnwrap(result.candidate)
        XCTAssertTrue(candidate.metadataBlock.hasPrefix("// ==UserScript=="))
        XCTAssertTrue(candidate.metadataBlock.hasSuffix("// ==/UserScript=="))
        XCTAssertTrue(candidate.metadataBlock.contains("// @author Anon"))
        XCTAssertEqual(candidate.source, "console.log('body');")
    }

    func testEditableSourceRebuildsMetadataForAStoredBody() throws {
        // An installed script stores only its body; the editor must still get
        // a document that parses, or every save fails as "not a user script".
        let script = InstalledUserScriptState(
            name: "Editable",
            namespace: "vela.tests",
            version: "2.0",
            description: "line one\nline two",
            source: "window.__velaEditedBody = 1;",
            matches: ["https://example.com/*"],
            grants: [.none],
            requireUrls: ["https://cdn.example.com/lib.js"],
            runAt: .documentStart
        )
        let text = UserScriptService.reconstructedSource(for: script)
        XCTAssertTrue(text.hasPrefix("// ==UserScript=="))
        XCTAssertTrue(text.contains("// @name Editable"))
        XCTAssertTrue(text.contains("// @match https://example.com/*"))
        XCTAssertTrue(text.contains("// @require https://cdn.example.com/lib.js"))
        XCTAssertFalse(text.contains("// @grant none"))
        XCTAssertTrue(text.contains("window.__velaEditedBody = 1;"))

        let parsed = UserScriptParser.parse(text)
        XCTAssertTrue(parsed.valid)
        let candidate = try XCTUnwrap(parsed.candidate)
        XCTAssertEqual(candidate.name, "Editable")
        XCTAssertEqual(candidate.matches, ["https://example.com/*"])
        XCTAssertTrue(candidate.source.contains("window.__velaEditedBody = 1;"))
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
        XCTAssertTrue(source.contains("bridge.resolve = function"))
    }
}
