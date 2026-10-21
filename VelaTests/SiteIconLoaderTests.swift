//
//  SiteIconLoaderTests.swift
//  VelaTests
//
//  A favicon URL is fetched once even when several tiles ask at the same time,
//  and a URL that failed is not hammered again on the next appearance.
//

import XCTest
import UIKit
@testable import Vela

private actor FetchCounter {
    private(set) var count = 0
    func record() -> Int {
        count += 1
        return count
    }
}

final class SiteIconLoaderTests: XCTestCase {
    func testARepeatedFailedRequestIsRemembered() async {
        let counter = FetchCounter()
        let loader = SiteIconLoader(fetch: { _ in
            _ = await counter.record()
            return nil
        })
        let url = URL(string: "https://example.com/favicon.ico")!

        let first = await loader.image(for: url, prepare: { $0 })
        let second = await loader.image(for: url, prepare: { $0 })

        XCTAssertNil(first)
        XCTAssertNil(second)
        let count = await counter.count
        XCTAssertEqual(count, 1, "the failed URL must be negatively cached")
    }

    func testConcurrentRequestsShareOneFetch() async {
        let counter = FetchCounter()
        let loader = SiteIconLoader(fetch: { _ in
            _ = await counter.record()
            try? await Task.sleep(nanoseconds: 50_000_000)
            return UIImage()
        })
        let url = URL(string: "https://example.com/icon.png")!

        async let first = loader.image(for: url, prepare: { $0 })
        async let second = loader.image(for: url, prepare: { $0 })
        let firstImage = await first
        let secondImage = await second

        XCTAssertNotNil(firstImage)
        XCTAssertNotNil(secondImage)
        let count = await counter.count
        XCTAssertEqual(count, 1, "concurrent tiles must share the in-flight fetch")
    }
}
