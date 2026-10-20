//
//  HamburgerGlyph.swift
//  Vela
//
//  The menu glyph, drawn rather than borrowed from the symbol set.
//
//  `line.3.horizontal` is the obvious SF Symbol for it, but at the chrome's
//  glyph size its three hairlines read thinner and shorter than every icon
//  beside them — a smaller-looking control in a row of equal ones. Three
//  capsules at the same optical weight and width as those icons keep the row
//  even.
//

import SwiftUI

struct HamburgerGlyph: View {
    /// The width of the bar. Matches the optical width of the chrome's other
    /// 16 pt symbols.
    var width: CGFloat = 17
    /// One capsule's thickness. A 16 pt semibold symbol strokes at about 2 pt.
    var thickness: CGFloat = 2
    /// The space between bars.
    var spacing: CGFloat = 4.2

    var body: some View {
        VStack(spacing: spacing) {
            ForEach(0..<3, id: \.self) { _ in
                Capsule()
                    .fill(.foreground)
                    .frame(width: width, height: thickness)
            }
        }
        // The same 34 pt touch target every other chrome glyph has.
        .frame(width: 34, height: 34)
        .contentShape(Rectangle())
        .accessibilityHidden(true)
    }
}
