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

    func testFullscreeningAPlayerContainerOpensItsVideoInTheSystemPlayer() async throws {
        let webKitStub = """
            Object.defineProperty(document, 'fullscreenEnabled', { value: true });
            Element.prototype.requestFullscreen = function () {
              return Promise.resolve('element fullscreen');
            };
            """
        let (webView, _) = try await load(script: webKitStub + "\n" + WebPageScripts.fullscreenBridge)
        let observed = try await webView.callAsyncJavaScript("""
            var player = document.body.appendChild(document.createElement('div'));
            var video = player.appendChild(document.createElement('video'));
            var requested = 0;
            Object.defineProperty(video, 'webkitSupportsFullscreen', { value: true });
            video.webkitEnterFullscreen = function () { requested += 1; };
            var result = await player.requestFullscreen();
            return requested === 1 && result === undefined;
            """, arguments: [:], in: nil, contentWorld: .page) as? Bool

        XCTAssertEqual(observed, true)
    }

    /// The system player keeps the page keyboard and duplicate captions out.
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

    /// The page leaves two languages showing. The system player must receive
    /// only the one the page is painting, so the second caption is never
    /// produced — not produced and then hidden.
    func testTwoShowingCaptionTracksReachThePlayerAsOne() async throws {
        let (webView, _) = try await load(script: WebPageScripts.fullscreenBridge)

        let initial = try await webView.evaluateJavaScript("""
            (function () {
              var video = document.createElement('video');
              Object.defineProperty(video, 'webkitDisplayingFullscreen', {
                value: true, configurable: true
              });
              document.body.appendChild(video);
              var painted = document.createElement('div');
              painted.className = 'ytp-caption-segment';
              painted.textContent = 'Hello, world';
              document.body.appendChild(painted);
              function trackFor(label, text) {
                var track = video.addTextTrack('subtitles', label, 'zh');
                Object.defineProperty(track, 'activeCues', {
                  value: [{ text: text }], configurable: true
                });
                track.mode = 'showing';
                return track;
              }
              var chinese = trackFor('中文', '你好，世界');
              var english = trackFor('English', 'Hello, world');
              window.__velaTestTracks = [chinese, english];
              video.dispatchEvent(new Event('webkitbeginfullscreen'));
              return [chinese.mode, english.mode];
            })();
            """) as? [String]

        XCTAssertEqual(
            initial,
            ["hidden", "showing"],
            "the track carrying the painted sentence is the only one that may draw"
        )
    }

    /// A language switch on the page changes the painted sentence while the
    /// tracks stay as they were. The player follows the sentence.
    func testALanguageSwitchFollowsThePaintedSentence() async throws {
        let (webView, _) = try await load(script: WebPageScripts.fullscreenBridge)

        let initial = try await webView.evaluateJavaScript("""
            (function () {
              var video = document.createElement('video');
              Object.defineProperty(video, 'webkitDisplayingFullscreen', {
                value: true, configurable: true
              });
              document.body.appendChild(video);
              var painted = document.createElement('div');
              painted.className = 'ytp-caption-segment';
              painted.textContent = 'Hello, world';
              document.body.appendChild(painted);
              function trackFor(label, text) {
                var track = video.addTextTrack('subtitles', label, 'zh');
                Object.defineProperty(track, 'activeCues', {
                  value: [{ text: text }], configurable: true
                });
                track.mode = 'hidden';
                return track;
              }
              var chinese = trackFor('中文', '你好，世界');
              var english = trackFor('English', 'Hello, world');
              window.__velaTestTracks = [chinese, english];
              window.__velaPainted = painted;
              video.dispatchEvent(new Event('webkitbeginfullscreen'));
              return [chinese.mode, english.mode];
            })();
            """) as? [String]
        XCTAssertEqual(initial, ["hidden", "showing"])

        // The site switches its caption language; only the painted text moves.
        _ = try await webView.evaluateJavaScript("""
            window.__velaPainted.textContent = '你好，世界';
            """)

        var modes: [String] = []
        for _ in 0..<200 {
            modes = (try? await webView.evaluateJavaScript("""
                window.__velaTestTracks.map(function (track) { return track.mode; })
                """)) as? [String] ?? []
            if modes == ["showing", "hidden"] { break }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertEqual(modes, ["showing", "hidden"])
    }

    /// WebKit's own YouTube caption mirror never becomes visible beside the
    /// page's track: the extra layer is refused at the setter, before it can
    /// be drawn.
    func testTheWebKitCaptionMirrorNeverBecomesVisibleBesideAPageTrack() async throws {
        let (webView, _) = try await load(script: WebPageScripts.fullscreenBridge)

        let observed = try await webView.evaluateJavaScript("""
            (function () {
              var video = document.createElement('video');
              Object.defineProperty(video, 'webkitDisplayingFullscreen', {
                value: true, configurable: true
              });
              document.body.appendChild(video);
              var page = video.addTextTrack('subtitles', '中文', 'zh');
              page.mode = 'showing';
              var mirror = video.addTextTrack('forced', 'YouTube Captions', 'und');
              video.dispatchEvent(new Event('webkitbeginfullscreen'));
              // WebKit's quirk switches its mirror on when the presentation
              // opens; the setter is where the duplicate is refused.
              mirror.mode = 'showing';
              return mirror.mode;
            })();
            """) as? String

        XCTAssertEqual(observed, "hidden")
    }

    /// The page's own modes come back when the film ends: a track the bridge
    /// switched on for the presentation is hidden again afterwards.
    func testLeavingFullscreenRestoresThePagesOwnCaptionState() async throws {
        let (webView, _) = try await load(script: WebPageScripts.fullscreenBridge)

        let observed = try await webView.evaluateJavaScript("""
            (function () {
              var video = document.createElement('video');
              Object.defineProperty(video, 'webkitDisplayingFullscreen', {
                value: true, configurable: true
              });
              document.body.appendChild(video);
              var painted = document.createElement('div');
              painted.className = 'ytp-caption-segment';
              painted.textContent = 'Hello, world';
              document.body.appendChild(painted);
              var track = video.addTextTrack('subtitles', 'English', 'zh');
              Object.defineProperty(track, 'activeCues', {
                value: [{ text: 'Hello, world' }], configurable: true
              });
              track.mode = 'hidden';
              video.dispatchEvent(new Event('webkitbeginfullscreen'));
              var during = track.mode;
              video.dispatchEvent(new Event('webkitendfullscreen'));
              return { during: during, after: track.mode };
            })();
            """) as? [String: String]

        XCTAssertEqual(observed?["during"], "showing")
        XCTAssertEqual(observed?["after"], "hidden")
    }

    func testReturningInlineReleasesCaptionMirrorAndIgnoresOtherVideos() async throws {
        let (webView, _) = try await load(script: WebPageScripts.fullscreenBridge)

        let observed = try await webView.evaluateJavaScript("""
            (function () {
              var video = document.body.appendChild(document.createElement('video'));
              var other = document.body.appendChild(document.createElement('video'));
              var page = video.addTextTrack('subtitles', 'English', 'en');
              var mirror = video.addTextTrack('forced', 'YouTube Captions', 'und');
              page.mode = 'showing';
              mirror.mode = 'showing';

              video.dispatchEvent(new Event('webkitbeginfullscreen'));
              other.dispatchEvent(new Event('webkitpresentationmodechanged'));
              mirror.mode = 'showing';
              var during = mirror.mode;

              video.dispatchEvent(new Event('webkitendfullscreen'));
              return { during: during, after: mirror.mode,
                hasOverride: String(Object.hasOwn(mirror, 'mode')) };
            })();
            """) as? [String: String]

        XCTAssertEqual(observed?["during"], "hidden")
        XCTAssertEqual(observed?["after"], "showing")
        XCTAssertEqual(observed?["hasOverride"], "false")
    }

    /// Turning captions off in the system player's own menu is the viewer's
    /// decision. A painted sentence the page has not changed must not switch
    /// them back on.
    func testTurningCaptionsOffInThePlayerIsNotUndone() async throws {
        let (webView, _) = try await load(script: WebPageScripts.fullscreenBridge)

        let initial = try await webView.evaluateJavaScript("""
            (function () {
              var video = document.createElement('video');
              Object.defineProperty(video, 'webkitDisplayingFullscreen', {
                value: true, configurable: true
              });
              document.body.appendChild(video);
              var painted = document.createElement('div');
              painted.className = 'ytp-caption-segment';
              painted.textContent = 'Hello, world';
              document.body.appendChild(painted);
              var track = video.addTextTrack('subtitles', 'English', 'zh');
              Object.defineProperty(track, 'activeCues', {
                value: [{ text: 'Hello, world' }], configurable: true
              });
              track.mode = 'hidden';
              window.__velaTestTrack = track;
              video.dispatchEvent(new Event('webkitbeginfullscreen'));
              var on = track.mode;
              // The viewer takes the caption off in the system player.
              track.mode = 'hidden';
              return on;
            })();
            """) as? String
        XCTAssertEqual(initial, "showing")

        try await Task.sleep(nanoseconds: 1_200_000_000)
        let mode = try await webView.evaluateJavaScript("window.__velaTestTrack.mode") as? String
        XCTAssertEqual(mode, "hidden", "the poll must not resurrect a caption the viewer turned off")
    }

    /// The page's own fullscreen is a film too. Its player stays on screen,
    /// so tapping 倍速 or any other control must not bring the page's keyboard
    /// back, and a caption the page paints must not be drawn a second time by
    /// a text track left showing.
    func testElementFullscreenOfAVideoTakesTheKeyboardAndTheSecondCaption() async throws {
        let (webView, collector) = try await load(
            script: WebPageScripts.fullscreenBridge,
            handlerName: WebPageScripts.Handler.mediaFullscreen.rawValue
        )

        let observed = try await webView.evaluateJavaScript("""
            (function () {
              var player = document.createElement('div');
              document.body.appendChild(player);
              var video = document.createElement('video');
              player.appendChild(video);
              // The page paints the caption itself and also leaves a track
              // showing for it — the shape that drew the same sentence twice.
              var painted = document.createElement('div');
              painted.className = 'ytp-caption-segment';
              painted.textContent = 'Hello, world';
              player.appendChild(painted);

              function trackFor(label, text, mode) {
                var track = video.addTextTrack('subtitles', label, 'zh');
                Object.defineProperty(track, 'activeCues', {
                  value: [{ text: text }], configurable: true
                });
                track.mode = mode;
                return track;
              }
              var english = trackFor('English', 'Hello, world', 'showing');
              var chinese = trackFor('中文', '你好，世界', 'hidden');
              window.__velaTracks = [english, chinese];

              var field = document.createElement('input');
              field.type = 'search';
              player.appendChild(field);
              var blurs = 0;
              field.blur = function () {
                blurs += 1;
                HTMLInputElement.prototype.blur.call(this);
              };

              Object.defineProperty(document, 'fullscreenElement', {
                value: player, configurable: true
              });
              document.dispatchEvent(new Event('fullscreenchange'));
              var afterEntry = [english.mode, chinese.mode];

              // A player that focuses its own input for the viewer: refused.
              field.dispatchEvent(new FocusEvent('focusin', { bubbles: true }));
              var afterUnaskedFocus = blurs;

              Object.defineProperty(document, 'fullscreenElement', {
                value: null, configurable: true
              });
              document.dispatchEvent(new Event('fullscreenchange'));
              var afterExit = [english.mode, chinese.mode];

              return {
                afterEntry: afterEntry,
                afterUnaskedFocus: afterUnaskedFocus,
                afterExit: afterExit
              };
            })();
            """) as? [String: Any]

        XCTAssertEqual(
            observed?["afterEntry"] as? [String],
            ["hidden", "hidden"],
            "the page paints this caption; a showing track would draw it twice"
        )
        XCTAssertEqual(
            observed?["afterUnaskedFocus"] as? Int,
            1,
            "the page may not take the keyboard over its own fullscreen film"
        )
        XCTAssertEqual(
            observed?["afterExit"] as? [String],
            ["showing", "hidden"],
            "leaving the film gives the page its own track modes back"
        )

        var reports: [[String: Any]] = []
        for _ in 0..<300 {
            reports = collector?.messages ?? []
            if reports.count >= 2 { break }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertEqual(reports.first?["active"] as? Bool, true)
        XCTAssertEqual(reports.last?["active"] as? Bool, false)
        XCTAssertEqual(reports.count, 2, "one report per state change, not per tap")
    }

    /// A player commonly parks a hidden input inside the control the finger
    /// lands on. The tap belongs to the control, not to that input, so the
    /// keyboard must not come up over the film.
    func testAnInputInsideTheTappedControlCannotTakeTheKeyboard() async throws {
        let (webView, _) = try await load(script: WebPageScripts.fullscreenBridge)

        let observed = try await webView.evaluateJavaScript("""
            (function () {
              var player = document.createElement('div');
              document.body.appendChild(player);
              var video = document.createElement('video');
              player.appendChild(video);

              var wrapper = document.createElement('button');
              player.appendChild(wrapper);
              var field = wrapper.appendChild(document.createElement('input'));
              field.type = 'text';
              field.style.width = '120px';
              field.style.height = '24px';
              var blurs = 0;
              field.blur = function () {
                blurs += 1;
                HTMLInputElement.prototype.blur.call(this);
              };

              Object.defineProperty(document, 'fullscreenElement', {
                value: player, configurable: true
              });
              document.dispatchEvent(new Event('fullscreenchange'));

              var touch = new Event('touchstart', { bubbles: true });
              Object.defineProperty(touch, 'composedPath', {
                value: function () { return [wrapper]; }
              });
              wrapper.dispatchEvent(touch);
              field.dispatchEvent(new FocusEvent('focusin', { bubbles: true }));
              return blurs;
            })();
            """) as? Int

        XCTAssertEqual(
            observed,
            1,
            "a tap on the wrapper is not a tap on the field it holds"
        )
    }

    /// A container can hold a preview video the page wrote first, and the one
    /// playing the film. The system player must get the film.
    func testAPlayerContainerHandsTheSystemPlayerTheVideoCarryingThePicture() async throws {
        let webKitStub = """
            Object.defineProperty(document, 'fullscreenEnabled', { value: true });
            Element.prototype.requestFullscreen = function () {
              return Promise.resolve('element fullscreen');
            };
            """
        let (webView, _) = try await load(script: webKitStub + "\n" + WebPageScripts.fullscreenBridge)
        let requested = try await webView.callAsyncJavaScript("""
            var player = document.body.appendChild(document.createElement('div'));
            var preview = player.appendChild(document.createElement('video'));
            var film = player.appendChild(document.createElement('video'));
            var requestedBy = '';
            Object.defineProperty(preview, 'webkitSupportsFullscreen', { value: true });
            preview.webkitEnterFullscreen = function () { requestedBy = 'preview'; };
            Object.defineProperty(film, 'webkitSupportsFullscreen', { value: true });
            Object.defineProperty(film, 'readyState', { value: 4 });
            film.webkitEnterFullscreen = function () { requestedBy = 'film'; };
            await player.requestFullscreen();
            return requestedBy;
            """, arguments: [:], in: nil, contentWorld: .page) as? String

        XCTAssertEqual(requested, "film")
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
