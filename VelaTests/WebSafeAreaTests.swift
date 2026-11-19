//
//  WebSafeAreaTests.swift
//  VelaTests
//
//  What a page actually receives as its safe-area insets.
//
//  `env(safe-area-inset-bottom)` is what a site's own bottom UI uses to keep
//  itself clear of the home indicator's gesture band. If the page reads zero,
//  its last row sits inside that band, where the system claims the touch and
//  the page never sees it. These tests measure the value a WKWebView reports
//  in the arrangements the app uses, so the fix is chosen from a measurement.
//

import XCTest
import WebKit
@testable import Vela

@MainActor
final class WebSafeAreaTests: XCTestCase {
    private func measure(
        behaviour: UIScrollView.ContentInsetAdjustmentBehavior,
        label: String,
        obscuredBottom: CGFloat? = nil
    ) async throws -> [String: Any] {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 820, height: 1080))
        window.windowScene = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }.first
        let controller = UIViewController()
        window.rootViewController = controller
        window.makeKeyAndVisible()
        controller.view.frame = window.bounds
        // A home-indicator-sized strip, whatever this simulator reports on
        // its own: 20 points is the iPad's inset.
        controller.additionalSafeAreaInsets = UIEdgeInsets(
            top: 0, left: 0, bottom: 20, right: 0
        )
        controller.view.layoutIfNeeded()

        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        let webView = WKWebView(frame: controller.view.bounds, configuration: configuration)
        webView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        webView.scrollView.contentInsetAdjustmentBehavior = behaviour
        if let obscuredBottom {
            if #available(iOS 26.0, *) {
                webView.obscuredContentInsets = UIEdgeInsets(
                    top: 0, left: 0, bottom: obscuredBottom, right: 0
                )
            }
        }
        controller.view.addSubview(webView)

        webView.loadHTMLString(
            """
            <!doctype html><html><head>
            <meta name="viewport" content="width=device-width, initial-scale=1, viewport-fit=cover">
            </head><body style="margin:0">
            <div id="probe" style="width:1px;height:env(safe-area-inset-bottom, -1px)"></div>
            </body></html>
            """,
            baseURL: URL(string: "https://example.com/")
        )

        // The probe, not `readyState`: the initial empty document reports
        // complete before the string's markup has committed, and reading it
        // there measures the wrong document.
        var ready: Bool?
        for _ in 0..<300 {
            ready = (try? await webView.evaluateJavaScript(
                "!!document.getElementById('probe')"
            )) as? Bool
            if ready == true { break }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        try await Task.sleep(nanoseconds: 300_000_000)
        controller.view.layoutIfNeeded()

        let page = try? await webView.evaluateJavaScript(
            """
            (function () {
              var probe = document.getElementById('probe');
              return {
                env: probe ? probe.getBoundingClientRect().height : -999,
                innerHeight: window.innerHeight,
                visualHeight: window.visualViewport ? window.visualViewport.height : -1,
                clientHeight: document.documentElement.clientHeight
              };
            })();
            """
        ) as? [String: Any]

        let result: [String: Any] = [
            "label": label,
            "behaviour": behaviour == .never ? "never" : "automatic",
            "envBottom": page?["env"] as? Double ?? -999,
            "pageInnerHeight": page?["innerHeight"] as? Double ?? -999,
            "pageVisualHeight": page?["visualHeight"] as? Double ?? -999,
            "pageClientHeight": page?["clientHeight"] as? Double ?? -999,
            "webViewSafeBottom": webView.safeAreaInsets.bottom,
            "webViewFrameHeight": webView.bounds.height,
            "rootSafeBottom": controller.view.safeAreaInsets.bottom,
            "windowSafeBottom": window.safeAreaInsets.bottom,
            "windowHeight": window.bounds.height
        ]
        window.isHidden = true
        return result
    }

    /// A measurement, not an expectation: the printed lines are the data the
    /// next change is based on.
    func testMeasureWhatThePageSeesAtTheBottom() async throws {
        print("VELA-SAFE-AREA plain=\(try await measure(behaviour: .never, label: "plain"))")
        print("VELA-SAFE-AREA automatic=\(try await measure(behaviour: .automatic, label: "automatic"))")
        print("VELA-SAFE-AREA obscured20=\(try await measure(behaviour: .never, label: "obscured20", obscuredBottom: 20))")
    }
}
