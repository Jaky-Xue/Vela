//
//  PrivateSessionLedgerTests.swift
//  VelaTests
//
//  T-12: an end request carries the generation of the session that made it.
//  A delayed request from an older session must run no actions at all, so it
//  cannot close a newer session's tabs or release its novel service/store.
//

import XCTest
@testable import Vela

@MainActor
final class PrivateSessionLedgerTests: XCTestCase {
    func testDelayedEndForAnOldPrivateSessionRunsNoActions() {
        // The old session was generation 1; a new one has already begun and
        // advanced the generation to 2.
        let currentGeneration = 2
        var actions = 0

        let next = PrivateSessionLedger.end(
            expectedGeneration: 1,
            currentGeneration: currentGeneration
        ) {
            actions += 1
        }

        XCTAssertNil(next, "a stale end must not produce a next generation")
        XCTAssertEqual(actions, 0, "a stale end must not close tabs, clear downloads or release the service")
    }

    func testEndForTheCurrentPrivateSessionRunsActionsAndAdvances() {
        let currentGeneration = 2
        var actions = 0

        let next = PrivateSessionLedger.end(
            expectedGeneration: currentGeneration,
            currentGeneration: currentGeneration
        ) {
            actions += 1
        }

        XCTAssertEqual(next ?? -1, 3)
        XCTAssertEqual(actions, 1)

        // A duplicate of the same request, arriving after the first end,
        // belongs to the old generation and is a no-op.
        let duplicate = PrivateSessionLedger.end(
            expectedGeneration: currentGeneration,
            currentGeneration: 3
        ) {
            actions += 1
        }
        XCTAssertNil(duplicate)
        XCTAssertEqual(actions, 1)
    }
}
