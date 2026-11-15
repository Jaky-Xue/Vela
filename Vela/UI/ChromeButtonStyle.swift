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
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.95 : 1)
            .opacity(configuration.isPressed ? 0.78 : 1)
            .animation(reduceMotion ? nil : .spring(response: 0.28, dampingFraction: 0.9), value: configuration.isPressed)
    }
}
