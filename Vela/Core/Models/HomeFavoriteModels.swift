//
//  HomeFavoriteModels.swift
//  Vela
//
//  A home favourite: one tile on the start page.
//
//  Favourites used to be bookmark ids kept in `UserDefaults`, so the home was
//  a filtered view of the bookmark store. They are their own inventory now: a
//  bookmark that is deleted or renamed cannot take a home tile with it, and a
//  tile edited on the home cannot rename a bookmark. The URL and the name are
//  copied at the moment the tile is created; from then on they are the tile's.
//

import CoreGraphics
import Foundation

public struct HomeFavorite: Identifiable, Codable, Equatable, Sendable {
    public var id: String
    public var title: String
    public var url: String
    /// `nil` follows 外观 ▸ 主页图标's 显示图标名称 default; a value makes this
    /// tile's name its own. Optional so a document written by an earlier build
    /// keeps decoding when a later one adds fields beside it.
    public var showsTitle: Bool?
    public var createdAt: Date
    public var updatedAt: Date

    public init(
        id: String = UUID().uuidString,
        title: String,
        url: String,
        showsTitle: Bool? = nil,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.title = title
        self.url = url
        self.showsTitle = showsTitle
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    /// The host shown under the name in an editor, with the `www.` prefix
    /// dropped the way every other list in the app drops it.
    public var displayHost: String {
        guard let host = URL(string: url)?.host else { return "" }
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }

    /// What the tile draws when its name is visible. An empty name falls back
    /// to the host rather than leaving a blank line under the icon.
    public var displayTitle: String {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? displayHost : trimmed
    }
}

/// The geometry shared by the home grid and the settings preview, so the
/// picture on the settings screen cannot describe a tile the home does not
/// draw.
enum HomeTileStyle {
    /// The chosen shape as the corner radius the icon tile is drawn with. A
    /// square tile at half its size in radius is a circle, so the three
    /// settings land on three radii and nothing else about the tile changes.
    static func cornerRadius(shape: String?, iconSize: CGFloat) -> CGFloat? {
        switch shape ?? "rounded" {
        case "circle": return iconSize / 2
        case "square": return 3
        default: return nil
        }
    }
}
