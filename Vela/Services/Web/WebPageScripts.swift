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
          video.__velaSuppressedCaptionTracks.push(track);
          try { track.mode = 'disabled'; } catch (error) {}
        }
      }

      function restoreOtherCaptionTracks(video) {
        var tracks = video.__velaSuppressedCaptionTracks;
        if (!tracks) { return; }
        video.__velaSuppressedCaptionTracks = null;
        for (var i = 0; i < tracks.length; i++) {
          try { tracks[i].mode = 'hidden'; } catch (error) {}
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
          // sentence.
          if (painted) { hideOtherCaptionTracks(video, track); }
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

        return """
        (function () {
          if (window.__velaIdentityConsistency === true) { return; }
          window.__velaIdentityConsistency = true;
        \(vendorBlock)
        \(userAgentDataBlock)
        \(windowChromeBlock)
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

    // MARK: - Inline video controls

    /// Tap-to-controls for a video in the page.
    ///
    /// A player that pauses on tap is the wrong shape for a phone browser:
    /// the tap the user means as "where am I in this film" stops the film.
    /// What a tap should produce is the system's inline controls — the
    /// progress bar, the time, the play/pause button and the fullscreen
    /// button — with pausing left to the pause button itself. So a
    /// capture-phase listener runs before any page handler, arms the system
    /// controls when the player ships none, and keeps the tap from reaching
    /// the page's pause path. Taps on a player's own visible buttons are
    /// untouched — they land on the button element, not the video — and so
    /// is a page playing through an overlay of its own chrome; only a tap on
    /// the bare video element is taken over. The element picker stands down
    /// for the same reason it injects late: it needs the page's click stream
    /// alive to choose what to hide.
    public static let inlineVideoControlsScript = """
    (function () {
      if (window.__velaInlineVideoControlsInstalled === true) { return; }
      window.__velaInlineVideoControlsInstalled = true;

      function isManagedPlayerSite(host) {
        // Sites whose player owns its tap layer end to end and behaves badly
        // when a stranger arms the system controls underneath it. YouTube is
        // the one that matters: its watch page binds its own handlers, and a
        // hijacked tap desynchronises its player state machine.
        return /(^|\\.)youtube\\.com$/.test(host) ||
               /(^|\\.)youtube-nocookie\\.com$/.test(host) ||
               /(^|\\.)youtubekids\\.com$/.test(host) ||
               host === 'youtu.be';
      }

      document.addEventListener('click', function (event) {
        var node = event.target;
        if (!node || node.nodeType !== 1 || node.tagName !== 'VIDEO') { return; }
        if (window.__velaElementPickerInstalled === true) { return; }
        var host = String(window.location && window.location.hostname || '').toLowerCase();
        if (isManagedPlayerSite(host)) { return; }
        if (!node.hasAttribute('controls')) { node.setAttribute('controls', ''); }
        event.stopImmediatePropagation();
      }, true);
    })();
    """

    // MARK: - Video quality

    /// Puts a floor under YouTube's automatic quality.
    ///
    /// The player on this device is handed a phone identifier — deliberately,
    /// because the iPad identifier lands YouTube's desktop site and its bot
    /// wall — and the phone-shaped player opens at the lowest rendition the
    /// connection allows and can stay there. The player's own range control
    /// (`setPlaybackQualityRange`, the undocumented method on the movie
    /// player) keeps the choice automatic while raising the floor to 720p, so
    /// a good connection still climbs to the best available rendition and a
    /// weak one cannot drop below HD. It is applied a few times per source
    /// while the player settles, never continuously, so a quality the user
    /// picks by hand is left alone afterwards.
    public static let youtubeQualityScript = """
    (function () {
      if (window.__velaYouTubeQualityInstalled === true) { return; }
      window.__velaYouTubeQualityInstalled = true;

      var floor = 'hd720';
      var ceiling = 'highres';
      var sourceKey = null;
      var attempts = 0;
      var lastAttemptAt = 0;

      // Seed the player's own stored quality preference when the site has not
      // recorded one. The range call below handles the current source; this is
      // what makes the next video open at HD too, and it is written only when
      // nothing is stored, so a quality the user picks by hand stays picked.
      try {
        var stored = null;
        try { stored = JSON.parse(localStorage.getItem('yt-player-quality') || 'null'); } catch (error) {}
        if (!stored || !stored.data) {
          localStorage.setItem('yt-player-quality', JSON.stringify({
            data: floor,
            creation: Date.now(),
            expiration: Date.now() + 31536000000
          }));
        }
      } catch (error) {}

      function currentPlayer() {
        var candidates = [
          document.getElementById('movie_player'),
          document.querySelector('.html5-video-player')
        ];
        for (var i = 0; i < candidates.length; i++) {
          var player = candidates[i];
          if (!player) { continue; }
          if (typeof player.setPlaybackQualityRange === 'function') { return player; }
          if (typeof player.setPlaybackQuality === 'function') { return player; }
        }
        return null;
      }

      function tick() {
        var player = currentPlayer();
        if (!player) { return; }
        var video = player.querySelector('video');
        if (!video) { return; }
        var key = video.currentSrc || video.src || '';
        if (!key) { return; }
        if (key !== sourceKey) {
          sourceKey = key;
          attempts = 0;
          lastAttemptAt = 0;
        }
        if (attempts >= 5) { return; }
        var now = Date.now();
        if (now - lastAttemptAt < 1200) { return; }
        attempts += 1;
        lastAttemptAt = now;
        try {
          if (typeof player.setPlaybackQualityRange === 'function') {
            player.setPlaybackQualityRange(floor, ceiling);
          } else if (typeof player.setPlaybackQuality === 'function') {
            player.setPlaybackQuality(floor);
          }
        } catch (error) {}
      }

      setInterval(tick, 700);

      // A new watch page reuses the player element but a different source; the
      // source key already notices that, and the navigation event only makes
      // the first attempt immediate.
      document.addEventListener('yt-navigate-finish', function () {
        sourceKey = null;
        attempts = 0;
        lastAttemptAt = 0;
        tick();
      }, true);
    })();
    """

    // MARK: - Inline video tap

    /// Taps the picture to show the controls rather than to pause.
    ///
    /// YouTube's player reads a tap on the picture as play/pause. On a phone
    /// or a tablet that tap means "show me the controls" — the progress bar,
    /// the play button, the fullscreen button — and a second tap means "put
    /// them away"; stopping the film belongs to the play button alone.
    ///
    /// Switching the events off is not enough by itself: the player answers
    /// the tap from whichever handler it bound — pointerdown, touchend, click,
    /// or a private command — and a click-only guard left that pause path
    /// alive. So the media element itself stands down for the length of a
    /// picture tap: `play()` and `pause()` calls on the tapped video are
    /// dropped inside the gesture's window, whatever called them, and the tap
    /// only toggles the control layer through the player's own
    /// `ytp-autohide` state. A tap that begins on a control clears the guard,
    /// so the play button — and every other button, the seek bar, the menus
    /// and the end screen — keeps its own job, and a drag cancels the guard
    /// before a scroll can be mistaken for a tap.
    public static let youtubeTapControlsScript = """
    (function () {
      if (window.__velaYouTubeTapControlsInstalled === true) { return; }
      window.__velaYouTubeTapControlsInstalled = true;

      // Elements that own the tap they receive: the play button, the seek
      // bar, the settings menu, the end screen, and the player's links.
      var ownedTapSelector = [
        '.ytp-button',
        '.ytp-chrome-controls',
        '.ytp-progress-bar-container',
        '.ytp-pause-overlay',
        '.ytp-endscreen-content',
        '.ytp-ce-element',
        '.ytp-cards-teaser',
        '.ytp-paid-content-overlay',
        '.ytp-ad-overlay-container',
        '.ytp-popup',
        '.ytp-settings-menu',
        '.ytp-contextmenu',
        'button',
        '[role="button"]',
        'a[href]',
        'input',
        'textarea',
        'select'
      ].join(',');

      var startX = 0;
      var startY = 0;
      var startAt = 0;
      var startPlayer = null;
      var startHidden = false;
      var tapVideo = null;
      var tapWasPlaying = false;
      var guardUntil = 0;
      var tracking = false;
      var handledAt = 0;

      function playerForPicture(node) {
        if (!node || node.nodeType !== 1) { return null; }
        var player = node.closest ? node.closest('.html5-video-player') : null;
        if (!player) { return null; }
        if (node.closest(ownedTapSelector)) { return null; }
        return player;
      }

      function setControls(player, visible) {
        if (visible) {
          player.classList.remove('ytp-autohide');
          player.classList.remove('ytp-hide-controls');
        } else {
          player.classList.add('ytp-autohide');
        }
      }

      // The player answers a picture tap by calling play() or pause() from
      // whichever handler it bound. Blocking the event alone left that path
      // alive, so the media element stands down for the length of a picture
      // tap: a play/pause call inside the window is dropped. A tap that starts
      // on a control clears the guard, so every control keeps its own job.
      var nativePlay = HTMLMediaElement.prototype.play;
      var nativePause = HTMLMediaElement.prototype.pause;

      function mediaIsGuarded(video) {
        return video && video === tapVideo && Date.now() < guardUntil;
      }

      HTMLMediaElement.prototype.play = function () {
        if (mediaIsGuarded(this)) { return Promise.resolve(); }
        return nativePlay.apply(this, arguments);
      };

      HTMLMediaElement.prototype.pause = function () {
        if (mediaIsGuarded(this)) { return; }
        return nativePause.apply(this, arguments);
      };

      // Claims one tap. The same tap reaches several events; only the first
      // one acts and the rest are swallowed, so the controls move once.
      //
      // The direction comes from the state read at the START of the gesture,
      // not from the state reached now: a player may reveal its controls on
      // touchstart, and reading the class at touchend would then see them
      // already visible and hide the very layer the tap was asking for.
      function claimTap(event) {
        var player = playerForPicture(event.target);
        if (!player) { return false; }
        event.preventDefault();
        event.stopImmediatePropagation();
        var now = Date.now();
        if (now - handledAt > 350) {
          handledAt = now;
          var show = startPlayer === player
            ? startHidden
            : player.classList.contains('ytp-autohide');
          try { setControls(player, show); } catch (error) {}
          guardUntil = Math.max(guardUntil, now + 400);
        }
        return true;
      }

      function recordStart(node, x, y) {
        startX = x;
        startY = y;
        startAt = Date.now();
        startPlayer = playerForPicture(node);
        startHidden = startPlayer ? startPlayer.classList.contains('ytp-autohide') : false;
        tapVideo = startPlayer ? startPlayer.querySelector('video') : null;
        tapWasPlaying = tapVideo ? !tapVideo.paused : false;
        guardUntil = tapVideo ? Date.now() + 900 : 0;
        tracking = true;
      }

      function cancelTap() {
        tracking = false;
        guardUntil = 0;
        tapVideo = null;
      }

      function isStillTap(x, y) {
        if (!tracking) { return false; }
        if (Date.now() - startAt > 700) { return false; }
        return Math.abs(x - startX) <= 12 && Math.abs(y - startY) <= 12;
      }

      window.addEventListener('pointerdown', function (event) {
        recordStart(event.target, event.clientX, event.clientY);
      }, true);

      window.addEventListener('touchstart', function (event) {
        var touch = event.touches && event.touches[0];
        if (touch) { recordStart(event.target, touch.clientX, touch.clientY); }
      }, true);

      window.addEventListener('pointermove', function (event) {
        if (!tracking) { return; }
        if (Math.abs(event.clientX - startX) > 12 || Math.abs(event.clientY - startY) > 12) {
          cancelTap();
        }
      }, true);

      window.addEventListener('touchmove', function (event) {
        var touch = event.touches && event.touches[0];
        if (!tracking || !touch) { return; }
        if (Math.abs(touch.clientX - startX) > 12 || Math.abs(touch.clientY - startY) > 12) {
          cancelTap();
        }
      }, true);

      window.addEventListener('pointerup', function (event) {
        var repeat = Date.now() - handledAt < 350;
        if (isStillTap(event.clientX, event.clientY) || repeat) { claimTap(event); }
        tracking = false;
      }, true);

      window.addEventListener('touchend', function (event) {
        var touch = event.changedTouches && event.changedTouches[0];
        var repeat = Date.now() - handledAt < 350;
        if (touch && (isStillTap(touch.clientX, touch.clientY) || repeat)) { claimTap(event); }
        tracking = false;
      }, true);

      window.addEventListener('touchcancel', function () {
        cancelTap();
      }, true);

      // Anything that bypasses the prototype (a native command, a private
      // player path) is put back here, using the unguarded originals.
      document.addEventListener('pause', function (event) {
        if (event.target !== tapVideo || Date.now() > guardUntil) { return; }
        if (!tapWasPlaying) { return; }
        try { nativePlay.call(tapVideo); } catch (error) {}
      }, true);

      document.addEventListener('play', function (event) {
        if (event.target !== tapVideo || Date.now() > guardUntil) { return; }
        if (tapWasPlaying) { return; }
        try { nativePause.call(tapVideo); } catch (error) {}
      }, true);

      // A mouse click, a keyboard activation, or a path that delivered only a
      // click still gets the same treatment.
      window.addEventListener('click', function (event) {
        claimTap(event);
      }, true);
    })();
    """

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

    /// Reports layout metrics back to the host so the toolbar clearance can be
    /// recomputed after a rotation or a dynamic-toolbar change.
    public static let pageMetricsReporter = """
    (function () {
      if (window.__velaPageMetricsInstalled === true) { return; }
      window.__velaPageMetricsInstalled = true;

      function report() {
        try {
          if (!(window.webkit && window.webkit.messageHandlers &&
                window.webkit.messageHandlers.\(Handler.pageMetrics.rawValue))) { return; }
          var root = document.documentElement;
          var body = document.body;
          window.webkit.messageHandlers.\(Handler.pageMetrics.rawValue).postMessage({
            // Whether the page actually scrolls decides whether the toolbar can
            // auto-hide. A page shorter than the viewport must keep it visible,
            // or the controls disappear with no way to bring them back.
            scrollHeight: Math.max(root ? root.scrollHeight : 0, body ? body.scrollHeight : 0),
            viewportHeight: window.innerHeight,
            viewportWidth: window.innerWidth,
            hasViewportFitCover: (function () {
              var meta = document.querySelector('meta[name="viewport"]');
              return !!meta && String(meta.getAttribute('content') || '').indexOf('viewport-fit=cover') >= 0;
            })(),
            colorScheme: (function () {
              var meta = document.querySelector('meta[name="color-scheme"]');
              if (meta) { return String(meta.getAttribute('content') || ''); }
              var computed = window.getComputedStyle(root);
              return String(computed.backgroundColor || '');
            })()
          });
        } catch (_error) {
        }
      }

      report();
      window.addEventListener('resize', function () { setTimeout(report, 120); }, false);
      document.addEventListener('DOMContentLoaded', function () { setTimeout(report, 60); }, false);
    })();
    """

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

    // MARK: - Dark mode

    /// Tells the page whether it should render dark, and reads back whether it
    /// has a dark stylesheet.
    public static func colorSchemeScript(prefersDark: Bool) -> String {
        """
        (function () {
          try {
            var meta = document.querySelector('meta[name="color-scheme"]');
            if (!meta) {
              meta = document.createElement('meta');
              meta.setAttribute('name', 'color-scheme');
              (document.head || document.documentElement).appendChild(meta);
            }
            meta.setAttribute('content', '\(prefersDark ? "dark light" : "light dark")');
            document.documentElement.style.colorScheme = '\(prefersDark ? "dark" : "light")';
          } catch (_error) {
          }
        })();
        """
    }

    // MARK: - Find in page

    /// Highlights every match of `query` and reports the count.
    ///
    /// Implemented with a DOM walk
    /// rather than `window.find()` because `window.find` is not exposed in
    /// WebKit's JavaScript context and selecting text does not survive a scroll
    /// on a long page.
    public static func findInPageScript(query: String, forward: Bool, focusIndex: Int) -> String {
        let encoded = (try? JSONSerialization.data(withJSONObject: [query]))
            .flatMap { String(data: $0, encoding: .utf8) }
            .map { String($0.dropFirst().dropLast()) } ?? "\"\""

        return """
        (function () {
          var HIGHLIGHT_ID = '__vela_find_highlight';
          var ACTIVE_CLASS = '__vela_find_active';

          function clearHighlights() {
            var existing = document.querySelectorAll('.' + ACTIVE_CLASS);
            for (var i = 0; i < existing.length; i++) {
              var parent = existing[i].parentNode;
              if (!parent) { continue; }
              parent.replaceChild(document.createTextNode(existing[i].textContent), existing[i]);
              parent.normalize();
            }
            var style = document.getElementById(HIGHLIGHT_ID);
            if (style) { style.remove(); }
          }

          clearHighlights();

          var query = \(encoded);
          if (!query) {
            if (window.webkit && window.webkit.messageHandlers &&
                window.webkit.messageHandlers.\(Handler.pageMetrics.rawValue)) {
              window.webkit.messageHandlers.\(Handler.pageMetrics.rawValue).postMessage({ findResult: { count: 0, index: -1 } });
            }
            return;
          }

          var lowerQuery = query.toLowerCase();
          var matches = [];
          // A TreeWalker is the only way to visit text nodes without collecting
          // every element in the document into an array first.
          var walker = document.createTreeWalker(
            document.body || document.documentElement,
            NodeFilter.SHOW_TEXT,
            {
              acceptNode: function (node) {
                if (!node.nodeValue || node.nodeValue.toLowerCase().indexOf(lowerQuery) < 0) {
                  return NodeFilter.FILTER_REJECT;
                }
                var tag = node.parentNode ? node.parentNode.nodeName : '';
                if (tag === 'SCRIPT' || tag === 'STYLE' || tag === 'NOSCRIPT') {
                  return NodeFilter.FILTER_REJECT;
                }
                return NodeFilter.FILTER_ACCEPT;
              }
            }
          );

          var current;
          while ((current = walker.nextNode())) {
            var text = current.nodeValue;
            var lowerText = text.toLowerCase();
            var position = lowerText.indexOf(lowerQuery);
            var fragment = document.createDocumentFragment();
            var cursor = 0;
            while (position >= 0) {
              if (position > cursor) {
                fragment.appendChild(document.createTextNode(text.slice(cursor, position)));
              }
              var mark = document.createElement('mark');
              mark.className = ACTIVE_CLASS;
              mark.style.backgroundColor = '#ffd54f';
              mark.style.color = '#000';
              mark.textContent = text.slice(position, position + query.length);
              fragment.appendChild(mark);
              matches.push(mark);
              cursor = position + query.length;
              position = lowerText.indexOf(lowerQuery, cursor);
            }
            if (cursor < text.length) {
              fragment.appendChild(document.createTextNode(text.slice(cursor)));
            }
            current.parentNode.replaceChild(fragment, current);
          }

          var index = matches.length === 0 ? -1 : ((\(focusIndex) % matches.length) + matches.length) % matches.length;
          if (index >= 0) {
            matches[index].style.backgroundColor = '#ff9800';
            matches[index].scrollIntoView({ block: 'center', behavior: 'smooth' });
          }

          if (window.webkit && window.webkit.messageHandlers &&
              window.webkit.messageHandlers.\(Handler.pageMetrics.rawValue)) {
            window.webkit.messageHandlers.\(Handler.pageMetrics.rawValue).postMessage({
              findResult: { count: matches.length, index: index }
            });
          }
        })();
        """
    }

    public static let clearFindInPageScript = """
    (function () {
      var marks = document.querySelectorAll('.__vela_find_active');
      for (var i = marks.length - 1; i >= 0; i--) {
        var mark = marks[i];
        var parent = mark.parentNode;
        if (!parent) { continue; }
        parent.replaceChild(document.createTextNode(mark.textContent), mark);
        parent.normalize();
      }
    })();
    """

    // MARK: - Element picker

    /// The element picker.
    ///
    /// The generated selector prefers a stable id, then a class combination,
    /// then a structural path. An auto-generated class such as `css-1x2y3z`
    /// changes on every deploy, so a rule built on one stops working; the
    /// structural path is ugly but is the only thing that survives.
    public static let elementPickerScript = """
    (function () {
      if (window.__velaElementPickerInstalled === true) { return; }
      window.__velaElementPickerInstalled = true;

      var highlighted = null;
      var previousOutline = '';

      function isGeneratedClass(name) {
        return /^(css|sc|jsx|styled)-?[0-9a-z]{4,}$/i.test(name) ||
               /^[a-z]+-[0-9a-f]{6,}$/i.test(name) ||
               /^_[0-9a-z]{5,}$/i.test(name);
      }

      function stableClasses(element) {
        var list = [];
        var classes = String(element.className || '').split(/\\s+/);
        for (var i = 0; i < classes.length; i++) {
          var name = classes[i].trim();
          if (!name || isGeneratedClass(name)) { continue; }
          list.push(name);
        }
        return list;
      }

      function selectorFor(element) {
        if (!element || element.nodeType !== 1) { return ''; }

        // 1. A stable id wins outright: ids are unique by definition and a
        //    hand-written one rarely changes.
        var id = element.getAttribute('id');
        if (id && !isGeneratedClass(id) && !/^\\d/.test(id)) {
          return '#' + (window.CSS && CSS.escape ? CSS.escape(id) : id);
        }

        var classes = stableClasses(element);
        if (classes.length > 0) {
          var escaped = classes.map(function (name) {
            return '.' + (window.CSS && CSS.escape ? CSS.escape(name) : name);
          }).join('');
          // Only use the class path when it is unique, otherwise the rule would
          // hide unrelated elements the user did not point at.
          try {
            if (document.querySelectorAll(escaped).length === 1) { return escaped; }
          } catch (_error) {
          }
          return element.tagName.toLowerCase() + escaped;
        }

        // 2. Structural path.
        var parts = [];
        var node = element;
        var depth = 0;
        while (node && node.nodeType === 1 && depth < 6) {
          var tag = node.tagName.toLowerCase();
          var parent = node.parentNode;
          if (parent) {
            var siblings = [];
            var children = parent.children || [];
            for (var i = 0; i < children.length; i++) {
              if (children[i].tagName === node.tagName) { siblings.push(children[i]); }
            }
            if (siblings.length > 1) {
              tag += ':nth-of-type(' + (siblings.indexOf(node) + 1) + ')';
            }
          }
          parts.unshift(tag);
          node = parent;
          depth++;
        }
        return parts.join(' > ');
      }

      function onMove(event) {
        var target = event.target;
        if (!target || target === document.documentElement || target === document.body) { return; }
        if (highlighted === target) { return; }
        if (highlighted) {
          highlighted.style.outline = previousOutline;
        }
        highlighted = target;
        previousOutline = target.style.outline;
        target.style.outline = '2px solid #ff5722';
      }

      function onClick(event) {
        event.preventDefault();
        event.stopPropagation();
        var selector = selectorFor(event.target);
        if (highlighted) { highlighted.style.outline = previousOutline; }
        try {
          if (window.webkit && window.webkit.messageHandlers &&
              window.webkit.messageHandlers.\(Handler.elementPick.rawValue)) {
            window.webkit.messageHandlers.\(Handler.elementPick.rawValue).postMessage({
              selector: selector,
              elementCount: selector ? document.querySelectorAll(selector).length : 0
            });
          }
        } catch (_error) {
        }
        // A pick is one-shot. Leaving the listeners installed would keep
        // swallowing the page's clicks while the confirmation is answered.
        if (window.__velaElementPickerStop) { window.__velaElementPickerStop(); }
      }

      window.__velaElementPickerStop = function () {
        document.removeEventListener('mousemove', onMove, true);
        document.removeEventListener('click', onClick, true);
        if (highlighted) { highlighted.style.outline = previousOutline; }
        highlighted = null;
        // Re-armable in the same document: without clearing this the next
        // arm's installed-guard would return before adding the listeners.
        window.__velaElementPickerInstalled = false;
      };

      document.addEventListener('mousemove', onMove, true);
      document.addEventListener('click', onClick, true);
    })();
    """

    public static let stopElementPickerScript = """
    (function () {
      if (typeof window.__velaElementPickerStop === 'function') {
        window.__velaElementPickerStop();
      }
    })();
    """

    // MARK: - Page text extraction

    /// Extracts the page text for translation.
    public static let textExtractionScript = """
    (function () {
      var SKIP_TAGS = { SCRIPT: 1, STYLE: 1, NOSCRIPT: 1, CODE: 1, PRE: 1, TEXTAREA: 1, SVG: 1, CANVAS: 1 };
      var segments = [];
      var walker = document.createTreeWalker(
        document.body || document.documentElement,
        NodeFilter.SHOW_TEXT,
        {
          acceptNode: function (node) {
            if (SKIP_TAGS[node.parentNode ? node.parentNode.nodeName : '']) {
              return NodeFilter.FILTER_REJECT;
            }
            var text = (node.nodeValue || '').trim();
            // Skip whitespace-only and single-character nodes: they are almost
            // always layout artefacts and translating them wastes a request.
            if (text.length < 2) { return NodeFilter.FILTER_REJECT; }
            if (!/[a-zA-Z\\u4e00-\\u9fa5]/.test(text)) { return NodeFilter.FILTER_REJECT; }
            return NodeFilter.FILTER_ACCEPT;
          }
        }
      );

      var index = 0;
      var node;
      while ((node = walker.nextNode())) {
        node.__velaTranslationIndex = index;
        segments.push({
          index: index,
          text: (node.nodeValue || '').trim(),
          tag: node.parentNode ? node.parentNode.nodeName.toLowerCase() : ''
        });
        index++;
        // A page with tens of thousands of nodes would produce a request body
        // no translation service accepts, and a latency the user would not
        // tolerate.
        if (index >= 800) { break; }
      }

      return JSON.stringify({ segments: segments, url: String(window.location.href || ''), title: document.title });
    })();
    """

    /// Writes translated text back into the nodes the extraction indexed.
    public static let textApplicationScript = """
    window.__velaApplyTranslation = function (payload) {
      try {
        var data = typeof payload === 'string' ? JSON.parse(payload) : payload;
        var segments = data.segments || [];
        for (var i = 0; i < segments.length; i++) {
          var segment = segments[i];
          var nodes = document.createTreeWalker(document.body, NodeFilter.SHOW_TEXT, null);
          var node;
          while ((node = nodes.nextNode())) {
            if (node.__velaTranslationIndex === segment.index) {
              node.nodeValue = segment.text;
              break;
            }
          }
        }
        return true;
      } catch (_error) {
        return false;
      }
    };
    """
}
