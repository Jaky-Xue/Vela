//
//  Chromebuttonstyle.swift
//  Vela
//
//  The press feedback shared by every chrome glyph.
//

import SwiftUI
import UIKit

// MARK: - Chrome button style

/// The press feedback for a chrome glyph.
///
/// A row of controls that do not respond to a touch reads as a screenshot. The
/// scale is small enough to stay inside the glyph's own frame, so pressing one
/// does not shift the ones beside it.
struct ChromeButtonStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.93 : 1)
            .opacity(configuration.isPressed ? 0.78 : 1)
            .animation(BrowserMotion.jellyPress(reduceMotion), value: configuration.isPressed)
    }
}

/// The press feedback for any other object in the app: a menu tile, a home
/// icon, a tab card. One give everywhere, so a tap reads the same wherever it
/// lands. Reduce Motion keeps the dimming and drops the squash.
struct JellyPressButtonStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var pressedScale: CGFloat = 0.94
    var pressedOpacity: Double = 0.85

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed && !reduceMotion ? pressedScale : 1)
            .opacity(configuration.isPressed ? pressedOpacity : 1)
            .animation(BrowserMotion.jellyPress(reduceMotion), value: configuration.isPressed)
    }
}
