//
//  ColorHex.swift
//  Vela
//
//  The CSS colour parser the settings and chrome read page colours with.
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
