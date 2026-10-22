//
//  WebPageScripts.swift
//  Vela
//
//  The document-start and document-end scripts injected into every page.
//
//  These exist because a `WKWebView` reports a navigation only when the document
//  changes. A single-page app calling `history.pushState` changes the URL without
//  ever navigating, so without the bridge below the address bar keeps showing the
//  URL the user arrived on, and back and forward stop reflecting where they
//  actually are.
//

import Foundation
import WebKit

public enum WebPageScripts {
    /// Message handler names. One handler with a `type` field would be smaller,
    /// but separate names let a delegate method be a `switch`-free single case,
    /// which keeps the coordinator readable.
    public enum Handler: String, CaseIterable {
        case historyApi = "velaHistoryApi"
        case scroll = "velaScroll"
        case pageMetrics = "velaPageMetrics"
        case elementPick = "velaElementPick"
        case console = "velaConsole"
        case userScript = "velaUserScript"
        case adBlockReport = "velaAdBlockReport"
        /// New text blocks found by the translation observer after a page
        /// has been translated once. The service answers with a batch of
        /// translated HTML.
        case translation = "velaTranslation"
    }

    // MARK: - History API bridge

    /// Reports `pushState` / `replaceState` / `popstate` / `hashchange` to the
    /// host, with a "only report a real change" guard: a `replaceState` that
    /// keeps the same URL must not produce an event, or an SPA that normalises
    /// its URL on every render would fire a spurious navigation on each frame.
    public static let historyApiBridge = """
    (function () {
      if (window.__velaHistoryApiBridgeInstalled === true) { return; }
      window.__velaHistoryApiBridgeInstalled = true;
      window.__velaHistoryApiBridgeLastUrl = String(window.location && window.location.href || '');

      function notify(kind, oldUrl, newUrl) {
        try {
          var normalizedOldUrl = String(oldUrl || '');
          var normalizedNewUrl = String(newUrl || '');
          if (!normalizedNewUrl || normalizedOldUrl === normalizedNewUrl) { return; }
          if (window.webkit && window.webkit.messageHandlers &&
              window.webkit.messageHandlers.\(Handler.historyApi.rawValue)) {
            window.webkit.messageHandlers.\(Handler.historyApi.rawValue).postMessage({
              kind: String(kind || ''),
              oldUrl: normalizedOldUrl,
              newUrl: normalizedNewUrl,
              timestamp: Date.now()
            });
          }
          window.__velaHistoryApiBridgeLastUrl = normalizedNewUrl;
        } catch (_error) {
        }
      }

      function installHistoryHook(methodName) {
        var original = history[methodName];
        if (typeof original !== 'function') { return; }
        history[methodName] = function (state, title, url) {
          var before = String(window.location.href || '');
          var result = original.apply(this, arguments);
          var after = String(window.location.href || '');
          notify(methodName === 'pushState' ? 'pushState' : 'replaceState', before, after);
          return result;
        };
      }

      installHistoryHook('pushState');
      installHistoryHook('replaceState');

      window.addEventListener('popstate', function () {
        var before = window.__velaHistoryApiBridgeLastUrl;
        var after = String(window.location.href || '');
        notify('popstate', before, after);
      }, true);

      window.addEventListener('hashchange', function () {
        var before = window.__velaHistoryApiBridgeLastUrl;
        var after = String(window.location.href || '');
        notify('hashchange', before, after);
      }, true);

      // The initial report lets the host settle a URL the page rewrote before
      // the bridge was installed.
      notify('init', '', String(window.location.href || ''));
    })();
    """

    // MARK: - Fullscreen bridge

