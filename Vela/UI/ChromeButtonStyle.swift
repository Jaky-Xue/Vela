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
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.86 : 1)
            .opacity(configuration.isPressed ? 0.6 : 1)
            .animation(.spring(response: 0.22, dampingFraction: 0.72), value: configuration.isPressed)
    }
}
