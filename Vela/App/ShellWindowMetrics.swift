import SwiftUI
import UIKit
import WebKit

// MARK: - Window safe area

/// The window measurements a safe-area-inset shell cannot read itself.
struct ShellWindowMetrics: Equatable {
    var insets: UIEdgeInsets
    var originY: CGFloat
    var windowHeight: CGFloat
}

/// Reports the hosting window's safe-area insets, its height, and where the
/// probed view (and therefore the shell) begins inside it.
///
/// `GeometryReader` inside the shell cannot: the shell is laid out inside the
/// safe area, so its own insets are zero. The web view is laid out edge to
/// edge, and the status bar and home indicator are real obstacles to it, so
/// the strip heights and the shell's window origin have to come from the
/// window itself.
struct WindowSafeAreaReader: UIViewRepresentable {
    var onChange: (ShellWindowMetrics) -> Void

    func makeUIView(context: Context) -> SafeAreaProbeView {
        let view = SafeAreaProbeView()
        view.onChange = onChange
        return view
    }

    func updateUIView(_ view: SafeAreaProbeView, context: Context) {
        // The callback is refreshed here, but the report is not: mutating the
        // shell's state synchronously inside a SwiftUI update is the one thing
        // this probe must not do. `didMoveToWindow` and `layoutSubviews` are
        // the UIKit callbacks that carry the measurements.
        view.onChange = onChange
    }

    final class SafeAreaProbeView: UIView {
        var onChange: ((ShellWindowMetrics) -> Void)?
        private var lastReported: ShellWindowMetrics?
        private var observation: NSKeyValueObservation?

        override func didMoveToWindow() {
            super.didMoveToWindow()
            observation = nil
            guard let window else { return }
            // The window's own insets are the ones the edge-to-edge web view
            // has to clear. KVO rather than `safeAreaInsetsDidChange`: this
            // probe sits inside the safe area, so its own insets never change;
            // the window's do.
            observation = window.observe(\.safeAreaInsets, options: [.initial, .new]) { [weak self] window, _ in
                guard let self else { return }
                let metrics = self.metrics(in: window)
                // State is written from a UIKit callback, but a SwiftUI update
                // can be in flight on the same turn; the hop keeps the write
                // out of it.
                DispatchQueue.main.async {
                    self.publish(metrics)
                }
            }
        }

        override func layoutSubviews() {
            super.layoutSubviews()
            // Rotation and Stage Manager resizes run layout even when KVO on
            // the window does not fire; this is the second, dependable signal.
            guard let window else { return }
            let metrics = metrics(in: window)
            DispatchQueue.main.async { [weak self] in
                self?.publish(metrics)
            }
        }

        deinit {
            observation?.invalidate()
        }

        private func metrics(in window: UIWindow) -> ShellWindowMetrics {
            ShellWindowMetrics(
                insets: window.safeAreaInsets,
                originY: convert(CGPoint.zero, to: window).y,
                windowHeight: window.bounds.height
            )
        }

        private func publish(_ metrics: ShellWindowMetrics) {
            guard metrics != lastReported else { return }
            lastReported = metrics
            onChange?(metrics)
        }
    }
}

