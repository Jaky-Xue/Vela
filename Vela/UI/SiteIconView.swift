//
//  SiteIconView.swift
//  Vela
//
//  The favicon tile: a site icon that cascades through its sources and trims its transparent margins.
//

import SwiftUI
import UIKit

// MARK: - Icons

/// A favicon or a letter placeholder.
///
/// A favicon is not readable from outside the page, so when the site's own icon
/// cannot be fetched this shows the host's first letter on a deterministic
/// colour. The colour is derived from the host, so the same site always gets the
/// same swatch.
struct SiteIconView: View {
    var host: String
    var size: CGFloat = 28
    var faviconUrl: String?
    /// Whether the icon may be fetched from a third-party favicon service.
    /// A private tab passes false: its host must not be sent to Google just to
    /// draw a tile.
    var allowsThirdPartyLookup: Bool = true
    /// The tile's corner radius, when the caller owns the shape the tile sits
    /// in — the home's favourites pass their chosen shape through here. `nil`
    /// keeps the component's own proportion of the size.
    var cornerRadius: CGFloat? = nil

    @Environment(\.colorScheme) private var colorScheme

    /// The decoded icon, once one of the candidate sources has answered.
    @State private var image: UIImage?

    /// Whether the icon brings a canvas of its own — a filled square, circle
    /// or rounded tile that the site drew — rather than a mark on
    /// transparency. Only a canvas has corners to round, so only a canvas is
    /// masked to the tile's shape.
    @State private var hasOpaqueCanvas = false

