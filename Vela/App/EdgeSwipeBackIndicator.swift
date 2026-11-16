import SwiftUI
import UIKit
import WebKit

// MARK: - Edge-swipe indicator

/// The arrow that stands in for the page sliding during an edge swipe.
///
/// Android's predictive-back gesture is the reference: a pill at the edge that
/// grows with the drag and inverts to a filled accent once releasing will
/// commit. It is a readout of the gesture, not a decoration — the page stays
/// exactly where it is.
struct EdgeSwipeBackIndicator: View {
    /// 0...1 across the first three tenths of the screen's width.
    var intensity: CGFloat
    /// Whether releasing now would complete the back action.
    var armed: Bool
    /// The release has been accepted and the navigation is about to run.
    var isCompleting: Bool

    @Environment(\.browserPalette) private var palette
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let diameter = 46 + 12 * intensity
        Image(systemName: "arrow.left")
            .font(.system(size: 18 + 4 * intensity, weight: .semibold))
            .foregroundStyle(armed ? palette.onAccent : palette.primaryText)
            .frame(width: diameter, height: diameter)
            .background {
                Circle()
                    .fill(armed ? palette.accent : palette.controlFill)
            }
            .overlay {
                Circle()
                    .strokeBorder(palette.cardStroke, lineWidth: 0.5)
            }
            .shadow(color: .black.opacity(0.18 * intensity), radius: 14, y: 4)
            .scaleEffect(armed ? 1.06 : 1)
            .offset(x: 4 + 24 * intensity)
            .opacity(isCompleting ? 0 : min(1, intensity * 2.6))
            .animation(BrowserMotion.press(reduceMotion), value: armed)
            .animation(BrowserMotion.hint(reduceMotion), value: isCompleting)
    }
}
