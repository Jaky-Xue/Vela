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

    /// The two things a page must not do to a film that is in the system
    /// player: raise a keyboard over it, and paint its caption twice.
    func testAFullscreenFilmTakesThePagesKeyboardAndReportsThePresentation() async throws {
        let (webView, collector) = try await load(
            script: WebPageScripts.fullscreenBridge,
            handlerName: WebPageScripts.Handler.mediaFullscreen.rawValue
        )

        // The field stands in for a search box or a player's hidden input. Its
        // blur is counted rather than observed, so the test reads the guard's
        // decision and not whether a web view in a test host can hold focus.
        let observed = try await webView.evaluateJavaScript("""
            (function () {
              var field = document.createElement('input');
              field.type = 'search';
              document.body.appendChild(field);
              var video = document.createElement('video');
              // The real player reports fullscreen through this flag; the
              // test sets it so the guard does not depend on timer timing.
              Object.defineProperty(video, 'webkitDisplayingFullscreen', {
                value: true, configurable: true
              });
              document.body.appendChild(video);

              var blurs = 0;
              field.blur = function () {
                blurs += 1;
                HTMLInputElement.prototype.blur.call(this);
              };
              function announce(name) {
                video.dispatchEvent(new Event(name));
              }
              function focusWithoutATap() {
                field.dispatchEvent(new FocusEvent('focusin', { bubbles: true }));
              }
              function tapThenFocus() {
                var touch = new Event('touchstart', { bubbles: true });
                Object.defineProperty(touch, 'composedPath', {
                  value: function () { return [field]; }
                });
                field.dispatchEvent(touch);
                field.dispatchEvent(new FocusEvent('focusin', { bubbles: true }));
              }

              field.focus();
              announce('webkitbeginfullscreen');
              var afterBegin = blurs;

              focusWithoutATap();
              var afterUnaskedFocus = blurs;

              tapThenFocus();
              var afterTappedFocus = blurs;

              announce('webkitendfullscreen');
              focusWithoutATap();
              var afterEnd = blurs;

              return {
                afterBegin: afterBegin,
                afterUnaskedFocus: afterUnaskedFocus,
                afterTappedFocus: afterTappedFocus,
                afterEnd: afterEnd
              };
            })();
            """) as? [String: Any]

        let afterBegin = observed?["afterBegin"] as? Int ?? -1
        let afterUnaskedFocus = observed?["afterUnaskedFocus"] as? Int ?? -2
        let afterTappedFocus = observed?["afterTappedFocus"] as? Int ?? -3
        let afterEnd = observed?["afterEnd"] as? Int ?? -4

        XCTAssertEqual(
            afterUnaskedFocus,
            afterBegin + 1,
            "a focus the viewer did not tap must be let go while the film is up"
        )
        XCTAssertEqual(
            afterTappedFocus,
            afterUnaskedFocus + 1,
            "over the system player the page is not on screen, so no field may take focus"
        )
        XCTAssertEqual(
            afterEnd,
            afterTappedFocus,
            "the guard ends with the presentation"
        )

        var reports: [[String: Any]] = []
        for _ in 0..<200 {
            reports = collector?.messages ?? []
            if reports.count >= 2 { break }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertEqual(reports.first?["active"] as? Bool, true)
        XCTAssertEqual(reports.last?["active"] as? Bool, false)
    }

    /// A site's own player in element fullscreen still shows its page, so a
    /// field the viewer taps keeps the keyboard — but a field the player
    /// focuses for them does not. A fullscreen element with no video in it is
    /// not a film and must not touch fields at all.
    func testElementFullscreenOnlyRefusesFocusNoTapAskedFor() async throws {
        let (webView, _) = try await load(script: WebPageScripts.fullscreenBridge)

        let observed = try await webView.evaluateJavaScript("""
            (function () {
              var field = document.createElement('input');
              field.type = 'search';
              document.body.appendChild(field);
              var video = document.createElement('video');
              document.body.appendChild(video);
              var player = document.createElement('div');
              player.appendChild(video);
              document.body.appendChild(player);

              var blurs = 0;
              field.blur = function () {
                blurs += 1;
                HTMLInputElement.prototype.blur.call(this);
              };
              function focusWithoutATap() {
                field.dispatchEvent(new FocusEvent('focusin', { bubbles: true }));
              }
              function tapThenFocus() {
                var touch = new Event('touchstart', { bubbles: true });
                Object.defineProperty(touch, 'composedPath', {
                  value: function () { return [field]; }
                });
                field.dispatchEvent(touch);
                field.dispatchEvent(new FocusEvent('focusin', { bubbles: true }));
              }

              Object.defineProperty(document, 'fullscreenElement', {
                value: player, configurable: true
              });
              document.dispatchEvent(new Event('fullscreenchange'));
              var afterEntry = blurs;

              focusWithoutATap();
              var afterUnaskedFocus = blurs;

              tapThenFocus();
              var afterTappedFocus = blurs;

              // An image viewer, a document: no video, so no guard.
              var image = document.createElement('img');
              Object.defineProperty(document, 'fullscreenElement', {
                value: image, configurable: true
              });
              document.dispatchEvent(new Event('fullscreenchange'));
              focusWithoutATap();
              var afterNonVideoFullscreen = blurs;

              return {
                afterEntry: afterEntry,
                afterUnaskedFocus: afterUnaskedFocus,
                afterTappedFocus: afterTappedFocus,
                afterNonVideoFullscreen: afterNonVideoFullscreen
              };
            })();
            """) as? [String: Any]

        let afterEntry = observed?["afterEntry"] as? Int ?? -1
        let afterUnaskedFocus = observed?["afterUnaskedFocus"] as? Int ?? -2
        let afterTappedFocus = observed?["afterTappedFocus"] as? Int ?? -3
        let afterNonVideoFullscreen = observed?["afterNonVideoFullscreen"] as? Int ?? -4

        XCTAssertEqual(
            afterUnaskedFocus,
            afterEntry + 1,
            "a player that focuses a field for the viewer must be refused in fullscreen"
        )
        XCTAssertEqual(
            afterTappedFocus,
            afterUnaskedFocus,
            "a field the viewer tapped keeps the keyboard in element fullscreen"
        )
        XCTAssertEqual(
            afterNonVideoFullscreen,
            afterTappedFocus,
            "only a fullscreen video is a film; an image viewer leaves fields alone"
        )
    }

    func testAFullscreenFilmLaysItsCaptionLayerDownAgain() async throws {
        let (webView, _) = try await load(script: WebPageScripts.fullscreenBridge)

        // `mode` is read back through an own accessor that records every
        // write, so the test sees the bridge's hidden/shown cycle without
        // needing a cue layer to inspect.
        let initial = try await webView.evaluateJavaScript("""
            (function () {
              var video = document.createElement('video');
              Object.defineProperty(video, 'webkitDisplayingFullscreen', {
                value: true, configurable: true
              });
              document.body.appendChild(video);
              var track = video.addTextTrack('subtitles', '字幕', 'zh');
              var descriptor = Object.getOwnPropertyDescriptor(
                Object.getPrototypeOf(track), 'mode'
              );
              var writes = [];
              Object.defineProperty(track, 'mode', {
                get: function () { return descriptor.get.call(this); },
                set: function (value) {
                  writes.push(String(value));
                  descriptor.set.call(this, value);
                }
              });
              track.mode = 'showing';
              window.__velaCaptionWrites = writes;
              video.dispatchEvent(new Event('webkitbeginfullscreen'));
              return writes.slice();
            })();
            """) as? [String]

        XCTAssertEqual(initial, ["showing"])

        var recorded: [String] = []
        for _ in 0..<200 {
            recorded = (try? await webView.evaluateJavaScript("window.__velaCaptionWrites")) as? [String] ?? []
            if recorded.count >= 3, recorded.last == "showing" { break }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }

        XCTAssertEqual(recorded.first, "showing")
        XCTAssertEqual(
            recorded.dropFirst().prefix(2).map { $0 },
            ["hidden", "showing"],
            "the showing track must be taken down and put back so WebKit rebuilds the layer"
        )
    }

    /// WebKit's own YouTube caption mirror and the page's caption track can
    /// both be showing the same sentence in the system player. One has to
    /// stand down; two different sentences (two languages) must both stay.
    func testTwoTracksCarryingTheSameSentenceAreDrawnOnce() async throws {
        let (webView, _) = try await load(script: WebPageScripts.fullscreenBridge)

        let initial = try await webView.evaluateJavaScript("""
            (function () {
              var video = document.createElement('video');
              Object.defineProperty(video, 'webkitDisplayingFullscreen', {
                value: true, configurable: true
              });
              document.body.appendChild(video);
              function trackFor(label, text) {
                var track = video.addTextTrack('subtitles', label, 'zh');
                track.addCue(new VTTCue(0, 1000, text));
                track.mode = 'showing';
                return track;
              }
              // The page's own track and WebKit's mirror, then a second
              // language that must not be touched.
              var page = trackFor('中文', '你好，世界');
              var mirror = video.addTextTrack('forced', 'YouTube Captions');
              mirror.addCue(new VTTCue(0, 1000, '你好， 世界'));
              mirror.mode = 'showing';
              var other = trackFor('English', 'Hello, world');
              window.__velaTestTracks = [page, mirror, other];
              video.dispatchEvent(new Event('webkitbeginfullscreen'));
              return [page.mode, mirror.mode, other.mode];
            })();
            """) as? [String]

        XCTAssertEqual(initial, ["showing", "showing", "showing"])

        var modes: [String] = []
        for _ in 0..<200 {
            modes = (try? await webView.evaluateJavaScript("""
                window.__velaTestTracks.map(function (track) { return track.mode; })
                """)) as? [String] ?? []
            if modes == ["showing", "hidden", "showing"] { break }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }

        XCTAssertEqual(modes, ["showing", "hidden", "showing"])
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
