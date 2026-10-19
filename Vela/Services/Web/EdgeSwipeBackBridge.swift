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
    var onBack: () -> Void

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
        var recognizer: UIScreenEdgePanGestureRecognizer?

        /// Installs the recognizer on the view directly below the window, and
        /// re-runs on every move to a window: SwiftUI can rebuild the bridge,
        /// and the recognizer has to follow the hierarchy it ends up in.
        func attach(from bridgeView: UIView) {
            if recognizer == nil {
                let edge = UIScreenEdgePanGestureRecognizer(
                    target: self,
                    action: #selector(edgePanned(_:))
                )
                edge.edges = .left
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

        @objc private func edgePanned(_ sender: UIScreenEdgePanGestureRecognizer) {
            guard sender.state == .ended else { return }
            parent?.onBack()
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
