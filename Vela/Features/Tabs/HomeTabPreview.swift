//
//  HomeTabPreview.swift
//  Vela
//
//  The designed preview of the native start page inside a tab card.
//
//  A home tab has no `WKWebView`, so `takeSnapshot` has nothing to ask. The
//  card previously fell back to a single house glyph on a flat surface, which
//  read as a missing image rather than as the start page. This draws the same
//  inventory the home shows — a section title, a favourites grid, and the
//  recently-closed card — scaled to the card.
//
//  Private homes keep their shape but lose their detail: the tiles and text
//  bars are muted and an eyeglasses badge marks the mode. The card's caption is
//  already suppressed for private tabs, so nothing on this surface names a
//  page.
//

import SwiftUI

struct HomeTabPreview: View {
    var isPrivate: Bool

    @Environment(\.browserPalette) private var palette

    private var tints: [Color] {
        [palette.accent, .blue, .green, .orange, .pink, .purple]
    }

    /// Single-letter marks on the favourite tiles, so the miniature reads as a
    /// shelf of sites rather than as a row of anonymous squares.
    private let marks = ["V", "G", "B", "Y", "N", "R"]

    var body: some View {
        GeometryReader { geo in
            let width = geo.size.width
            let height = geo.size.height
            let inset = max(9, width * 0.065)
            let gap = max(5, width * 0.035)
            // A landscape card is much shorter than a portrait one. One row
            // and no recent list keeps the miniature from being a squeezed
            // smear at that height.
            let compact = height < width * 0.95
            let tile = min(
                max(12, (width - inset * 2 - gap * 2) / 3),
                height * (compact ? 0.20 : 0.17)
            )

            ZStack(alignment: .topTrailing) {
                LinearGradient(
                    colors: [
                        palette.surface,
                        palette.controlFill.opacity(isPrivate ? 0.16 : 0.28)
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )

                VStack(alignment: .leading, spacing: max(6, height * 0.035)) {
                    Text("收藏")
                        .font(.system(size: max(7, width * 0.045), weight: .semibold))
                        .foregroundStyle(palette.primaryText.opacity(isPrivate ? 0.3 : 0.78))

                    VStack(alignment: .leading, spacing: gap) {
                        ForEach(0..<2, id: \.self) { row in
                            HStack(alignment: .top, spacing: gap) {
                                ForEach(0..<3, id: \.self) { column in
                                    tileView(
                                        index: row * 3 + column,
                                        size: tile
                                    )
                                }
                                Spacer(minLength: 0)
                            }
                        }
                    }

                    if !compact {
                        Text("最近关闭")
                            .font(.system(size: max(6.5, width * 0.038), weight: .semibold))
                            .foregroundStyle(palette.secondaryText.opacity(isPrivate ? 0.24 : 0.65))
                            .padding(.top, 1)
                        recentlyClosedCard(width: width)
                    }

                    Spacer(minLength: 0)
                }
                .padding(inset)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)

                if isPrivate {
                    Image(systemName: "eyeglasses")
                        .font(.system(size: max(9, min(12, width * 0.05)), weight: .semibold))
                        .foregroundStyle(palette.secondaryText)
                        .padding(max(4, width * 0.022))
                        .background(palette.controlFill.opacity(0.9), in: Circle())
                        .padding(inset * 0.7)
                }
            }
        }
        .clipped()
        .accessibilityHidden(true)
    }

    private func tileView(index: Int, size: CGFloat) -> some View {
        VStack(spacing: max(3, size * 0.1)) {
            ZStack {
                RoundedRectangle(cornerRadius: size * 0.28, style: .continuous)
                    .fill(tints[index % tints.count].opacity(isPrivate ? 0.24 : 0.78))
                if !isPrivate {
                    Text(marks[index % marks.count])
                        .font(.system(size: size * 0.34, weight: .bold, design: .rounded))
                        .foregroundStyle(.white.opacity(0.92))
                }
            }
            .frame(width: size, height: size)
            RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                .fill(palette.secondaryText.opacity(isPrivate ? 0.13 : 0.34))
                .frame(width: size * 0.68, height: max(2, size * 0.07))
        }
        .frame(width: size)
    }

    private func recentlyClosedCard(width: CGFloat) -> some View {
        VStack(spacing: max(3, width * 0.017)) {
            ForEach(0..<2, id: \.self) { index in
                HStack(spacing: max(4, width * 0.022)) {
                    Circle()
                        .fill(palette.controlFill.opacity(isPrivate ? 0.5 : 0.85))
                        .frame(width: max(7, width * 0.035))
                    VStack(alignment: .leading, spacing: 1.5) {
                        RoundedRectangle(cornerRadius: 1, style: .continuous)
                            .fill(palette.secondaryText.opacity(isPrivate ? 0.12 : 0.32))
                            .frame(
                                width: width * (index == 0 ? 0.3 : 0.22),
                                height: max(2, width * 0.011)
                            )
                        RoundedRectangle(cornerRadius: 1, style: .continuous)
                            .fill(palette.secondaryText.opacity(isPrivate ? 0.08 : 0.2))
                            .frame(width: width * 0.16, height: max(1.5, width * 0.008))
                    }
                    Spacer(minLength: 0)
                }
            }
        }
        .padding(.horizontal, max(5, width * 0.026))
        .padding(.vertical, max(5, width * 0.026))
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            palette.card.opacity(isPrivate ? 0.25 : 0.62),
            in: RoundedRectangle(cornerRadius: max(6, width * 0.035), style: .continuous)
        )
    }
}