    /// Decoded icons for this process, keyed by URL. `URLSession`'s own cache
    /// answers the bytes; this one answers the decode, so a tile that scrolls
    /// back into view shows instantly.
    private static let iconCache = NSCache<NSString, UIImage>()

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: resolvedCornerRadius, style: .continuous)
                .fill(tileFill)

            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
                    // An icon that brings its own canvas takes the tile's
                    // shape at the same proportion, the way iOS masks an app
                    // icon: a full-bleed white square lands as a rounded
                    // square inside a rounded tile instead of as a sharp
                    // square cutting across it. A mark on transparency has
                    // no corners to round and keeps its own silhouette.
                    .clipShape(
                        RoundedRectangle(
                            cornerRadius: hasOpaqueCanvas ? artworkCornerRadius : 0,
                            style: .continuous
                        )
                    )
                    .padding(size * Self.iconInset)
            } else {
                Text(initial)
                    .font(.system(size: size * 0.42, weight: .semibold, design: .rounded))
                    .foregroundStyle(color)
                    .minimumScaleFactor(0.6)
            }
        }
        // The chosen shape is the tile's shape, picture included. An icon
        // that carries its own opaque background covers the fill entirely,
        // so shaping only the fill let 圆角/圆形/方角 change something no
        // one could see; clipping the stack makes the shape the icon's own
        // silhouette too.
        .clipShape(RoundedRectangle(cornerRadius: resolvedCornerRadius, style: .continuous))
        .overlay {
            // A hairline that keeps the tile reading as a tile over any
            // backdrop, the way Via's tiles hold their edge on a picture.
            RoundedRectangle(cornerRadius: resolvedCornerRadius, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5)
        }
        .frame(width: size, height: size)
        .task(id: "\(host)|\(faviconUrl ?? "")") {
            await loadIcon()
        }
    }

    private var resolvedCornerRadius: CGFloat {
        cornerRadius ?? size * 0.22
    }

    /// How far the icon sits inside its tile, as a fraction of the tile.
    private static let iconInset: CGFloat = 0.14

    /// The radius the icon's own canvas is masked with. The canvas is inset
    /// inside the tile, so carrying the tile's radius inward by the same
    /// proportion lines the two shapes up instead of leaving the canvas's
    /// corners cutting across the tile's.
    private var artworkCornerRadius: CGFloat {
        resolvedCornerRadius * (1 - 2 * Self.iconInset)
    }

    /// The tile every icon rides: one quiet neutral, so a grid of them reads
    /// as a shelf of equals — the uniformity the reference home has — instead
    /// of every favicon arriving on whatever backdrop its own alpha implies.
    private var tileFill: Color {
        colorScheme == .dark ? Color(white: 0.17) : Color(white: 0.94)
    }

    /// A source is good enough when its long edge covers the tile at 3x.
    /// Anything smaller is remembered and used only when nothing better
    /// answers — a 16-pixel favicon is still the site's mark, just a soft
    /// one, and it beats a letter placeholder.
    private static let sharpIconEdge: CGFloat = 96

    /// Walks the candidate sources in order and keeps the first one that
    /// decodes at a usable resolution.
    ///
    /// `/apple-touch-icon.png` comes first because it is the icon the site
    /// built for a home screen — usually 152-180 pixels, which stays sharp at
    /// 40 points, where a 16-or-32-pixel `.ico` is mush. The favicon service
    /// answers for the sites that publish no touch icon at all. An explicit
    /// URL from the page outranks everything.
    private func loadIcon() async {
        image = nil
        hasOpaqueCanvas = false
        var fallback: UIImage?
        for candidate in Self.candidates(host: host, faviconUrl: faviconUrl, allowsThirdParty: allowsThirdPartyLookup) {
            guard let url = candidate else { continue }
            if let cached = Self.iconCache.object(forKey: url.absoluteString as NSString) {
                if max(cached.size.width, cached.size.height) >= Self.sharpIconEdge {
                    present(cached)
                    return
                }
                if fallback == nil { fallback = cached }
                continue
            }
            guard let prepared = await SiteIconLoader.shared.image(
                for: url,
                prepare: Self.preparedArtwork
            ) else { continue }
            Self.iconCache.setObject(prepared, forKey: url.absoluteString as NSString)
            if max(prepared.size.width, prepared.size.height) >= Self.sharpIconEdge {
                present(prepared)
                return
            }
            if fallback == nil { fallback = prepared }
        }
        if let fallback { present(fallback) }
    }

    /// Puts an icon on the tile together with the property the tile draws it
    /// by, so the two can never disagree about the same picture.
    private func present(_ image: UIImage) {
        self.image = image
        hasOpaqueCanvas = Self.isOpaqueCanvas(image)
    }

    /// Whether a decoded icon is a filled canvas rather than a mark.
    ///
    /// A canvas is an icon whose pixels are opaque nearly everywhere; a mark
    /// leaves the space between its strokes transparent. The check samples a
    /// 24-point thumbnail, so it costs the same whatever the source's
    /// resolution, and an icon with no alpha channel at all answers without
    /// painting anything.
    nonisolated static func isOpaqueCanvas(_ image: UIImage) -> Bool {
        guard let cgImage = image.cgImage else { return false }
        switch cgImage.alphaInfo {
        case .none, .noneSkipFirst, .noneSkipLast:
            return true
        default:
            break
        }

        let side = 24
        var pixels = [UInt8](repeating: 0, count: side * side * 4)
        let painted = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(
                data: buffer.baseAddress,
                width: side,
                height: side,
                bitsPerComponent: 8,
                bytesPerRow: side * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return false }
            context.interpolationQuality = .low
            context.draw(cgImage, in: CGRect(x: 0, y: 0, width: side, height: side))
            return true
        }
        guard painted else { return false }

        var opaque = 0
        for index in 0..<(side * side) where pixels[index * 4 + 3] > 240 {
            opaque += 1
        }
        return opaque * 10 >= side * side * 9
    }

    /// Everything the loader runs once per icon: the transparent margins
    /// trimmed, then a padded canvas removed from around the block it
    /// surrounds.
    nonisolated fileprivate static func preparedArtwork(_ image: UIImage) -> UIImage {
        canvasRemoved(trimmedToOpaqueBounds(image))
    }

    /// The icon cropped to the pixels that actually paint.
    ///
    /// A site's icon file is not always its artwork: favicons routinely carry
    /// transparent margins, and a glyph drawn across four fifths of its
    /// canvas lands in the tile visibly smaller than the neighbour that fills
    /// its own — the unevenness the uniform backdrop alone could not fix.
    /// Cropping to the opaque bounds makes every icon answer the tile at the
    /// same size. A fully opaque icon — the usual apple-touch-icon — has
    /// nothing to crop and is handed back untouched.
    nonisolated fileprivate static func trimmedToOpaqueBounds(_ image: UIImage) -> UIImage {
        guard let cgImage = image.cgImage else { return image }
        let width = cgImage.width
        let height = cgImage.height
        guard width > 1, height > 1,
              let context = CGContext(
                  data: nil,
                  width: width,
                  height: height,
                  bitsPerComponent: 8,
                  bytesPerRow: width * 4,
                  space: CGColorSpaceCreateDeviceRGB(),
                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              ) else { return image }

        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let data = context.data else { return image }
        let pixels = data.bindMemory(to: UInt8.self, capacity: width * height * 4)

        let alphaThreshold: UInt8 = 6
        var minX = width
        var minY = height
        var maxX = -1
        var maxY = -1
        for y in 0..<height {
            let row = y * width * 4
            for x in 0..<width where pixels[row + x * 4 + 3] > alphaThreshold {
                if x < minX { minX = x }
                if x > maxX { maxX = x }
                if y < minY { minY = y }
                if y > maxY { maxY = y }
            }
        }

        // Nothing opaque, or nothing to trim: the original stands.
        guard maxX >= minX, maxY >= minY,
              minX > 0 || minY > 0 || maxX < width - 1 || maxY < height - 1 else {
            return image
        }

        let bounds = CGRect(
            x: minX,
            y: minY,
            width: maxX - minX + 1,
            height: maxY - minY + 1
        )
        guard let cropped = cgImage.cropping(to: bounds) else { return image }
        return UIImage(cgImage: cropped, scale: image.scale, orientation: .up)
    }

    /// Removes a padded canvas from around a mark that brings its own block.
    ///
    /// A site that exports its mark floating on a flat canvas arrives in the
    /// tile smaller than its neighbours, with the canvas standing in for the
    /// site's own colour. When the canvas is one uniform colour and what it
    /// surrounds is a solid block or disc — the mark's own background, not a
    /// glyph drawn on the canvas — the canvas is erased and the block is what
    /// is left, so the mark answers the tile at the size its neighbours do.
    /// A glyph on a canvas keeps its canvas: the white behind ChatGPT's knot
    /// is the mark, not padding.
    nonisolated static func canvasRemoved(_ image: UIImage) -> UIImage {
        guard let cgImage = image.cgImage else { return image }
        let width = cgImage.width
        let height = cgImage.height
        guard width > 8, height > 8,
              let context = CGContext(
                  data: nil,
                  width: width,
                  height: height,
                  bitsPerComponent: 8,
                  bytesPerRow: width * 4,
                  space: CGColorSpaceCreateDeviceRGB(),
                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              ) else { return image }

        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let data = context.data else { return image }
        let pixels = data.bindMemory(to: UInt8.self, capacity: width * height * 4)

        // Only a canvas is opaque everywhere. A mark's gaps are transparent,
        // and `trimmedToOpaqueBounds` has already taken its margins.
        for index in 0..<(width * height) where pixels[index * 4 + 3] < 250 {
            return image
        }

        // The canvas colour is the ring's colour, provided the ring really is
        // one colour and not artwork that reaches the edge.
        var ringCount = 0
        var ringRed = 0
        var ringGreen = 0
        var ringBlue = 0
        for x in 0..<width {
            for y in [0, height - 1] {
                let index = (y * width + x) * 4
                ringRed += Int(pixels[index])
                ringGreen += Int(pixels[index + 1])
                ringBlue += Int(pixels[index + 2])
                ringCount += 1
            }
        }
        for y in 1..<(height - 1) {
            for x in [0, width - 1] {
                let index = (y * width + x) * 4
                ringRed += Int(pixels[index])
                ringGreen += Int(pixels[index + 1])
                ringBlue += Int(pixels[index + 2])
                ringCount += 1
            }
        }
        guard ringCount > 0 else { return image }
        let canvasRed = ringRed / ringCount
        let canvasGreen = ringGreen / ringCount
        let canvasBlue = ringBlue / ringCount

        func isCanvas(_ index: Int, tolerance: Int) -> Bool {
            abs(Int(pixels[index]) - canvasRed) <= tolerance
                && abs(Int(pixels[index + 1]) - canvasGreen) <= tolerance
                && abs(Int(pixels[index + 2]) - canvasBlue) <= tolerance
        }

        var ringMatches = 0
        for x in 0..<width {
            for y in [0, height - 1] where isCanvas((y * width + x) * 4, tolerance: 18) {
                ringMatches += 1
            }
        }
        for y in 1..<(height - 1) {
            for x in [0, width - 1] where isCanvas((y * width + x) * 4, tolerance: 18) {
                ringMatches += 1
            }
        }
        guard ringMatches * 100 >= ringCount * 95 else { return image }

        // The mark's bounds are everything that is not the canvas colour; the
        // wider tolerance leaves the antialiased seam out of them.
        var minX = width
        var minY = height
        var maxX = -1
        var maxY = -1
        for y in 0..<height {
            for x in 0..<width {
                guard !isCanvas((y * width + x) * 4, tolerance: 32) else { continue }
                if x < minX { minX = x }
                if x > maxX { maxX = x }
                if y < minY { minY = y }
                if y > maxY { maxY = y }
            }
        }
        guard maxX >= minX, maxY >= minY else { return image }

        let contentWidth = maxX - minX + 1
        let contentHeight = maxY - minY + 1
        // Only when the canvas is actually padding: a mark that already
        // reaches both edges has nothing to remove.
        guard contentWidth < width * 96 / 100 || contentHeight < height * 96 / 100 else {
            return image
        }

        // A glyph leaves the canvas showing between its strokes; a block or a
        // disc fills its own bounds. Only the latter is the mark, so only the
        // latter is worth taking out of its canvas.
        var painted = 0
        for y in minY...maxY {
            for x in minX...maxX where !isCanvas((y * width + x) * 4, tolerance: 32) {
                painted += 1
            }
        }
        guard painted * 100 >= contentWidth * contentHeight * 70 else { return image }

        // Erase the canvas, but only the part that touches the border: the
        // same colour further in — a white glyph, a ring within the block —
        // is the mark and stays.
        var visited = [Bool](repeating: false, count: width * height)
        var pending: [Int] = []
        for x in [0, width - 1] {
            pending.append(x)
            pending.append((height - 1) * width + x)
        }
        for y in 1..<(height - 1) {
            pending.append(y * width)
            pending.append(y * width + width - 1)
        }
        while let index = pending.popLast() {
            if visited[index] { continue }
            visited[index] = true
            guard isCanvas(index * 4, tolerance: 32) else { continue }
            pixels[index * 4] = 0
            pixels[index * 4 + 1] = 0
            pixels[index * 4 + 2] = 0
            pixels[index * 4 + 3] = 0
            let x = index % width
            let y = index / width
            if x > 0 { pending.append(index - 1) }
            if x < width - 1 { pending.append(index + 1) }
            if y > 0 { pending.append(index - width) }
            if y < height - 1 { pending.append(index + width) }
        }

        guard let erased = context.makeImage() else { return image }
        return trimmedToOpaqueBounds(
            UIImage(cgImage: erased, scale: image.scale, orientation: .up)
        )
    }

    /// The URLs to try, strongest first.
    ///
    /// The site's home-screen icon comes first, then the favicon service:
    /// a site's own `favicon.ico` is routinely 16 pixels (YouTube's is
    /// exactly that), and a 16-pixel mark blown up into a 40-point tile is
    /// the blur the grid showed. The service answers with the largest
    /// rendition it holds — 128-256 pixels for the sites that matter — and
    /// the site's own `.ico` is kept as the last resort for a network where
    /// the service cannot be reached.
    /// The candidate sources, in order. The third-party favicon service is
    /// included only when the caller allows it; an explicit page icon is kept
    /// only when it is local to the page's host or third-party lookups are
    /// allowed.
    static func candidates(
        host: String,
        faviconUrl: String?,
        allowsThirdParty: Bool
    ) -> [URL?] {
        var urls: [URL?] = []
        let trimmed = host.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedHost = trimmed.lowercased()

        if let faviconUrl, !faviconUrl.isEmpty,
           let url = URL(string: faviconUrl) {
            let iconHost = url.host?.lowercased()
            if allowsThirdParty || iconHost == nil || iconHost == normalizedHost {
                urls.append(url)
            }
        }

        if !trimmed.isEmpty, trimmed.contains(".") {
            urls.append(URL(string: "https://\(trimmed)/apple-touch-icon.png"))
            urls.append(URL(string: "https://\(trimmed)/apple-touch-icon-precomposed.png"))
            if allowsThirdParty {
                urls.append(URL(string: "https://www.google.com/s2/favicons?sz=256&domain=\(trimmed)"))
            }
            urls.append(URL(string: "https://\(trimmed)/favicon.ico"))
        }
        return urls
    }

    private var initial: String {
        let trimmed = host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
        return String(trimmed.first.map(String.init) ?? "?").uppercased()
    }

    /// A stable hue from the host. FNV-1a rather than `hashValue`, which is
    /// seeded per process and would make a site change colour between launches.
    ///
    /// The hue colours the letter only — the tile stays neutral — so sites
    /// without an icon stay distinguishable without breaking the grid's
    /// uniform backdrop.
    private var color: Color {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in host.lowercased().utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01b3
        }
        let hue = Double(hash % 360) / 360.0
        return Color(hue: hue, saturation: 0.45, brightness: 0.62)
    }
}

