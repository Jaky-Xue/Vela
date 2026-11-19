//
//  TapDeliveryTests.swift
//  VelaTests
//
//  Where a touch at the bottom of the screen actually lands.
//
//  A page's own bottom row can be visible and still not respond. This hosts
//  the real shell, opens a page with a fixed bottom link, hides the command
//  bar the way a scroll does, and asks the window what it hit-tests at points
//  near the bottom. The printed chain names the view that owns the touch, so
//  an overlay above the page is identified rather than guessed at.
//

import XCTest
import SwiftUI
import WebKit
@testable import Vela

@MainActor
final class TapDeliveryTests: XCTestCase {
    private func chain(of view: UIView?) -> String {
        var names: [String] = []
        var node = view
        var depth = 0
        while let current = node, depth < 12 {
            names.append(String(describing: type(of: current)))
            node = current.superview
            depth += 1
        }
        return names.joined(separator: " < ")
    }

    private func findWebView(in view: UIView) -> WKWebView? {
        if let webView = view as? WKWebView { return webView }
        for subview in view.subviews {
            if let found = findWebView(in: subview) { return found }
        }
        return nil
    }

    func testWhatOwnsATouchAtTheBottomOfThePage() async throws {
        let server = try LocalHTTPServer(routes: [
            "/": .html("""
            <meta name="viewport" content="width=device-width, initial-scale=1">
            <title>Tap fixture</title>
            <body style="margin:0;background:#f2f2f2">
            <div style="height:2400px;padding:16px;font:24px system-ui">tall page</div>
            <a href="/next" style="position:fixed;left:16px;right:16px;bottom:8px;height:48px;
               background:#e8e8e8;font:24px system-ui;text-align:center;line-height:48px">bottom link</a>
            </body>
            """)
        ])
        let base = try await server.start()
        defer { server.stop() }

        let env = AppEnvironment(
            services: AppServices(),
            windowId: "TapDelivery-" + UUID().uuidString
        )
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        window.windowScene = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }.first
        let controller = UIHostingController(
            rootView: BrowserShellView(environment: env)
                .environment(env)
                .environment(\.browserPalette, BrowserPalette.default)
                .environment(\.colorScheme, .light)
        )
        window.overrideUserInterfaceStyle = .light
        window.rootViewController = controller
        window.makeKeyAndVisible()
        controller.view.frame = window.bounds
        controller.view.layoutIfNeeded()

        let tab = env.tabManager.openTab(url: base, privacyMode: .regular)
        for _ in 0..<300 {
            if let webView = env.tabManager.webView(for: tab.id), webView.isLoading == false,
               webView.url != nil {
                break
            }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        try await Task.sleep(nanoseconds: 500_000_000)
        controller.view.layoutIfNeeded()

        let webView = try XCTUnwrap(findWebView(in: window), "the page must be on screen")
        let frameInWindow = webView.convert(webView.bounds, to: window)
        print("VELA-TAP window=\(window.bounds) webViewFrame=\(frameInWindow) safeBottom=\(window.safeAreaInsets.bottom)")

        func probe(_ label: String, _ point: CGPoint) {
            let hit = window.hitTest(point, with: nil)
            let insideWebView = webView.frame.contains(webView.superview?.convert(point, from: window) ?? .zero)
            print("VELA-TAP \(label) point=\(point) insideWebView=\(insideWebView) hit=\(String(describing: hit)) chain=\(chain(of: hit))")
        }

        probe("middle", CGPoint(x: window.bounds.midX, y: window.bounds.midY))
        probe("bottom-30", CGPoint(x: window.bounds.midX, y: window.bounds.maxY - 30))
        probe("bottom-70", CGPoint(x: window.bounds.midX, y: window.bounds.maxY - 70))

        // Hide the bar the way scrolling does: two downward samples past the
        // tracker's threshold.
        webView.scrollView.setContentOffset(CGPoint(x: 0, y: 120), animated: false)
        try await Task.sleep(nanoseconds: 200_000_000)
        webView.scrollView.setContentOffset(CGPoint(x: 0, y: 320), animated: false)
        try await Task.sleep(nanoseconds: 600_000_000)
        controller.view.layoutIfNeeded()

        let topHit = window.hitTest(
            CGPoint(x: window.bounds.midX, y: window.bounds.maxY - 30), with: nil
        )
        print("VELA-TAP after-scroll bottom-30 hit=\(String(describing: topHit)) chain=\(chain(of: topHit))")
        probe("after-scroll bottom-70", CGPoint(x: window.bounds.midX, y: window.bounds.maxY - 70))
    }
}
