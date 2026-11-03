//
//  ColorHex.swift
//  Vela
//
//  The #RRGGBB description used by the palette list.
//

import SwiftUI
import UIKit

extension Color {
    /// Parses the CSS `rgb(r, g, b)` / `rgba(r, g, b, a)` colour the page-side
    /// background bridge reports.
    ///
    /// `getComputedStyle` normalises every authored notation — hex, a named
    /// colour, the modern `rgb(r g b / a)` syntax — to this legacy comma form
    /// before the script reads it, so this parser only has to understand one
    /// shape. Returns nil for anything else, which leaves the caller free to
    /// fall back to the palette.
    init?(cssColor value: String) {
        let text = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard text.hasPrefix("rgb"),
              let open = text.firstIndex(of: "("),
              let close = text.lastIndex(of: ")"),
              open < close else {
            return nil
        }

        let parts = text[text.index(after: open)..<close]
            .split(separator: ",")
            .map { String($0).trimmingCharacters(in: .whitespaces) }
        guard parts.count == 3 || parts.count == 4 else { return nil }

        var components: [Double] = []
        components.reserveCapacity(parts.count)
        for (index, part) in parts.enumerated() {
            if index == 3 {
                guard let alpha = Double(part) else { return nil }
                components.append(min(1, max(0, alpha)))
            } else if part.hasSuffix("%") {
                guard let percent = Double(part.dropLast()) else { return nil }
                components.append(min(255, max(0, percent * 2.55)) / 255)
            } else {
                guard let channel = Double(part) else { return nil }
                components.append(min(255, max(0, channel)) / 255)
            }
        }

        self.init(
            .sRGB,
            red: components[0],
            green: components[1],
            blue: components[2],
            opacity: components.count == 4 ? components[3] : 1
        )
    }
}

// MARK: - Colour description

extension Color {
    /// The colour as `#RRGGBB`, for the settings list.
    ///
    /// Resolved against the standard sRGB space and no trait collection: these
    /// are the palette's authored values, and showing them is the only way a
    /// user can tell two similar palettes apart in a list.
    var hexDescription: String {
        let uiColor = UIColor(self)
        var red: CGFloat = 0
        var green: CGFloat = 0
        var blue: CGFloat = 0
        var alpha: CGFloat = 0
        guard uiColor.getRed(&red, green: &green, blue: &blue, alpha: &alpha) else {
            return "#------"
        }
        return String(
            format: "#%02X%02X%02X",
            Int((red * 255).rounded()),
            Int((green * 255).rounded()),
            Int((blue * 255).rounded())
        )
    }
}
