//
//  ColorHex.swift
//  Vela
//
//  The #RRGGBB description used by the palette list.
//

import SwiftUI
import UIKit

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
