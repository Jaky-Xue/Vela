//
//  SiteIconLoaderTests.swift
//  VelaTests
//
//  A favicon URL is fetched once even when several tiles ask at the same time,
//  and a URL that failed is not hammered again on the next appearance.
//

import XCTest
import ImageIO
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

    /// A file that carries several renditions hands back its largest one.
    ///
    /// `.ico` files routinely hold 16, 32, 48 and 64-pixel pictures, so a
    /// decoder allowed to answer with "the" image is how a sharp file becomes
    /// a soft tile.
    func testAMultiFrameFileKeepsItsLargestFrame() throws {
        let data = try multiPageTIFF(sizes: [16, 96])
        let image = try XCTUnwrap(SiteIconLoader.decode(data))
        XCTAssertEqual(max(image.size.width, image.size.height), 96)
    }

    func testASingleFrameFileDecodesUnchanged() throws {
        let data = try multiPageTIFF(sizes: [72])
        let image = try XCTUnwrap(SiteIconLoader.decode(data))
        XCTAssertEqual(max(image.size.width, image.size.height), 72)
    }

    private func multiPageTIFF(sizes: [Int]) throws -> Data {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            data,
            "public.tiff" as CFString,
            sizes.count,
            nil
        ) else {
            throw XCTSkip("the platform has no TIFF encoder")
        }
        for side in sizes {
            let image = try XCTUnwrap(solidImage(side: side))
            CGImageDestinationAddImage(destination, image, nil)
        }
        guard CGImageDestinationFinalize(destination) else {
            throw XCTSkip("the TIFF encoder refused the frames")
        }
        return data as Data
    }

    private func solidImage(side: Int) -> CGImage? {
        guard let context = CGContext(
            data: nil,
            width: side,
            height: side,
            bitsPerComponent: 8,
            bytesPerRow: side * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        context.setFillColor(UIColor.systemBlue.cgColor)
        context.fill(CGRect(x: 0, y: 0, width: side, height: side))
        return context.makeImage()
    }
}
