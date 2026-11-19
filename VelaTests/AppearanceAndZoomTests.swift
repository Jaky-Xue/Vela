//
//  AppearanceAndZoomTests.swift
//  VelaTests
//
//  The pure parts of the appearance, forced-zoom and automatic identity work.
//

import XCTest
import UIKit
import WebKit
@testable import Vela

final class AppearanceAndZoomTests: XCTestCase {
    func testAppearanceModeMapsToAWindowStyle() {
        XCTAssertEqual(AppearanceMode.system.userInterfaceStyle, .unspecified)
        XCTAssertEqual(AppearanceMode.light.userInterfaceStyle, .light)
        XCTAssertEqual(AppearanceMode.dark.userInterfaceStyle, .dark)
    }

    func testGestureZoomScriptRemovesTheViewportLock() {
        let enabled = WebPageScripts.gestureZoomViewportScript(enabled: true)
        XCTAssertTrue(enabled.contains("user-scalable=yes"))
        XCTAssertTrue(enabled.contains("maximum-scale=3"))
        XCTAssertTrue(enabled.contains("if (true)"))

        let disabled = WebPageScripts.gestureZoomViewportScript(enabled: false)
        XCTAssertTrue(disabled.contains("if (false)"))
    }

    func testTheAutomaticIdentityPresetIsFirstAndStoresNoString() {
        let first = BrowserUserAgentPreset.all[0]
        XCTAssertEqual(first.id, "auto")
        XCTAssertNil(first.userAgent)
        XCTAssertTrue(first.claimedSummary.contains("当前设备"))
    }

    func testTheIPadIdentifierClaimsATablet() {
        XCTAssertTrue(BrowserUserAgent.padIdentifier.contains("(iPad;"))
        XCTAssertTrue(BrowserUserAgent.padIdentifier.contains("Safari/604.1"))
    }

    // MARK: - Dark fallback

    /// A page that paints its dark theme on a wrapper leaves `body` and `html`
    /// transparent. The fallback used to read only those two backgrounds and
    /// invert the page, turning a dark site light in dark mode.
    @MainActor
    func testTheDarkFallbackStaysOffADarkPagePaintedOnAWrapper() async throws {
        let marker = try await darkFallbackMarker(html: """
            <!doctype html><html><body style="margin:0">
              <div style="min-height:100vh;background:#111;color:#eee;padding:24px">
                <h1>dark wrapper</h1>
              </div>
            </body></html>
            """)
        XCTAssertFalse(marker, "a page that paints itself dark must not be inverted")
    }

    @MainActor
    func testADarkPageWithALightSectionStaysDark() async throws {
        let marker = try await darkFallbackMarker(html: """
            <!doctype html><html><body style="margin:0;background:#111;color:#eee">
              <div style="height:35vh;background:#fff;color:#111">light card</div>
              <div style="height:65vh;background:#111;color:#eee">dark page</div>
            </body></html>
            """)
        XCTAssertFalse(marker, "a mostly dark page must keep its own appearance")
    }

    @MainActor
    func testTheDarkFallbackInvertsAPageThatPaintsLight() async throws {
        let marker = try await darkFallbackMarker(html: """
            <!doctype html><html><body style="margin:0;background:#fff;color:#111">
              <h1>light page</h1>
            </body></html>
            """)
        XCTAssertTrue(marker, "a page with no dark theme of its own gets the fallback")
    }

    /// A stored theme or a framework hydration can paint the page after the
    /// first pass. The filter has to come off when the page turns out dark.
    @MainActor
    func testTheDarkFallbackComesOffWhenThePageTurnsDarkLate() async throws {
        let marker = try await darkFallbackMarker(html: """
            <!doctype html><html><body style="margin:0;background:#fff;color:#111">
              <h1>late theme</h1>
              <script>
                setTimeout(function () {
                  document.body.style.background = '#101010';
                  document.body.style.color = '#eee';
                }, 300);
              </script>
            </body></html>
            """, settle: 2_000_000_000)
        XCTAssertFalse(marker, "a theme painted after the first pass must take the filter off")
    }

    /// Loads a fixture in a windowed web view that matches the dark scheme and
    /// asks whether the fallback marker is on the document.
    @MainActor
    private func darkFallbackMarker(html: String, settle: UInt64 = 900_000_000) async throws -> Bool {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.userContentController.addUserScript(WebPageScripts.makeAppearanceScript())
        let webView = WKWebView(
            frame: CGRect(x: 0, y: 0, width: 390, height: 844),
            configuration: configuration
        )
        webView.overrideUserInterfaceStyle = .dark
        let window = UIWindow(frame: webView.frame)
        window.windowScene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        window.rootViewController = UIViewController()
        window.rootViewController?.view.addSubview(webView)
        window.makeKeyAndVisible()
        defer {
            webView.stopLoading()
            webView.removeFromSuperview()
            window.isHidden = true
        }
        webView.loadHTMLString(html, baseURL: URL(string: "https://example.com/"))
        try await Task.sleep(nanoseconds: settle)
        let marker = try await webView.evaluateJavaScript(
            "document.documentElement.hasAttribute('data-vela-dark-fallback')"
        ) as? Bool
        return marker ?? false
    }
}
