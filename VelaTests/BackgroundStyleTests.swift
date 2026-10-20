//
//  BackgroundStyleTests.swift
//  VelaTests
//
//  What the global background starts as, and what the stored names mean.
//
//  These are small assertions about a preference, but the preference decides
//  what a brand-new install looks like before the user has touched anything:
//  no stored value must land on 纯净 rather than on one of the fields.
//

import XCTest
@testable import Vela

final class BackgroundStyleTests: XCTestCase {
    /// A fresh install has no stored value; it has to start on the plain
    /// surface, not on an ambient field.
    func testNoStoredValueResolvesToSolid() {
        XCTAssertEqual(BrowserBackgroundStyle.resolve(nil), .solid)
    }

    /// A name that no longer exists falls back to the plain surface, while the
    /// retired names keep the choice they stood for.
    func testStoredNamesResolveByRole() {
        XCTAssertEqual(BrowserBackgroundStyle.resolve("no-such-field"), .solid)
        XCTAssertEqual(BrowserBackgroundStyle.resolve("amber"), .sunrise)
        XCTAssertEqual(BrowserBackgroundStyle.resolve("midnight"), .glacier)
        XCTAssertEqual(BrowserBackgroundStyle.resolve("solid"), .solid)
    }

    /// 缤纷 is a real field: it round-trips through its stored name, it is
    /// offered by the picker, and it paints more than the palette surface.
    func testColorfulIsAField() {
        XCTAssertEqual(BrowserBackgroundStyle(rawValue: "colorful"), .colorful)
        XCTAssertEqual(BrowserBackgroundStyle.resolve("colorful"), .colorful)
        XCTAssertTrue(BrowserBackgroundStyle.allCases.contains(.colorful))
        XCTAssertTrue(BrowserBackgroundStyle.colorful.usesAmbient)
        XCTAssertFalse(BrowserBackgroundStyle.solid.usesAmbient)
    }
}
