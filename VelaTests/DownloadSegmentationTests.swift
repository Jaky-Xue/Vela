//
//  DownloadSegmentationTests.swift
//  VelaTests
//
//  The segment planner must cover every byte exactly once; a gap would write a
//  corrupt file and an overlap would duplicate part of it.
//

import XCTest
@testable import Vela

final class DownloadSegmentationTests: XCTestCase {
    func testSegmentsCoverEveryByteExactlyOnce() {
        let total: Int64 = 10_000_003
        let segments = SegmentedDownloadSession.makeSegments(totalBytes: total, count: 4)
        XCTAssertEqual(segments.count, 4)
        XCTAssertEqual(segments.first?.start, 0)
        XCTAssertEqual(segments.last?.end, total - 1)
        XCTAssertEqual(segments.reduce(Int64(0)) { $0 + $1.length }, total)

        for pair in zip(segments, segments.dropFirst()) {
            XCTAssertEqual(pair.0.end + 1, pair.1.start)
        }
    }

    func testUnknownLengthIsOneWholeFileSegment() {
        let segments = SegmentedDownloadSession.makeSegments(totalBytes: 0, count: 4)
        XCTAssertEqual(segments.count, 1)
        XCTAssertEqual(segments[0].start, 0)
        XCTAssertEqual(segments[0].end, 0)
    }

    func testSegmentCountIsClamped() {
        XCTAssertLessThanOrEqual(
            SegmentedDownloadSession.makeSegments(totalBytes: 100_000_000, count: 99).count,
            8
        )
        XCTAssertEqual(
            SegmentedDownloadSession.makeSegments(totalBytes: 100_000_000, count: 0).count,
            1
        )
    }

    func testDownloadSettingsDefaults() {
        let settings = DownloadSettings.default
        XCTAssertTrue(settings.usesSegmentedDownloads)
        XCTAssertEqual(settings.segmentCount, 4)
        XCTAssertEqual(settings.maxConcurrentDownloadCount, 2)
    }
}
