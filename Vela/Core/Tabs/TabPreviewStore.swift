//
//  TabPreviewStore.swift
//  Vela
//
//  The overview's page pictures: an in-memory cache and a bounded on-disk
//  store, keyed by tab id. Split from TabManager so the pool's ownership rules
//  and the picture cache do not have to be read in one file.
//

import Foundation
import UIKit

/// The last picture each tab's page showed, for the overview's cards.
///
/// Kept in memory for the cards on screen and on disk so a restored session's
/// cold tabs still show the page they were left on — a tab whose web view the
/// live pool has let go has no view to ask. The picture is stored downscaled:
/// a card is a few hundred points wide, and a full-resolution print per tab is
/// tens of megabytes of decoded bitmap for a strip nobody is looking at.
@MainActor
final class TabPreviewStore {
    /// How many pictures the folder keeps across sessions. Closed tabs delete
    /// theirs; this is the bound for tabs that vanished without a close.
    private static let maximumFiles = 80

    private let cache = NSCache<NSString, UIImage>()
    private let directory: URL?

    init() {
        cache.countLimit = 32
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        if let base {
            let folder = base.appendingPathComponent("Vela/TabPreviews", isDirectory: true)
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            directory = folder
        } else {
            directory = nil
        }
        pruneIfNeeded()
    }

    func image(for tabId: String) -> UIImage? {
        if let cached = cache.object(forKey: tabId as NSString) { return cached }
        guard let directory else { return nil }
        let url = directory.appendingPathComponent(Self.fileName(for: tabId))
        guard let image = UIImage(contentsOfFile: url.path) else { return nil }
        cache.setObject(image, forKey: tabId as NSString)
        return image
    }

    func store(_ image: UIImage, for tabId: String, persistToDisk: Bool = true) {
        // The render and JPEG encode are the expensive half; the cache write
        // must be on the main actor, and the file write stays off it.
        Task.detached(priority: .utility) { [weak self] in
            let prepared = Self.downscaled(image)
            guard let data = prepared.jpegData(compressionQuality: 0.72) else { return }
            let url = await MainActor.run { [weak self] () -> URL? in
                self?.cache.setObject(prepared, forKey: tabId as NSString)
                guard persistToDisk, let directory = self?.directory else { return nil }
                return directory.appendingPathComponent(Self.fileName(for: tabId))
            }
            if let url {
                try? data.write(to: url, options: .atomic)
            }
        }
    }

    func remove(_ tabId: String) {
        cache.removeObject(forKey: tabId as NSString)
        guard let directory else { return }
        let url = directory.appendingPathComponent(Self.fileName(for: tabId))
        try? FileManager.default.removeItem(at: url)
    }

    /// Keeps the folder from growing without bound across sessions. The newest
    /// files are the ones a restored session is most likely to name.
    private func pruneIfNeeded() {
        guard let directory,
              let files = try? FileManager.default.contentsOfDirectory(
                  at: directory,
                  includingPropertiesForKeys: [.contentModificationDateKey],
                  options: [.skipsHiddenFiles]
              ),
              files.count > Self.maximumFiles else { return }
        let ordered = files.sorted { left, right in
            let leftDate = (try? left.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate ?? .distantPast
            let rightDate = (try? right.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate ?? .distantPast
            return leftDate > rightDate
        }
        for url in ordered.dropFirst(Self.maximumFiles) {
            try? FileManager.default.removeItem(at: url)
        }
    }

    /// Tab ids are UUID strings; anything else is rewritten so an id can never
    /// escape the folder.
    private static func fileName(for tabId: String) -> String {
        let safe = tabId.map { character -> Character in
            character.isLetter || character.isNumber || character == "-" || character == "_"
                ? character
                : "_"
        }
        return String(safe) + ".jpg"
    }

    nonisolated private static func downscaled(_ image: UIImage) -> UIImage {
        // A card at its widest is a few hundred points; 720 pixels covers it
        // even at 3x with room for the cover-crop.
        let maximumEdge: CGFloat = 720
        let longEdge = max(image.size.width, image.size.height)
        guard longEdge > maximumEdge, longEdge > 0 else { return image }
        let scale = maximumEdge / longEdge
        let size = CGSize(width: image.size.width * scale, height: image.size.height * scale)
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        format.opaque = true
        return UIGraphicsImageRenderer(size: size, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: size))
        }
    }
}