    /// Routes a page's fullscreen request to the system video player whenever
    /// the element being fullscreened contains a video.
    ///
    /// The stock `<video>` controls' button and sites that call
    /// `video.webkitEnterFullscreen()` already reach the native player — that
    /// path is media-specific and WebKit handles it well. What never reaches
    /// it is the fullscreen button on a *custom* player: those call the
    /// Fullscreen API on a container `<div>`, and WebKit's generic element
    /// fullscreen presents a snapshot of the element — a path in which the
    /// video's hardware compositing layer does not participate, so the user
    /// sees the player chrome enter fullscreen over a black rectangle. The
    /// wrapper below redirects any fullscreen request on a video-bearing
    /// element to the video itself and the native player, which is the
    /// presentation the user asked for; elements without a video fall through
    /// to the ordinary API untouched.
    ///
    /// Subtitles need one more step on that redirect. The native player
    /// renders a text track only while the track's mode is `showing`, but a
    /// custom player keeps its tracks `hidden` and draws the cues into its own
    /// DOM overlay — which the native player cannot show, because it plays the
    /// bare video element. So the wrapper switches subtitle and caption tracks
    /// to `showing` on the way in, which is what makes the native player draw
    /// the captions, and restores each track's original mode when the video
    /// returns to `inline`, which is what keeps those captions from doubling
    /// the page's own overlay after leaving fullscreen.
    ///
    /// A page with no track behind its captions needs a second road. YouTube
    /// is the case that matters: its player paints the sentence into its own
    /// cue windows and never exposes a text track, so there is nothing to
    /// switch on and the native player shows a silent picture. While the video
    /// is in the native player a mirror therefore reads the sentence the page
    /// is painting and re-states it as a cue on a text track it adds to the
    /// video — the one shape the native player can draw. It covers YouTube's
    /// cue windows, Bilibili's subtitle strip and the cue elements of the
    /// common JavaScript players; a page that does have a showing track with
    /// live cues is left alone, so the two never draw the same sentence twice.
    ///
    /// The takeover has to cover every road into the native player, not just
    /// the Fullscreen API: the fullscreen button on many players calls the
    /// video's own `webkitEnterFullscreen()` directly, and some enter through
    /// `webkitSetPresentationMode('fullscreen')`. All three are hooked, and
    /// tracks a player adds only once playback is under way are picked up by
    /// an `addtrack` listener that keeps them shown while the video is in the
    /// native player — a page typically sets its preferred mode right after
    /// adding the track, so the assertion is repeated once that has settled.
    public static let fullscreenBridge = """
    (function () {
      if (window.__velaFullscreenBridgeInstalled === true) { return; }
      window.__velaFullscreenBridgeInstalled = true;

      function findVideo(element) {
        if (!element) { return null; }
        if (element.tagName === 'VIDEO') { return element; }
        if (element.querySelector) { return element.querySelector('video'); }
        return null;
      }

      function forceShowing(tracks) {
        for (var i = 0; i < tracks.length; i++) {
          var kind = tracks[i].kind;
          if (kind !== 'subtitles' && kind !== 'captions') { continue; }
          if (tracks[i].mode !== 'showing') {
            try { tracks[i].mode = 'showing'; } catch (error) {}
          }
        }
      }

      // Captions a page paints itself, rather than through a text track.
      // Ordered by specificity: the first selector that yields visible text
      // wins, so a player's outer window cannot duplicate its segments.
      var captionSelectors = [
        '.ytp-caption-segment',
        '.caption-window .captions-text',
        '.bpx-player-subtitle-panel-text',
        '.bpx-player-video-subtitle',
        '.vjs-text-track-cue',
        '.jw-text-track-cue',
        '.plyr__captions',
        '.dplayer-subtitle',
        '.art-subtitle'
      ];

      function paintedCaptionText(includeHidden) {
        for (var s = 0; s < captionSelectors.length; s++) {
          var nodes = document.querySelectorAll(captionSelectors[s]);
          var parts = [];
          for (var i = 0; i < nodes.length; i++) {
            var node = nodes[i];
            if (!includeHidden && (!node.getClientRects || node.getClientRects().length === 0)) { continue; }
            var text = node.innerText || node.textContent || '';
            text = String(text).replace(/\\u200B|\\u200C|\\u200D|\\uFEFF/g, '');
            text = String(text).replace(/\\s+/g, ' ').trim();
            if (text && parts.indexOf(text) === -1) { parts.push(text); }
          }
          if (parts.length) {
            var joined = parts.join(' ');
            return joined.length > 400 ? joined.slice(0, 400) : joined;
          }
        }
        return '';
      }

      // Every other caption layer stands down while the mirror carries text.
      // That includes WebKit's own YouTube caption mirror — a forced track it
      // names 'YouTube Captions' and draws beside ours, which is what put two
      // identical lines on screen. A track is only suppressed once our mirror
      // has a sentence to show: on a video whose cues our selectors cannot
      // read, WebKit's track is left alone and may still draw the caption.
      function hideOtherCaptionTracks(video, mirror) {
        var tracks = video.textTracks;
        if (!tracks) { return; }
        if (!video.__velaSuppressedCaptionTracks) {
          video.__velaSuppressedCaptionTracks = [];
        }
        for (var i = 0; i < tracks.length; i++) {
          var track = tracks[i];
          if (track === mirror) { continue; }
          var carriesCaption = track.kind === 'subtitles' ||
            track.kind === 'captions' ||
            track.kind === 'forced';
          if (!carriesCaption) { continue; }
          if (track.mode !== 'showing') { continue; }
          // The mode is remembered, not assumed: a caption track the user
          // turned on has to come back on when the mirror stands down. The
          // old code restored every suppressed track to 'hidden', which left
          // YouTube's captions switched off for good after one fullscreen
          // visit.
          video.__velaSuppressedCaptionTracks.push({ track: track, mode: track.mode });
          try { track.mode = 'disabled'; } catch (error) {}
        }
      }

      function restoreOtherCaptionTracks(video) {
        var saved = video.__velaSuppressedCaptionTracks;
        if (!saved) { return; }
        video.__velaSuppressedCaptionTracks = null;
        for (var i = 0; i < saved.length; i++) {
          try { saved[i].track.mode = saved[i].mode; } catch (error) {}
        }
      }

      function clearMirrorCues(track) {
        if (!track || !track.cues) { return; }
        while (track.cues.length > 0) {
          try { track.removeCue(track.cues[0]); } catch (error) { break; }
        }
      }

      function stopCaptionMirror(video) {
        if (video.__velaCaptionMirrorTimer) {
          clearInterval(video.__velaCaptionMirrorTimer);
          video.__velaCaptionMirrorTimer = null;
        }
        restoreOtherCaptionTracks(video);
        var track = video.__velaCaptionMirrorTrack;
        if (!track) { return; }
        clearMirrorCues(track);
        try { track.mode = 'disabled'; } catch (error) {}
      }

      // Mirrors the page's own caption paint into a text track the native
      // player can draw. The track is `forced` and stays hidden until the
      // presentation actually opens: a forced track is drawn by the native
      // player without having to be picked from its caption menu, and keeping
      // it hidden inline is what stops the mirror from doubling the page's own
      // captions before fullscreen. WebKit's own CNN quirk mirrors DOM
      // captions into a forced track the same way.
      function startCaptionMirror(video) {
        if (video.__velaCaptionMirrorTimer) { return; }
        if (typeof video.addTextTrack !== 'function') { return; }
        var track = video.__velaCaptionMirrorTrack;
        if (!track) {
          // `forced` is the kind WebKit's own caption mirrors use, and the
          // native player draws it without a menu choice; a WebKit that
          // refuses the kind still gets an ordinary captions track.
          try {
            track = video.addTextTrack('forced', '字幕', 'und');
          } catch (error) {
            try { track = video.addTextTrack('captions', '字幕', 'und'); } catch (error) { return; }
          }
          video.__velaCaptionMirrorTrack = track;
        }
        try { track.mode = 'hidden'; } catch (error) {}
        var startedAt = Date.now();
        var painted = null;

        function sync() {
          if (!video.isConnected) { stopCaptionMirror(video); return; }
          var mode = video.webkitPresentationMode;
          if (mode === 'inline' && Date.now() - startedAt > 2000) {
            stopCaptionMirror(video);
            return;
          }
          if (mode && mode !== 'inline' && track.mode !== 'showing') {
            try { track.mode = 'showing'; } catch (error) {}
          }
          // Inside the native presentation the page's overlay is behind the
          // player and may be hidden outright, so text counts there whether
          // or not it is painted. Inline it has to be visible: a player keeps
          // hidden copies of its cue elements, and those are not captions.
          var text = paintedCaptionText(mode && mode !== 'inline');
          if (text !== painted) {
            painted = text;
            clearMirrorCues(track);
            if (text) {
              try {
                var cue = new VTTCue(Math.max(0, video.currentTime - 0.3), video.currentTime + 600, text);
                cue.line = 'auto';
                track.addCue(cue);
              } catch (error) {}
            }
          }
          // Repeated every tick: a player can switch a track on at any time
          // (its addtrack listener, WebKit's quirk, the native menu), and the
          // mirror has to stay the only caption layer while it carries the
          // sentence. Suppression belongs to the native presentation only:
          // inline the mirror is hidden, so standing the page's own track
          // down there removed the captions the viewer was reading.
          if (mode && mode !== 'inline' && painted) {
            hideOtherCaptionTracks(video, track);
          }
        }

        sync();
        video.__velaCaptionMirrorTimer = setInterval(sync, 150);
      }

      function exposeSubtitlesToNativePlayer(video) {
        var tracks = video.textTracks;
        if (!tracks) { return; }
        if (!video.__velaSavedTrackModes) {
          var saved = [];
          for (var i = 0; i < tracks.length; i++) { saved.push(tracks[i].mode); }
          video.__velaSavedTrackModes = saved;
          try {
            tracks.addEventListener('addtrack', function (event) {
              var track = event.track;
              if (!track || (track.kind !== 'subtitles' && track.kind !== 'captions')) { return; }
              if (video.webkitPresentationMode !== 'fullscreen') { return; }
              try { track.mode = 'showing'; } catch (error) {}
              setTimeout(function () {
                if (video.webkitPresentationMode === 'fullscreen') {
                  try { track.mode = 'showing'; } catch (error) {}
                }
              }, 300);
            });
          } catch (error) {}
          video.addEventListener('webkitpresentationmodechanged', function () {
            if (video.webkitPresentationMode !== 'inline') {
              startCaptionMirror(video);
              return;
            }
            stopCaptionMirror(video);
            var modes = video.__velaSavedTrackModes;
            if (!modes) { return; }
            video.__velaSavedTrackModes = null;
            for (var j = 0; j < tracks.length && j < modes.length; j++) {
              try { tracks[j].mode = modes[j]; } catch (error) {}
            }
          });
          // The native player's own roads also announce themselves; they are
          // the only signal when the system's controls opened the presentation.
          video.addEventListener('webkitbeginfullscreen', function () {
            startCaptionMirror(video);
          });
          video.addEventListener('webkitendfullscreen', function () {
            stopCaptionMirror(video);
          });
        }
        forceShowing(tracks);
        startCaptionMirror(video);
      }

      function patch(proto, name) {
        var original = proto && proto[name];
        if (typeof original !== 'function') { return; }
        proto[name] = function () {
          var video = findVideo(this);
          if (video && typeof video.webkitEnterFullscreen === 'function') {
            exposeSubtitlesToNativePlayer(video);
            try { video.webkitEnterFullscreen(); } catch (error) {}
            try { document.dispatchEvent(new Event('fullscreenchange')); } catch (error) {}
            return Promise.resolve();
          }
          return original.apply(this, arguments);
        };
      }

      patch(Element.prototype, 'requestFullscreen');
      patch(Element.prototype, 'webkitRequestFullscreen');

      var videoProto = window.HTMLVideoElement && HTMLVideoElement.prototype;
      if (videoProto && typeof videoProto.webkitEnterFullscreen === 'function') {
        var nativeEnterFullscreen = videoProto.webkitEnterFullscreen;
        videoProto.webkitEnterFullscreen = function () {
          exposeSubtitlesToNativePlayer(this);
          return nativeEnterFullscreen.apply(this, arguments);
        };
      }
      if (videoProto && typeof videoProto.webkitSetPresentationMode === 'function') {
        var nativeSetPresentationMode = videoProto.webkitSetPresentationMode;
        videoProto.webkitSetPresentationMode = function (mode) {
          if (mode === 'fullscreen') { exposeSubtitlesToNativePlayer(this); }
          return nativeSetPresentationMode.apply(this, arguments);
        };
      }
    })();
    """

