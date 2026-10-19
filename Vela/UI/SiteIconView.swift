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
    /// The tile's corner radius, when the caller owns the shape the tile sits
    /// in — the home's favourites pass their chosen shape through here. `nil`
    /// keeps the component's own proportion of the size.
    var cornerRadius: CGFloat? = nil

    @Environment(\.colorScheme) private var colorScheme

    /// The decoded icon, once one of the candidate sources has answered.
    @State private var image: UIImage?

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
                    .padding(size * 0.14)
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
        var fallback: UIImage?
        for candidate in candidateUrls {
            guard let url = candidate else { continue }
            if let cached = Self.iconCache.object(forKey: url.absoluteString as NSString) {
                if max(cached.size.width, cached.size.height) >= Self.sharpIconEdge {
                    image = cached
                    return
                }
                if fallback == nil { fallback = cached }
                continue
            }
            guard let (data, _) = try? await URLSession.shared.data(from: url),
                  let decoded = UIImage(data: data) else { continue }
            let prepared = Self.trimmedToOpaqueBounds(decoded)
            Self.iconCache.setObject(prepared, forKey: url.absoluteString as NSString)
            if max(prepared.size.width, prepared.size.height) >= Self.sharpIconEdge {
                image = prepared
                return
            }
            if fallback == nil { fallback = prepared }
        }
        image = fallback
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
    private static func trimmedToOpaqueBounds(_ image: UIImage) -> UIImage {
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

    /// The URLs to try, strongest first.
    ///
    /// The site's home-screen icon comes first, then the favicon service:
    /// a site's own `favicon.ico` is routinely 16 pixels (YouTube's is
    /// exactly that), and a 16-pixel mark blown up into a 40-point tile is
    /// the blur the grid showed. The service answers with the largest
    /// rendition it holds — 128-256 pixels for the sites that matter — and
    /// the site's own `.ico` is kept as the last resort for a network where
    /// the service cannot be reached.
    private var candidateUrls: [URL?] {
        var urls: [URL?] = []
        if let faviconUrl, !faviconUrl.isEmpty {
            urls.append(URL(string: faviconUrl))
        }
        let trimmed = host.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty, trimmed.contains(".") {
            urls.append(URL(string: "https://\(trimmed)/apple-touch-icon.png"))
            urls.append(URL(string: "https://\(trimmed)/apple-touch-icon-precomposed.png"))
            urls.append(URL(string: "https://www.google.com/s2/favicons?sz=256&domain=\(trimmed)"))
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
