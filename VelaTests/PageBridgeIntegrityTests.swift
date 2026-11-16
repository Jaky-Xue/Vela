//
//  PageBridgeIntegrityTests.swift
//  VelaTests
//
//  What a site can see of Vela's page bridges.
//
//  The bridges replace functions the page reads back — `history.pushState`,
//  `navigator.geolocation.getCurrentPosition`, `Notification.requestPermission`
//  — and a bot check treats a wrapper it can see as a tampered browser. The
//  sites that answer that with a challenge which never clears are the reason
//  the wrappers are installed on the platform's prototypes and answer
//  `toString` the way the platform's own functions do. These tests run the real
//  scripts in a real `WKWebView` and ask the questions such a check asks; they
//  are about what the page observes, not about how the script is written.
//

import XCTest
import WebKit
@testable import Vela

/// Receives the bridge's reports. WebKit delivers script messages on the main
/// thread; the lock keeps the collector correct whatever thread that is.
private final class BridgeMessageCollector: NSObject, WKScriptMessageHandler, @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [[String: Any]] = []

    var messages: [[String: Any]] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    func userContentController(
        _ controller: WKUserContentController,
        didReceive message: WKScriptMessage
    ) {
        guard let body = message.body as? [String: Any] else { return }
        lock.lock()
        storage.append(body)
        lock.unlock()
    }
}

/// Resumes once a web view reports that a document finished loading.
private final class BridgeLoadWaiter: NSObject, WKNavigationDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Error>?

    func wait(timeout: TimeInterval) async throws {
        try await withCheckedThrowingContinuation { continuation in
            lock.lock()
            self.continuation = continuation
            lock.unlock()
            Task { [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                self?.finish(URLError(.timedOut))
            }
        }
    }

    private func finish(_ error: Error?) {
        lock.lock()
        let continuation = self.continuation
        self.continuation = nil
        lock.unlock()
        guard let continuation else { return }
        if let error {
            continuation.resume(throwing: error)
        } else {
            continuation.resume()
        }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { finish(nil) }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        finish(error)
    }

    func webView(
        _ webView: WKWebView,
        didFailProvisionalNavigation navigation: WKNavigation!,
        withError error: Error
    ) {
        finish(error)
    }
}

@MainActor
final class PageBridgeIntegrityTests: XCTestCase {
    private var webViews: [WKWebView] = []

    override func tearDown() async throws {
        webViews.forEach { $0.stopLoading() }
        webViews.removeAll()
        try await super.tearDown()
    }

    /// Loads a blank same-origin document with `script` injected the way a tab
    /// injects it.
    private func load(
        script: String,
        handlerName: String? = nil
    ) async throws -> (WKWebView, BridgeMessageCollector?) {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        let controller = WKUserContentController()
        configuration.userContentController = controller

        var collector: BridgeMessageCollector?
        if let handlerName {
            let box = BridgeMessageCollector()
            collector = box
            controller.add(box, name: handlerName)
        }
        controller.addUserScript(
            WKUserScript(source: script, injectionTime: .atDocumentStart, forMainFrameOnly: true)
        )

        let webView = WKWebView(frame: .zero, configuration: configuration)
        webViews.append(webView)
        let waiter = BridgeLoadWaiter()
        webView.navigationDelegate = waiter
        webView.loadHTMLString(
            "<!doctype html><html><body>bridge</body></html>",
            baseURL: URL(string: "https://example.com/")
        )
        try await waiter.wait(timeout: 5)
        return (webView, collector)
    }