    // MARK: - Identifier consistency

    /// Makes a hand-picked identifier hold together as a whole.
    ///
    /// A preset only rewrites the `User-Agent` header; everything else a page
    /// can ask stays WebKit's own — `navigator.vendor` reports Apple,
    /// `navigator.userAgentData` is absent, `window.chrome` is missing. A
    /// site's risk control reads exactly those, and a UA claiming Chrome
    /// beside a vendor saying Apple is the textbook mismatch such a check
    /// exists to catch — the shape of YouTube's 「出了点问题」 screens. So
    /// when a tab presents a hand-picked identifier, this script aligns the
    /// rest of the surface with the claim:
    ///
    /// * A Chromium claim (`Chrome/`, `Edg/`) gains the `userAgentData`
    ///   object real Chromium exposes — brands, platform, mobility, and a
    ///   `getHighEntropyValues` answer — plus Google's vendor and
    ///   `window.chrome`.
    /// * A Chrome-on-iOS claim (`CriOS/`) gains only the vendor: real Chrome
    ///   on iOS runs on WebKit and has no `userAgentData`, so adding one
    ///   would be its own mismatch.
    /// * A Firefox claim gains Firefox's empty vendor and nothing else —
    ///   Firefox has no `userAgentData` either.
    /// * Vela's default and the Safari presets send no script at all:
    ///   WebKit already is Safari, and its surface is consistent by
    ///   construction.
    ///
    /// Returns nil when there is nothing to align.
    public static func identityConsistencyScript(userAgent: String) -> String? {
        let lowered = userAgent.lowercased()
        let claimsChromiumData = lowered.contains("chrome/") || lowered.contains("edg/")
        let claimsCriOS = lowered.contains("crios/")
        let claimsFirefox = lowered.contains("firefox/")
        guard claimsChromiumData || claimsCriOS || claimsFirefox else { return nil }

        func majorToken(after marker: String) -> String? {
            guard let range = lowered.range(of: marker) else { return nil }
            let digits = lowered[range.upperBound...].prefix { $0.isNumber }
            return digits.isEmpty ? nil : String(digits)
        }
        let chromiumMajor = majorToken(after: "chrome/") ?? majorToken(after: "edg/") ?? "120"
        let isEdge = lowered.contains("edg/")

        let vendor: String = (claimsChromiumData || claimsCriOS) ? "Google Inc." : ""

        let platform: String
        if lowered.contains("android") { platform = "Android" }
        else if lowered.contains("macintosh") { platform = "macOS" }
        else if lowered.contains("windows") { platform = "Windows" }
        else { platform = "Chrome OS" }
        let mobile = lowered.contains("android")

        let platformVersion: String
        switch platform {
        case "Android": platformVersion = "\(majorToken(after: "android ") ?? "14").0.0"
        case "macOS": platformVersion = "13.5.0"
        default: platformVersion = "10.0.0"
        }

        // The platform and the touch-point count were still the iPad's on
        // every preset: a Windows Chrome claim beside a platform of "MacIntel"
        // and five touch points is the mismatch a site's browser check reads
        // first. Chrome on iOS is left alone — it really is WebKit on iOS.
        let claimedPlatform: String
        switch platform {
        case "Android": claimedPlatform = "Linux armv8l"
        case "macOS": claimedPlatform = "MacIntel"
        case "Windows": claimedPlatform = "Win32"
        default: claimedPlatform = "Linux x86_64"
        }
        let claimedTouchPoints = mobile ? 5 : 0
        let platformLiteral = Self.jsonString(claimedPlatform)

        let grease = ["brand": "Not_A Brand", "version": "24"]
        let brands: [[String: String]] = isEdge
            ? [["brand": "Microsoft Edge", "version": majorToken(after: "edg/") ?? chromiumMajor],
               ["brand": "Chromium", "version": chromiumMajor],
               grease]
            : [["brand": "Google Chrome", "version": chromiumMajor],
               ["brand": "Chromium", "version": chromiumMajor],
               grease]
        let brandsJSON = (try? JSONSerialization.data(withJSONObject: brands))
            .flatMap { String(data: $0, encoding: .utf8) } ?? "[]"

        let vendorBlock = """
          try {
            Object.defineProperty(Navigator.prototype, 'vendor', {
              get: function () { return \(Self.jsonString(vendor)); },
              configurable: true
            });
          } catch (error) {}
        """

        let userAgentDataBlock = claimsChromiumData ? """
          try {
            if (!navigator.userAgentData) {
              var brands = \(brandsJSON);
              var data = {
                brands: brands,
                mobile: \(mobile),
                platform: '\(platform)'
              };
              data.getHighEntropyValues = function (hints) {
                return Promise.resolve({
                  brands: brands,
                  mobile: \(mobile),
                  platform: '\(platform)',
                  platformVersion: '\(platformVersion)',
                  architecture: 'x86',
                  bitness: '64',
                  model: '',
                  uaFullVersion: '\(chromiumMajor).0.0.0',
                  fullVersionList: brands
                });
              };
              data.toJSON = function () {
                return { brands: brands, mobile: \(mobile), platform: '\(platform)' };
              };
              Object.defineProperty(Navigator.prototype, 'userAgentData', {
                get: function () { return data; },
                configurable: true
              });
            }
          } catch (error) {}
        """ : ""

        let windowChromeBlock = claimsChromiumData ? """
          try { if (!window.chrome) { window.chrome = { runtime: {} }; } } catch (error) {}
        """ : ""

        let platformBlock = (claimsChromiumData || claimsFirefox) ? """
          try {
            Object.defineProperty(Navigator.prototype, 'platform', {
              get: function () { return \(platformLiteral); },
              configurable: true
            });
          } catch (error) {}
          try {
            Object.defineProperty(Navigator.prototype, 'maxTouchPoints', {
              get: function () { return \(claimedTouchPoints); },
              configurable: true
            });
          } catch (error) {}
        """ : ""

        return """
        (function () {
          if (window.__velaIdentityConsistency === true) { return; }
          window.__velaIdentityConsistency = true;
        \(vendorBlock)
        \(userAgentDataBlock)
        \(windowChromeBlock)
        \(platformBlock)
        })();
        """
    }

