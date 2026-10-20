//
//  BackgroundImageStore.swift
//  Vela
//
//  The custom global background picture on disk.
//
//  One file, one timestamp. The timestamp is what the preferences document and
//  the shell both key off: saving writes the file and hands back the stamp, and
//  a view reading `backgroundImageStamp` reloads the picture when the stamp
//  moves. The in-memory cache is keyed by the same stamp, so a screen
//  re-rendering for an unrelated reason re-reads nothing.
//
//  The picture used to live behind the home surface alone (主页背景). It now
//  backs the whole shell — home, the top bar's backdrop, and the area around
//  the settings screens — so the file and its stamp moved out of the home's
//  settings. `adoptLegacyHomeImage` carries an existing install's picture over
//  rather than asking the user to choose it again.
//

import Foundation
import UIKit

enum BackgroundImageStore {
    /// Where the picture lives. Application Support, under the app's own
    /// folder, beside the ad-block filter lists.
    static var fileUrl: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let directory = base.appendingPathComponent("Vela", isDirectory: true)
        if !FileManager.default.fileExists(atPath: directory.path) {
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        return directory.appendingPathComponent("BackgroundImage.jpg")
    }

    /// The file the retired 主页背景 feature wrote.
    private static var legacyHomeFileUrl: URL {
        fileUrl.deletingLastPathComponent().appendingPathComponent("HomeBackground.jpg")
    }

    private static var cached: (stamp: Double, image: UIImage)?

    /// The image for a stamp, or nil when the file is gone. A stamp of nil
    /// means no picture was ever saved.
    static func load(stamp: Double?) -> UIImage? {
        guard let stamp else { return nil }
        if let cached, cached.stamp == stamp { return cached.image }
        guard let image = UIImage(contentsOfFile: fileUrl.path) else { return nil }
        cached = (stamp, image)
        return image
    }

    /// Downscales, encodes and writes an image, returning the stamp that
    /// refers to it.
    ///
    /// A photo from the library is routinely 12 megapixels; the shell never
    /// draws it larger than the screen, so the copy kept is capped at 2048 on
    /// its long edge and encoded as JPEG — a few hundred kilobytes instead of
    /// tens of megabytes.
    static func save(_ image: UIImage) -> Double? {
        let prepared = downscaled(image)
        guard let data = prepared.jpegData(compressionQuality: 0.85) else { return nil }
        do {
            try data.write(to: fileUrl, options: .atomic)
        } catch {
            return nil
        }
        let stamp = Date().timeIntervalSince1970
        cached = (stamp, prepared)
        return stamp
    }

    /// Removes the file and the cache. The stamp in the settings document is
    /// the caller's to clear, since that write belongs to the settings path.
    static func clear() {
        try? FileManager.default.removeItem(at: fileUrl)
        cached = nil
    }

    /// Adopts the picture the retired 主页背景 feature saved, moving it into
    /// the global slot.
    ///
    /// Returns the stamp the picture should be recorded under, or nil when
    /// there is nothing to adopt. The move is what makes this run once: after
    /// it there is no legacy file left to find.
    static func adoptLegacyHomeImage() -> Double? {
        let manager = FileManager.default
        if manager.fileExists(atPath: fileUrl.path) {
            try? manager.removeItem(at: legacyHomeFileUrl)
            return modificationStamp(of: fileUrl)
        }
        guard manager.fileExists(atPath: legacyHomeFileUrl.path) else { return nil }
        do {
            try manager.moveItem(at: legacyHomeFileUrl, to: fileUrl)
        } catch {
            return nil
        }
        cached = nil
        return modificationStamp(of: fileUrl)
    }

    private static func modificationStamp(of url: URL) -> Double? {
        let values = try? url.resourceValues(forKeys: [.contentModificationDateKey])
        return values?.contentModificationDate?.timeIntervalSince1970
    }

    /// The image scaled so its long edge is at most 2048 points.
    private static func downscaled(_ image: UIImage) -> UIImage {
        let maxEdge: CGFloat = 2048
        let longEdge = max(image.size.width, image.size.height)
        guard longEdge > maxEdge, longEdge > 0 else { return image }

        let scale = maxEdge / longEdge
        let newSize = CGSize(width: image.size.width * scale, height: image.size.height * scale)
        let format = UIGraphicsImageRendererFormat.default()
        format.opaque = true
        return UIGraphicsImageRenderer(size: newSize, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: newSize))
        }
    }
}