    func testTheHistoryBridgeLooksLikeThePlatformAndStillReportsAChange() async throws {
        let (webView, collector) = try await load(
            script: WebPageScripts.historyApiBridge,
            handlerName: WebPageScripts.Handler.historyApi.rawValue
        )

        let observed = try await webView.evaluateJavaScript("""
            (function () {
              var descriptor = Object.getOwnPropertyDescriptor(
                Object.getPrototypeOf(history), 'pushState'
              );
              return {
                own: Object.prototype.hasOwnProperty.call(history, 'pushState'),
                text: String(history.pushState),
                name: history.pushState.name,
                enumerable: !!(descriptor && descriptor.enumerable)
              };
            })();
            """) as? [String: Any]

        XCTAssertEqual(observed?["own"] as? Bool, false, "the hook must not be an own property of history")
        XCTAssertEqual(observed?["enumerable"] as? Bool, false)
        XCTAssertEqual(observed?["name"] as? String, "pushState")
        XCTAssertEqual(
            observed?["text"] as? String,
            "function pushState() { [native code] }",
            "a page reads the wrapper's source, and it has to read the platform's"
        )

        // The hook still has to do its job. A document loaded from a string
        // carries the base URL as its address, so the push is same-origin and
        // the report the host depends on is the one it makes here.
        let pushed = try await webView.evaluateJavaScript("""
            (function () {
              try {
                history.pushState({}, '', 'https://example.com/next');
                return 'pushed';
              } catch (error) {
                return 'failed: ' + error.name;
              }
            })();
            """) as? String
        XCTAssertEqual(pushed, "pushed", "document URL: \(webView.url?.absoluteString ?? "nil")")

        let reports = await waitForReports(in: collector) { report in
            (report["kind"] as? String) == "pushState"
        }
        XCTAssertEqual(reports.first?["newUrl"] as? String, "https://example.com/next")
    }

    func testThePermissionBridgeLeavesThePlatformMethodsLookingNative() async throws {
        let (webView, _) = try await load(script: WebPageScripts.permissionBridge)

        let observed = try await webView.evaluateJavaScript("""
            (function () {
              var geolocation = navigator.geolocation;
              var notification = window.Notification;
              return {
                geolocationOwn: geolocation
                  ? Object.prototype.hasOwnProperty.call(geolocation, 'getCurrentPosition')
                  : null,
                geolocationHooked: geolocation
                  ? Object.prototype.hasOwnProperty.call(
                      Object.getPrototypeOf(geolocation), 'getCurrentPosition'
                    )
                  : null,
                geolocationText: geolocation ? String(geolocation.getCurrentPosition) : '',
                notificationText: notification && notification.requestPermission
                  ? String(notification.requestPermission) : ''
              };
            })();
            """) as? [String: Any]

        XCTAssertEqual(
            observed?["geolocationOwn"] as? Bool,
            false,
            "the gate belongs on the prototype, where the platform keeps the method"
        )
        XCTAssertEqual(observed?["geolocationHooked"] as? Bool, true)
        XCTAssertEqual(
            observed?["geolocationText"] as? String,
            "function getCurrentPosition() { [native code] }"
        )
        if let notification = observed?["notificationText"] as? String, !notification.isEmpty {
            XCTAssertTrue(notification.contains("[native code]"), notification)
        }
    }

    func testADesktopClaimReplacesThePlatformOnlyWhenItDiffers() {
        guard let script = WebPageScripts.identityConsistencyScript(
            userAgent: BrowserUserAgent.desktopIdentifier
        ) else {
            return XCTFail("a desktop claim has to align the platform")
        }
        // The replacement is conditional: on an iPad the desktop content mode
        // already answers MacIntel, and replacing an accessor with an identical
        // answer is exactly the visible tampering the condition avoids.
        XCTAssertTrue(script.contains("if (navigator.platform !== 'MacIntel')"), script)
        XCTAssertTrue(script.contains("get: velaNative("), script)
        XCTAssertFalse(script.contains("userAgentData"), script)
    }

    /// Waits for the first report the predicate accepts.
    private func waitForReports(
        in collector: BridgeMessageCollector?,
        matching predicate: ([String: Any]) -> Bool
    ) async -> [[String: Any]] {
        guard let collector else { return [] }
        for _ in 0..<200 {
            let matching = collector.messages.filter(predicate)
            if !matching.isEmpty { return matching }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        return []
    }
}
