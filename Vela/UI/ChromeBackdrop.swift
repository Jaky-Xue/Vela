//
//  ChromeBackdrop.swift
//  Vela
//
//  The luminance measurements that decide whether the floating chrome draws black or white ink.
//

import SwiftUI
import UIKit

// MARK: - Chrome contrast

/// Whether the surface the floating chrome sits over reads light or dark.
///
/// The chrome is glass over whatever is behind it — the home surface's own
/// picture, the palette surface, or the live page — and glass does not
/// guarantee legibility: white ink on a bright sky is as unreadable as black
/// ink on a night page. What decides the ink is the luminance of the strip
/// the bar actually covers, so both measurements here look at that strip and
/// not the whole surface.
enum ChromeBackdrop {
    /// The threshold at or above which a mean luminance counts as light.
    static let lightThreshold = 0.6

    /// The mean luminance of an image's bottom strip — the region the command
    /// bar floats over — against `lightThreshold`.
    ///
    /// The picture is squashed into a few dozen pixels first: an average is
    /// the answer wanted here, and a 16×48 read costs nothing next to a full
    /// histogram. `nil` when the picture has no bitmap to read.
    static func bottomStripIsLight(_ image: UIImage) -> Bool? {
        guard let cgImage = image.cgImage else { return nil }
        let width = 16
        let height = 48
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let context = CGContext(
            data: &pixels,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )
        guard let context else { return nil }
        context.interpolationQuality = .low
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))

        // The context's first scanline in memory is the top of the drawn
        // picture, so the strip the bar covers is the last rows read here.
        var total = 0.0
        var samples = 0
        for row in (height - 16)..<height {
            for column in 0..<width {
                let offset = (row * width + column) * 4
                total += 0.2126 * Double(pixels[offset]) / 255
                    + 0.7152 * Double(pixels[offset + 1]) / 255
                    + 0.0722 * Double(pixels[offset + 2]) / 255
                samples += 1
            }
        }
        return total / Double(max(samples, 1)) > lightThreshold
    }

    /// The mean luminance of the whole picture against `lightThreshold`.
    ///
    /// Chrome sampling asks about the strip it floats over; home text sits
    /// across the whole surface, so it asks about the whole picture.
    static func isLight(_ image: UIImage) -> Bool? {
        guard let cgImage = image.cgImage else { return nil }
        let edge = 24
        var pixels = [UInt8](repeating: 0, count: edge * edge * 4)
        let context = CGContext(
            data: &pixels,
            width: edge,
            height: edge,
            bitsPerComponent: 8,
            bytesPerRow: edge * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )
        guard let context else { return nil }
        context.interpolationQuality = .low
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: edge, height: edge))

        var total = 0.0
        for offset in stride(from: 0, to: pixels.count, by: 4) {
            total += 0.2126 * Double(pixels[offset]) / 255
                + 0.7152 * Double(pixels[offset + 1]) / 255
                + 0.0722 * Double(pixels[offset + 2]) / 255
        }
        return total / Double(edge * edge) > lightThreshold
    }

    /// A palette colour's own lightness, resolved for one appearance.
    ///
    /// The palette's colours are dynamic — they re-resolve when the appearance
    /// changes — so the answer is asked of the mode it will be drawn in.
    /// `nil` when the colour carries no readable components.
    static func surfaceIsLight(_ color: Color, scheme: ColorScheme) -> Bool? {
        var red: CGFloat = 0
        var green: CGFloat = 0
        var blue: CGFloat = 0
        var alpha: CGFloat = 0
        let style: UIUserInterfaceStyle = scheme == .dark ? .dark : .light
        let resolved = UIColor(color).resolvedColor(with: UITraitCollection(userInterfaceStyle: style))
        guard resolved.getRed(&red, green: &green, blue: &blue, alpha: &alpha) else { return nil }
        let luminance = 0.2126 * Double(red) + 0.7152 * Double(green) + 0.0722 * Double(blue)
        return luminance > lightThreshold
    }
}