// MARK: - Shared loader

/// Coalesces favicon requests and remembers the URLs that failed.
///
/// A grid of tiles can ask for the same host's icon several times at once, and
/// a site with no icon at any candidate URL used to be retried by every tile
/// on every appearance. The actor keeps one in-flight request per URL and a
/// bounded negative cache; the decoded-image cache remains in `SiteIconView`.
actor SiteIconLoader {
    static let shared = SiteIconLoader()

    typealias Fetch = (URL) async -> UIImage?

    private struct Failure {
        let at: Date
    }

    private let fetch: Fetch
    private var failures: [String: Failure] = [:]
    private var inFlight: [String: Task<UIImage?, Never>] = [:]
    private let maximumConcurrent = 6
    private var activeFetches = 0
    private var waitingFetches: [CheckedContinuation<Void, Never>] = []
    private let failureLifetime: TimeInterval = 15 * 60
    private let maximumFailures = 256

    init(fetch: @escaping Fetch = SiteIconLoader.defaultFetch) {
        self.fetch = fetch
    }

    private static func defaultFetch(_ url: URL) async -> UIImage? {
        guard let (data, _) = try? await URLSession.shared.data(from: url) else {
            return nil
        }
        return UIImage(data: data)
    }

    func image(
        for url: URL,
        prepare: @escaping (UIImage) -> UIImage
    ) async -> UIImage? {
        let key = url.absoluteString
        if let failure = failures[key],
           Date().timeIntervalSince(failure.at) < failureLifetime {
            return nil
        }
        if let task = inFlight[key] {
            return await task.value
        }

        let task = Task<UIImage?, Never> { [weak self] in
            await self?.acquireFetchSlot()
            let decoded = await fetch(url)
            await self?.releaseFetchSlot()
            guard let decoded else { return nil }
            return prepare(decoded)
        }
        inFlight[key] = task
        let result = await task.value
        inFlight[key] = nil

        if let result {
            failures.removeValue(forKey: key)
            return result
        }
        failures[key] = Failure(at: Date())
        pruneFailures()
        return nil
    }

    private func acquireFetchSlot() async {
        if activeFetches < maximumConcurrent {
            activeFetches += 1
            return
        }
        await withCheckedContinuation { continuation in
            waitingFetches.append(continuation)
        }
    }

    private func releaseFetchSlot() {
        if waitingFetches.isEmpty {
            activeFetches = max(0, activeFetches - 1)
        } else {
            // Hand the slot directly to the next waiter; activeFetches stays
            // the same.
            waitingFetches.removeFirst().resume()
        }
    }

    private func pruneFailures() {
        guard failures.count > maximumFailures else { return }
        let cutoff = Date().addingTimeInterval(-failureLifetime)
        failures = failures.filter { $0.value.at >= cutoff }
        guard failures.count > maximumFailures else { return }
        let keep = failures
            .sorted { $0.value.at > $1.value.at }
            .prefix(maximumFailures)
        failures = Dictionary(uniqueKeysWithValues: keep.map { ($0.key, $0.value) })
    }
}
