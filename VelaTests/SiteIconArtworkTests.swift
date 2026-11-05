//
//  SiteIconArtworkTests.swift
//  VelaTests
//
//  The two adaptive steps between a fetched favicon and the tile: whether the
//  icon brings a canvas of its own (which the tile masks to its shape), and
//  whether a canvas is padding around a block (which the tile removes).
//

import XCTest
import UIKit
@testable import Vela

final class SiteIconArtworkTests: XCTestCase {
    // MARK: - Canvas or mark

    func testAFilledSquareIsACanvas() {
        let image = Self.image { context in
            UIColor.white.setFill()
            context.fill(Self.canvas)
        }
        XCTAssertTrue(
            SiteIconView.isOpaqueCanvas(image),
            "a filled square is the site's own canvas and must be shaped by the tile"
        )
    }

    func testAMarkOnTransparencyIsNotACanvas() {
        let image = Self.image { context in
            UIColor.black.setFill()
            context.fillEllipse(in: CGRect(x: 20, y: 20, width: 20, height: 20))
        }
        XCTAssertFalse(
            SiteIconView.isOpaqueCanvas(image),
            "a mark keeps its own silhouette; masking it would cut the drawing"
        )
    }

    // MARK: - Padding or mark

    func testABlockOnACanvasLosesTheCanvas() {
        let image = Self.image { context in
            UIColor.white.setFill()
            context.fill(Self.canvas)
            UIColor.black.setFill()
            context.fill(Self.block)
        }
        let result = SiteIconView.canvasRemoved(image)
        let original = CGFloat(Self.pixels(of: image))
        let remaining = CGFloat(Self.pixels(of: result))
        XCTAssertEqual(
            remaining / original,
            0.5,
            accuracy: 0.08,
            "the canvas around the block is padding and is removed"
        )
    }

    func testAGlyphOnACanvasKeepsTheCanvas() {
        let image = Self.image { context in
            UIColor.white.setFill()
            context.fill(Self.canvas)
            UIColor.black.setStroke()
            context.setLineWidth(3)
            context.strokeEllipse(in: Self.block)
        }
        let result = SiteIconView.canvasRemoved(image)
        XCTAssertEqual(
            Self.pixels(of: result),
            Self.pixels(of: image),
            "a glyph is drawn on its canvas; removing the canvas would erase the mark"
        )
    }

    func testAMarkOnTransparencyIsLeftAlone() {
        let image = Self.image { context in
            UIColor.red.setFill()
            context.fill(CGRect(x: 10, y: 10, width: 40, height: 40))
        }
        let result = SiteIconView.canvasRemoved(image)
        XCTAssertEqual(Self.pixels(of: result), Self.pixels(of: image))
    }

    // MARK: - Fixtures

    private static let canvas = CGRect(x: 0, y: 0, width: 60, height: 60)
    private static let block = CGRect(x: 15, y: 15, width: 30, height: 30)

    private static func pixels(of image: UIImage) -> Int {
        image.cgImage?.width ?? 0
    }

    /// A 60-point square with a transparent background, so the alpha channel
    /// the check samples is the one the drawing actually paints.
    private static func image(draw: (CGContext) -> Void) -> UIImage {
        let format = UIGraphicsImageRendererFormat.default()
        format.opaque = false
        let renderer = UIGraphicsImageRenderer(
            size: CGSize(width: 60, height: 60),
            format: format
        )
        return renderer.image { context in
            draw(context.cgContext)
        }
    }
}
