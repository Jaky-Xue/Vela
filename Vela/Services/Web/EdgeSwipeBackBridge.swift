//
//  Screen-edgeswipeback.swift
//  Vela
//
//  The screen-edge pan that goes back, bridged to UIKit.
//

import SwiftUI
import UIKit

// MARK: - Screen-edge swipe back

/// The screen-edge swipe that goes back, bridged to UIKit.
///
/// SwiftUI has no edge-pan gesture, and a SwiftUI strip along the edge is
/// not the answer either: it would sit above the page and intercept its
/// touches, leaving a dead band down the left side of every document. So the
/// recognizer is a `UIScreenEdgePanGestureRecognizer` installed on the view
/// directly below the window — an ancestor whose recognizer sees touches
/// delivered anywhere inside it, the web view included, without a
/// hit-testing view of its own. Presented sheets live in their own
/// container, so a swipe inside one never reaches it.
///
/// Whether the gesture is allowed is the shell's decision (`isEnabled`): it
/// stands down wherever WebKit's own interactive back gesture is the right
/// responder, and acts through `onBack` where that gesture cannot — see
/// `BrowserShellView.edgeSwipeBackEnabled`.
struct EdgeSwipeBackBridge: UIViewRepresentable {
    var isEnabled: Bool
    /// The finger's horizontal travel from the edge. The shell moves the page
    /// with this value, so the gesture is interactive rather than a switch
    /// that fires at the end.
    var onChanged: (CGFloat) -> Void = { _ in }
    /// The distance and velocity at release. The shell decides whether the
    /// swipe completes or springs back.
    var onEnded: (CGFloat, CGFloat) -> Void = { _, _ in }
    /// A cancelled or failed recognition — spring the page home.
    var onCancelled: () -> Void = {}

    func makeUIView(context: Context) -> EdgeSwipeBridgeView {
        let view = EdgeSwipeBridgeView()
        view.backgroundColor = .clear
        // The bridge has no touch role of its own: the recognizer it installs
        // lives on an ancestor, and this view must never become a hit-test
        // target standing above the page.
        view.isUserInteractionEnabled = false
        let coordinator = context.coordinator
        view.onMoveToWindow = { coordinator.attach(from: view) }
        coordinator.parent = self
        return view
    }

    func updateUIView(_ view: EdgeSwipeBridgeView, context: Context) {
        context.coordinator.parent = self
        context.coordinator.recognizer?.isEnabled = isEnabled
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var parent: EdgeSwipeBackBridge?
        var recognizer: LeftEdgeBackGestureRecognizer?

        /// Installs the recognizer on the view directly below the window, and
        /// re-runs on every move to a window: SwiftUI can rebuild the bridge,
        /// and the recognizer has to follow the hierarchy it ends up in.
        func attach(from bridgeView: UIView) {
            if recognizer == nil {
                let edge = LeftEdgeBackGestureRecognizer(
                    target: self,
                    action: #selector(edgePanned(_:))
                )
                edge.edgeWidth = 44
                edge.delegate = self
                recognizer = edge
            }
            guard let recognizer else { return }

            var root = bridgeView
            while let superview = root.superview, !(superview is UIWindow) {
                root = superview
            }
            if recognizer.view !== root {
                recognizer.view?.removeGestureRecognizer(recognizer)
                root.addGestureRecognizer(recognizer)
            }
            recognizer.isEnabled = parent?.isEnabled ?? false
        }

        @objc private func edgePanned(_ sender: LeftEdgeBackGestureRecognizer) {
            let translation = max(0, sender.translation(in: sender.view).x)

            switch sender.state {
            case .began, .changed:
                parent?.onChanged(translation)
            case .ended:
                let velocity = sender.velocity(in: sender.view).x
                parent?.onEnded(translation, velocity)
            case .cancelled, .failed:
                parent?.onCancelled()
            default:
                break
            }
        }

        func gestureRecognizer(
            _ gestureRecognizer: UIGestureRecognizer,
            shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer
        ) -> Bool {
            false
        }
    }
}

/// The bridge's view: nothing but a ride into the hierarchy and a signal
/// that it has landed somewhere with a window.
final class EdgeSwipeBridgeView: UIView {
    var onMoveToWindow: (() -> Void)?

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window != nil { onMoveToWindow?() }
    }
}

/// The left-edge pan, with a start band wide enough to find.
///
/// `UIScreenEdgePanGestureRecognizer` only accepts touches inside the system's
/// own bezel, which on a phone in a case is a few points wide — the gesture
/// then reads as unreliable rather than as a feature. This recognizer accepts
/// a 44-point strip and fails the moment the movement is vertical, so a page
/// scroll that happens to start near the edge keeps its scroll.
final class LeftEdgeBackGestureRecognizer: UIGestureRecognizer {
    /// How far from the leading edge a touch may start and still count.
    var edgeWidth: CGFloat = 44

    private var startPoint: CGPoint = .zero
    private var previousPoint: CGPoint = .zero
    private var previousTimestamp: TimeInterval = 0
    private var translationValue: CGPoint = .zero
    private var velocityValue: CGPoint = .zero

    func translation(in view: UIView?) -> CGPoint { translationValue }
    func velocity(in view: UIView?) -> CGPoint { velocityValue }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        guard let touch = touches.first, let view else { return }
        startPoint = touch.location(in: view)
        previousPoint = startPoint
        previousTimestamp = touch.timestamp
        translationValue = .zero
        velocityValue = .zero
        state = startPoint.x <= edgeWidth ? .possible : .failed
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent) {
        guard let touch = touches.first, let view else { return }
        let point = touch.location(in: view)
        translationValue = CGPoint(
            x: point.x - startPoint.x,
            y: point.y - startPoint.y
        )
        let interval = max(touch.timestamp - previousTimestamp, 0.001)
        velocityValue = CGPoint(
            x: (point.x - previousPoint.x) / interval,
            y: (point.y - previousPoint.y) / interval
        )
        previousPoint = point
        previousTimestamp = touch.timestamp

        switch state {
        case .possible:
            // Vertical intent belongs to the page. Fail before the scroll
            // view's own recognizer is cancelled.
            if abs(translationValue.y) > abs(translationValue.x),
               abs(translationValue.y) > 6 {
                state = .failed
                return
            }
            if abs(translationValue.x) > 6 {
                state = .began
            }
        case .began, .changed:
            state = .changed
        default:
            break
        }
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) {
        if state == .began || state == .changed {
            state = .ended
        } else if state == .possible {
            state = .failed
        }
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent) {
        state = .cancelled
    }
}