    /// A JSON string literal for embedding a Swift string in injected
    /// JavaScript.
    private static func jsonString(_ value: String) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: [value]),
              let array = String(data: data, encoding: .utf8), array.count >= 2 else {
            return "\"\""
        }
        return String(array.dropFirst().dropLast())
    }

    // MARK: - Viewport and safe area

    /// Reports viewport metrics and applies the bottom safe-area inset.
    ///
    /// `BrowserWebViewportCoordinator`. The inset is applied to the document
    /// element rather than by shrinking the web view, because shrinking the web
    /// view would make fixed-position page chrome sit above the toolbar, which
    /// looks like a rendering bug to the user.
    public static func safeAreaScript(bottomInset: Double, toolbarClearance: Double, topInset: Double) -> String {
        """
        (function () {
          var root = document.documentElement;
          if (!root) { return; }
          var styleId = '__vela_safe_area_style';
          var style = document.getElementById(styleId);
          if (!style) {
            style = document.createElement('style');
            style.id = styleId;
            (document.head || root).appendChild(style);
          }
          // A page that declares a viewport-fit of cover draws under the
          // toolbar; one that does not needs the padding to be visible at all.
          style.textContent =
            ':root { --vela-safe-area-bottom: \(Int(bottomInset))px; --vela-safe-area-top: \(Int(topInset))px; }' +
            'body { padding-bottom: \(Int(bottomInset + toolbarClearance))px !important; }';
          try {
            root.style.setProperty('--vela-safe-area-bottom', '\(Int(bottomInset))px');
            root.style.setProperty('--vela-safe-area-top', '\(Int(topInset))px');
          } catch (_error) {
          }
        })();
        """
    }

    // MARK: - Scroll

    /// Reports scroll offset and direction.
    public static let scrollReporter = """
    (function () {
      if (window.__velaScrollReporterInstalled === true) { return; }
      window.__velaScrollReporterInstalled = true;

      var lastY = window.scrollY || 0;
      var lastEmitAt = 0;
      var ticking = false;

      function emit() {
        ticking = false;
        try {
          var y = window.scrollY || 0;
          var delta = y - lastY;
          // A distance threshold plus a time gate keeps the script bridge quiet
          // during a fling: the chrome only needs to know which side of its
          // threshold the accumulated movement is on, not every frame.
          if (Math.abs(delta) < 8) { return; }
          var now = Date.now();
          // Reaching the top is always reported: a thinned-out final frame
          // must not leave the bar hidden on a page the user has returned to
          // the start of.
          if (y > 0 && now - lastEmitAt < 70) { return; }
          lastEmitAt = now;
          if (window.webkit && window.webkit.messageHandlers &&
              window.webkit.messageHandlers.\(Handler.scroll.rawValue)) {
            window.webkit.messageHandlers.\(Handler.scroll.rawValue).postMessage({
              offsetY: y,
              deltaY: delta,
              direction: delta > 0 ? 'down' : 'up',
              atTop: y <= 0
            });
          }
          lastY = y;
        } catch (_error) {
        }
      }

      window.addEventListener('scroll', function () {
        if (ticking) { return; }
        ticking = true;
        window.requestAnimationFrame(emit);
      }, { passive: true });
    })();
    """

    /// Puts a restored tab back where the user left it.
    ///
    /// Called once after a discarded tab's page has finished loading. Two
    /// animation frames after the call let layout settle first — scrolling a
    /// document whose height is still being computed is silently clamped to
    /// the height it had at that instant.
    public static func scrollRestoreScript(offsetY: Double) -> String {
        let target = max(0, Int(offsetY.rounded()))
        return """
        (function () {
          try {
            var target = \(target);
            function apply() {
              try { window.scrollTo(0, target); } catch (_error) {}
            }
            apply();
            if (window.requestAnimationFrame) {
              window.requestAnimationFrame(function () {
                apply();
                window.requestAnimationFrame(apply);
              });
            }
            // Late images and lazy content can grow the document after the
            // first frames; one more pass keeps a restored position from
            // being clamped to a height the page had only for a moment.
            window.setTimeout(apply, 320);
          } catch (_error) {
          }
        })();
        """
    }

    // MARK: - Find in page

    /// The in-page find script.
    ///
    /// It highlights with the CSS Custom Highlight API — ranges, not elements —
    /// so a search never rewrites the page's DOM. The earlier version wrapped
    /// every match in a `mark` element and unwrapped it again on the next
    /// keystroke; on a framework-rendered page that mutates text nodes React or
    /// Vue still hold references to, and the page can stop updating after a
    /// search. Highlights leave the document untouched.
    ///
    /// The match list and the current index live on the page, so "next" cannot
    /// race a report message that has not arrived yet. `reset` means the query
    /// changed: start at its first match. WebKit without the highlight API
    /// falls back to wrapping marks, and rebuilds the list on every step
    /// because wrapping invalidates the ranges.
    public static func findInPageScript(query: String, forward: Bool, reset: Bool) -> String {
        let encoded = (try? JSONSerialization.data(withJSONObject: [query]))
            .flatMap { String(data: $0, encoding: .utf8) }
            .map { String($0.dropFirst().dropLast()) } ?? "\"\""
        let forwardLiteral = forward ? "true" : "false"
        let resetLiteral = reset ? "true" : "false"

        return """
        (function () {
          var HANDLER = '\(Handler.pageMetrics.rawValue)';
          var STYLE_ID = '__vela_find_style';
          var ALL = 'vela-find';
          var ACTIVE = 'vela-find-active';

          function report(count, index) {
            if (window.webkit && window.webkit.messageHandlers &&
                window.webkit.messageHandlers[HANDLER]) {
              window.webkit.messageHandlers[HANDLER].postMessage({
                findResult: { count: count, index: index }
              });
            }
          }

          function hasHighlightAPI() {
            return !!(window.CSS && CSS.highlights && window.Highlight &&
                      window.Highlight.prototype && window.Highlight.prototype.add);
          }

          function ensureStyle(supported) {
            if (document.getElementById(STYLE_ID)) { return; }
            var style = document.createElement('style');
            style.id = STYLE_ID;
            style.textContent = supported
              ? '::highlight(vela-find){background-color:#ffd54f;color:#000;}' +
                '::highlight(vela-find-active){background-color:#ff9800;color:#000;}'
              : 'mark.__vela_find_all{background-color:#ffd54f;color:#000;}' +
                'mark.__vela_find_active{background-color:#ff9800;color:#000;}';
            (document.head || document.documentElement).appendChild(style);
          }

          function clearAll() {
            if (window.CSS && CSS.highlights) {
              CSS.highlights.delete(ALL);
              CSS.highlights.delete(ACTIVE);
            }
            var marks = document.querySelectorAll('mark.__vela_find_all, mark.__vela_find_active');
            for (var i = marks.length - 1; i >= 0; i--) {
              var mark = marks[i];
              var parent = mark.parentNode;
              if (!parent) { continue; }
              parent.replaceChild(document.createTextNode(mark.textContent), mark);
              parent.normalize();
            }
          }

          function collect(query) {
            var ranges = [];
            var lower = query.toLowerCase();
            if (!lower) { return ranges; }
            var walker = document.createTreeWalker(
              document.body || document.documentElement,
              NodeFilter.SHOW_TEXT,
              {
                acceptNode: function (node) {
                  if (!node.nodeValue) { return NodeFilter.FILTER_REJECT; }
                  var parent = node.parentNode;
                  var name = parent ? parent.nodeName : '';
                  if (name === 'SCRIPT' || name === 'STYLE' || name === 'NOSCRIPT' ||
                      name === 'TEXTAREA' || name === 'INPUT' || name === 'SELECT') {
                    return NodeFilter.FILTER_REJECT;
                  }
                  if (parent && parent.isContentEditable) {
                    return NodeFilter.FILTER_REJECT;
                  }
                  if (node.nodeValue.toLowerCase().indexOf(lower) < 0) {
                    return NodeFilter.FILTER_REJECT;
                  }
                  return NodeFilter.FILTER_ACCEPT;
                }
              }
            );
            var node;
            while ((node = walker.nextNode())) {
              var text = node.nodeValue;
              var haystack = text.toLowerCase();
              var at = haystack.indexOf(lower);
              while (at >= 0) {
                var range = document.createRange();
                range.setStart(node, at);
                range.setEnd(node, at + query.length);
                ranges.push(range);
                at = haystack.indexOf(lower, at + query.length);
              }
            }
            return ranges;
          }

          function wrapMarks(ranges, activeIndex) {
            var byNode = [];
            for (var i = 0; i < ranges.length; i++) {
              var node = ranges[i].startContainer;
              var group = null;
              for (var g = 0; g < byNode.length; g++) {
                if (byNode[g].node === node) { group = byNode[g]; break; }
              }
              if (!group) {
                group = { node: node, hits: [] };
                byNode.push(group);
              }
              group.hits.push({
                start: ranges[i].startOffset,
                end: ranges[i].endOffset,
                index: i
              });
            }
            for (var b = 0; b < byNode.length; b++) {
              var entry = byNode[b];
              var text = entry.node.nodeValue;
              if (!text || !entry.node.parentNode) { continue; }
              entry.hits.sort(function (a, b2) { return a.start - b2.start; });
              var fragment = document.createDocumentFragment();
              var cursor = 0;
              for (var h = 0; h < entry.hits.length; h++) {
                var hit = entry.hits[h];
                if (hit.start < cursor) { continue; }
                if (hit.start > cursor) {
                  fragment.appendChild(document.createTextNode(text.slice(cursor, hit.start)));
                }
                var mark = document.createElement('mark');
                mark.className = hit.index === activeIndex
                  ? '__vela_find_active'
                  : '__vela_find_all';
                mark.textContent = text.slice(hit.start, hit.end);
                fragment.appendChild(mark);
                cursor = hit.end;
              }
              if (cursor < text.length) {
                fragment.appendChild(document.createTextNode(text.slice(cursor)));
              }
              entry.node.parentNode.replaceChild(fragment, entry.node);
            }
          }

          var query = \(encoded);
          var forward = \(forwardLiteral);
          var reset = \(resetLiteral);
          var supported = hasHighlightAPI();
          var state = window.__velaFindState ||
            (window.__velaFindState = { query: '', ranges: [], index: -1 });

          if (!query) {
            clearAll();
            state.query = '';
            state.ranges = [];
            state.index = -1;
            report(0, -1);
            return;
          }

          ensureStyle(supported);

          var sameQuery = state.query === query && state.ranges.length > 0;
          // The wrapping fallback invalidates the ranges it uses, so it is
          // rebuilt on every step; the native path keeps them between steps.
          var rebuild = reset || !supported || !sameQuery;

          if (rebuild) {
            clearAll();
            state.ranges = collect(query);
            state.query = query;
            if (!sameQuery) { state.index = -1; }
          }

          var count = state.ranges.length;
          var index = -1;
          if (count > 0) {
            if (state.index < 0) {
              index = forward ? 0 : count - 1;
            } else {
              index = ((state.index + (forward ? 1 : -1)) % count + count) % count;
            }
          }
          state.index = index;

          if (supported) {
            var all = new Highlight();
            for (var i = 0; i < count; i++) {
              if (i !== index) { all.add(state.ranges[i]); }
            }
            CSS.highlights.set(ALL, all);
            if (index >= 0 && index < count) {
              var active = new Highlight();
              active.add(state.ranges[index]);
              CSS.highlights.set(ACTIVE, active);
            } else {
              CSS.highlights.delete(ACTIVE);
            }
          } else if (count > 0) {
            clearAll();
            wrapMarks(state.ranges, index);
          }

          if (index >= 0 && index < count) {
            var range = state.ranges[index];
            var node = range.startContainer;
            var element = node.nodeType === 1 ? node : node.parentElement;
            if (element && element.scrollIntoView) {
              element.scrollIntoView({ block: 'center', behavior: 'smooth' });
            }
          }

          report(count, index);
        })();
        """
    }

    /// Removes the find highlights and forgets the match list.
    ///
    /// Both highlight paths are cleared: the registry entries of the native
    /// API, and — for WebKit without it — the marks the fallback wrapped.
    public static let clearFindInPageScript = """
    (function () {
      if (window.CSS && CSS.highlights) {
        CSS.highlights.delete('vela-find');
        CSS.highlights.delete('vela-find-active');
      }
      var marks = document.querySelectorAll('mark.__vela_find_all, mark.__vela_find_active');
      for (var i = marks.length - 1; i >= 0; i--) {
        var mark = marks[i];
        var parent = mark.parentNode;
        if (!parent) { continue; }
        parent.replaceChild(document.createTextNode(mark.textContent), mark);
        parent.normalize();
      }
      var state = window.__velaFindState;
      if (state) {
        state.query = '';
        state.ranges = [];
        state.index = -1;
      }
    })();
    """

}
