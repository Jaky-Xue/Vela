//
//  HomeFavoriteTile.swift
//  Vela
//
//  One favourite tile: the site's icon, and its name when the tile shows one.
//
//  The home grid and the 外观 ▸ 主页图标 preview draw this same view. Keeping
//  one tile means the settings picture cannot show a shape, size or name rule
//  the home itself does not use.
//

import SwiftUI

struct HomeFavoriteTile: View {
    var favorite: HomeFavorite
    var showsTitle: Bool
    var iconSize: CGFloat
    /// `nil` keeps `SiteIconView`'s own proportion, which is the 圆角 shape.
    var cornerRadius: CGFloat?
    var titleColor: Color
    var titleShadow: Color = .clear
    /// Whether the tile takes an equal share of its row. The home's grid wants
    /// that; a preview with a fixed number of tiles also wants it, so the
    /// default is on.
    var fillsWidth: Bool = true

    var body: some View {
        VStack(spacing: 6) {
            SiteIconView(
                host: favorite.displayHost,
                size: iconSize,
                cornerRadius: cornerRadius
            )

            if showsTitle {
                Text(favorite.displayTitle)
                    .font(.system(size: 11, weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .foregroundStyle(titleColor)
                    .shadow(color: titleShadow, radius: 3, y: 1)
                    .frame(maxWidth: fillsWidth ? .infinity : nil)
            }
        }
        .padding(.vertical, 4)
        .frame(maxWidth: fillsWidth ? .infinity : nil)
    }
}
