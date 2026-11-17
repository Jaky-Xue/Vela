import SwiftUI
import UIKit
import WebKit

extension BrowserShellView {
    // MARK: - Safe area

    /// Reads the safe-area geometry once the view is in a window.
    ///
    /// A `GeometryReader` in the background sees the safe-area rectangle the
    /// ZStack is laid out in, so the numbers here are the real insets on this
    /// device, re-read on rotation — which is what the keyboard-aware card
    /// budget and the full-bleed insets need.
    var safeAreaReader: some View {
        GeometryReader { geo in
            Color.clear
                .onAppear { recordSafeArea(geo) }
                .onChange(of: geo.size) { _, _ in recordSafeArea(geo) }
                .onChange(of: geo.safeAreaInsets) { _, _ in recordSafeArea(geo) }
        }
    }

    func recordSafeArea(_ geo: GeometryProxy) {
        // The geometry inside the safe area reports zero insets; a non-zero
        // answer (a view that was deliberately placed edge to edge) is taken
        // as authoritative, and the window probe fills in the rest.
        let top = max(safeTop, geo.safeAreaInsets.top)
        let bottom = max(safeBottom, geo.safeAreaInsets.bottom)
        // Geometry can report on every layout pass. Avoid publishing identical
        // values back into the shell, which would schedule another pass.
        if abs(safeTop - top) > 0.5 { safeTop = top }
        if abs(safeBottom - bottom) > 0.5 { safeBottom = bottom }
        if abs(safeRectHeight - geo.size.height) > 0.5 { safeRectHeight = geo.size.height }
        if abs(safeRectWidth - geo.size.width) > 0.5 { safeRectWidth = geo.size.width }
    }

    /// Records the window metrics the shell cannot read from its own geometry:
    /// the real safe-area insets, the shell's origin inside the window, and the
    /// window height. The first two are needed because SwiftUI lays the shell
    /// inside the safe area, where its own insets read zero; the height is
    /// needed to place a keyboard-relative card without assuming where the
    /// shell begins.
    func applyWindowMetrics(_ metrics: ShellWindowMetrics) {
        if abs(safeTop - metrics.insets.top) > 0.5 {
            safeTop = metrics.insets.top
        }
        if abs(safeBottom - metrics.insets.bottom) > 0.5 {
            safeBottom = metrics.insets.bottom
        }
        if abs(shellOriginY - metrics.originY) > 0.5 {
            shellOriginY = metrics.originY
        }
        if abs(windowHeight - metrics.windowHeight) > 0.5 {
            windowHeight = metrics.windowHeight
        }
    }
}
