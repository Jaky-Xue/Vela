//
//  WebPageScripts+Media.swift
//  Vela
//
//  The media scripts injected into pages, split from the base script
//  catalogue so each page-script area has its own file.
//

import Foundation

extension WebPageScripts {
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
        // The app's own fullscreen player owns the video's controls while it
        // is up; arming WebKit's inline controls underneath it would put two
        // control layers on the same picture.
        if (window.__velaPlayer && window.__velaPlayer.isActive()) { return; }
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


    // MARK: - Fullscreen player

    /// The app's own fullscreen video player, in place of the system one.
    ///
    /// Two roads lead into the system's media presentation: the page's
    /// Fullscreen API and the fullscreen button on WebKit's inline controls.
    /// Both are taken over. A video-bearing element is promoted to the
    /// viewport with fixed positioning instead — the page keeps its own
    /// player, captions and JavaScript, so nothing a site does to its video
    /// has to be reimplemented here — and the host draws its controls over
    /// the page, as a layer rather than a presented controller.
    ///
    /// The takeover has to be complete or it is worse than the native player.
    /// The Fullscreen API's three entry points (`requestFullscreen`,
    /// `webkitRequestFullscreen`, and `webkitEnterFullscreen` on the video)
    /// are replaced, presentation mode changes are followed, and the state
    /// the page reads back — `document.fullscreenElement`, its WebKit
    /// aliases, and the fullscreen events — is kept consistent so a player
    /// that branches on being fullscreen takes the same branch it would have
    /// taken natively. The inline controls' own fullscreen button cannot be
    /// intercepted as a call, because WebKit implements it below JavaScript;
    /// its `webkitbeginfullscreen` event is caught instead, the native
    /// presentation is closed, and the same promotion runs a moment later.
    ///
    /// The player container is what gets promoted whenever one can be found,
    /// including when the page asked for fullscreen on the bare video: the
    /// container carries the site's progress bar, settings menu and captions,
    /// and it survives a player that replaces or re-lays-out the video during
    /// the transition. The host then shows only a way out. A video with no
    /// player wrapper gets the host's controls instead, and WebKit's inline
    /// controls are stood down for the length of the presentation and
    /// restored exactly as they were.
    ///
    /// A fixed element is still positioned relative to any ancestor that
    /// creates a containing block — a transform, a filter, `contain` — so the
    /// ancestor chain is lifted for the length of the presentation and put
    /// back on the way out. A few delayed re-applies cover a native
    /// fullscreen teardown or a site layout that lands after the promotion.
    ///
    /// A player inside a cross-origin frame cannot be promoted from inside
    /// that frame — fixed positioning is relative to the frame's own
    /// viewport, which is still its old box on the page. The frame promotes
    /// itself and the host asks the top document to promote the frame
    /// element; on the way out the same message path releases it. The frame
    /// is matched by its URL when the top document can see it, and by
    /// largest visible area when it cannot.
    ///
    /// The script is also the control surface. `window.__velaPlayer` exposes
    /// `enter`, `exit`, `command`, `video` and `state`, `document` receives
    /// `velaplayerenter`, `velaplayerstate` and `velaplayerexit` events, and
    /// the host drives playback through `command`. A user script can call
    /// any of them, which is what "script can take over" means here: the
    /// player is not a closed native view.
    public static let mediaPlayerScript = """
    (function () {
      if (window.__velaMediaPlayerInstalled === true) { return; }
      window.__velaMediaPlayerInstalled = true;

      var handlerName = 'velaMediaFullscreen';
      var active = false;
      var activeElement = null;
      var activeVideo = null;
      var mode = 'video';
      var savedElement = null;
      var savedRoot = null;
      var savedBody = null;
      var savedControls = null;
      var overlayStyle = null;
      var promotedFrame = null;
      var savedFrame = null;
      var savedAncestors = [];
      var nativeTakeoverVideo = null;
      var lastStateAt = 0;

      var containerStyles = {
        'position': 'fixed',
        'inset': '0px',
        'top': '0px',
        'right': '0px',
        'bottom': '0px',
        'left': '0px',
        'width': '100vw',
        'height': '100vh',
        'max-width': 'none',
        'max-height': 'none',
        'margin': '0px',
        'padding': '0px',
        'background-color': '#000',
        'background-image': 'none',
        'transform': 'none',
        'z-index': '2147483647',
        'display': 'block',
        'overflow': 'hidden'
      };

      var videoStyles = {
        'position': 'fixed',
        'inset': '0px',
        'top': '0px',
        'right': '0px',
        'bottom': '0px',
        'left': '0px',
        'width': '100vw',
        'height': '100vh',
        'max-width': 'none',
        'max-height': 'none',
        'margin': '0px',
        'padding': '0px',
        'border': '0px',
        'background-color': '#000',
        'background-image': 'none',
        'object-fit': 'contain',
        'transform': 'none',
        'z-index': '2147483647',
        'display': 'block'
      };

      var frameStyles = {
        'position': 'fixed',
        'inset': '0px',
        'top': '0px',
        'right': '0px',
        'bottom': '0px',
        'left': '0px',
        'width': '100vw',
        'height': '100vh',
        'max-width': 'none',
        'max-height': 'none',
        'margin': '0px',
        'border': '0px',
        'z-index': '2147483647',
        'display': 'block'
      };

      // Properties that make an ancestor the containing block for a fixed
      // descendant. A player is often wrapped in one of them, which is why a
      // promoted element can stay trapped in its old box. The values are the
      // documented containing-block creators; each is restored on exit.
      var ancestorLiftStyles = {
        'transform': 'none',
        'filter': 'none',
        'perspective': 'none',
        'backdrop-filter': 'none',
        'contain': 'none',
        'will-change': 'auto'
      };

      function post(payload) {
        try {
          if (window.webkit && window.webkit.messageHandlers &&
              window.webkit.messageHandlers[handlerName]) {
            window.webkit.messageHandlers[handlerName].postMessage(payload);
          }
        } catch (error) {}
      }

      function findVideo(element) {
        if (!element) { return null; }
        if (element.tagName === 'VIDEO') { return element; }
        if (element.shadowRoot) {
          var inShadow = findVideo(element.shadowRoot);
          if (inShadow) { return inShadow; }
        }
        if (!element.querySelector) { return null; }
        var direct = element.querySelector('video');
        if (direct) { return direct; }
        // A web-component player keeps its video behind a shadow root the
        // selector cannot cross. Only open hosts are inspected, and only on the
        // fullscreen request itself, so this never runs per frame.
        var hosts = element.querySelectorAll('*');
        var limit = Math.min(hosts.length, 600);
        for (var i = 0; i < limit; i++) {
          if (!hosts[i].shadowRoot) { continue; }
          var nested = findVideo(hosts[i].shadowRoot);
          if (nested) { return nested; }
        }
        return null;
      }

      // A site's player is a container around the video: its chrome, its caption
      // layer, the element its own layout sizes. Promoting the container rather
      // than the bare video is what survives a player that replaces or re-lays-out
      // the video during the fullscreen transition. A video with no such wrapper
      // keeps the host's controls.
      function playerContainerFor(video) {
        if (!video || !video.closest) { return null; }
        var selectors = [
          '.html5-video-player',
          '#movie_player',
          '.bpx-player-container',
          '.bpx-player-video-wrap',
          '.video-js',
          '.vjs-player',
          '.plyr',
          '.jwplayer',
          '.dplayer',
          '.artplayer',
          '.prism-player',
          '.xgplayer',
          '.vp-player',
          '.vimeo-player',
          '[data-player]',
          '.video-player',
          '.player-container'
        ];
        for (var i = 0; i < selectors.length; i++) {
          var found = video.closest(selectors[i]);
          if (found && found !== document.body && found !== document.documentElement) {
            return found;
          }
        }
        var node = video.parentElement;
        for (var depth = 0; node && depth < 4 && node !== document.body; depth++) {
          var marker = '';
          try { marker = String(node.id || ''); } catch (error) {}
          try {
            marker += ' ' + String(typeof node.className === 'string' ? node.className : '');
          } catch (error) {}
          if (marker.toLowerCase().indexOf('player') !== -1) { return node; }
          node = node.parentElement;
        }
        return null;
      }

      function save(node, values) {
        if (!node) { return null; }
        var saved = {};
        for (var name in values) {
          if (!Object.prototype.hasOwnProperty.call(values, name)) { continue; }
          saved[name] = {
            value: node.style.getPropertyValue(name),
            priority: node.style.getPropertyPriority(name)
          };
        }
        return saved;
      }

      function apply(node, values) {
        if (!node || !values) { return; }
        for (var name in values) {
          if (!Object.prototype.hasOwnProperty.call(values, name)) { continue; }
          try { node.style.setProperty(name, values[name], 'important'); } catch (error) {}
        }
      }

      function restore(node, saved) {
        if (!node || !saved) { return; }
        for (var name in saved) {
          if (!Object.prototype.hasOwnProperty.call(saved, name)) { continue; }
          var entry = saved[name];
          try {
            if (entry && entry.value) {
              node.style.setProperty(name, entry.value, entry.priority || '');
            } else {
              node.style.removeProperty(name);
            }
          } catch (error) {}
        }
      }

      function currentVideo() {
        if (activeVideo && activeVideo.isConnected) { return activeVideo; }
        var replacement = null;
        if (activeElement && activeElement !== activeVideo) {
          replacement = findVideo(activeElement);
        }
        if (!replacement || !replacement.isConnected || replacement === activeVideo) {
          // A bare video that the site replaced. The new one is the page's video;
          // the host's controls should follow it even if it is no longer the
          // element that received the fullscreen request.
          replacement = document.querySelector('video');
        }
        if (replacement) {
          activeVideo = replacement;
          bindVideo(replacement);
        }
        return activeVideo;
      }

      function videoState() {
        var video = currentVideo();
        var duration = 0;
        try { duration = (video && isFinite(video.duration)) ? video.duration : 0; } catch (error) {}
        return {
          paused: video ? !!video.paused : true,
          currentTime: video ? Number(video.currentTime) || 0 : 0,
          duration: duration,
          muted: video ? !!video.muted : false,
          volume: video ? Number(video.volume) || 0 : 1,
          ended: video ? !!video.ended : false,
          readyState: video ? Number(video.readyState) || 0 : 0,
          canSeek: !!video && duration > 0 && video.seekable && video.seekable.length > 0
        };
      }

      function emit(kind) {
        try {
          var detail = videoState();
          detail.mode = active ? mode : '';
          detail.active = active;
          document.dispatchEvent(new CustomEvent('velaplayer' + kind, { detail: detail }));
        } catch (error) {}
      }

      function postState() {
        lastStateAt = Date.now();
        var state = videoState();
        state.event = 'state';
        post(state);
        emit('state');
      }

      function notifyFullscreenChange(element) {
        try { document.dispatchEvent(new Event('fullscreenchange')); } catch (error) {}
        try { document.dispatchEvent(new Event('webkitfullscreenchange')); } catch (error) {}
        if (element) {
          try { element.dispatchEvent(new Event('fullscreenchange')); } catch (error) {}
          try { element.dispatchEvent(new Event('webkitfullscreenchange')); } catch (error) {}
        }
      }

      function onMediaEvent(event) {
        if (!active || event.target !== activeVideo) { return; }
        postState();
      }

      function onTimeUpdate(event) {
        if (!active || event.target !== activeVideo) { return; }
        var now = Date.now();
        if (now - lastStateAt < 250) { return; }
        postState();
      }

      function bindVideo(video) {
        if (!video || video.__velaPlayerBound === true) { return; }
        video.__velaPlayerBound = true;
        var names = [
          'play', 'pause', 'ended', 'volumechange', 'ratechange',
          'durationchange', 'loadedmetadata', 'seeked', 'canplay', 'waiting', 'playing'
        ];
        for (var i = 0; i < names.length; i++) {
          video.addEventListener(names[i], onMediaEvent, true);
        }
        video.addEventListener('timeupdate', onTimeUpdate, true);
      }

      function liftAncestors(element) {
        savedAncestors = [];
        var node = element ? element.parentElement : null;
        while (node && node !== document.body && node !== document.documentElement) {
          var computed = null;
          try { computed = getComputedStyle(node); } catch (error) {}
          if (computed) {
            var willChange = String(computed.willChange || '');
            var createsContainingBlock =
              (computed.transform && computed.transform !== 'none') ||
              (computed.filter && computed.filter !== 'none') ||
              (computed.perspective && computed.perspective !== 'none') ||
              (computed.backdropFilter && computed.backdropFilter !== 'none') ||
              (computed.contain && computed.contain !== 'none') ||
              willChange.indexOf('transform') !== -1 ||
              willChange.indexOf('filter') !== -1 ||
              willChange.indexOf('perspective') !== -1 ||
              willChange.indexOf('contain') !== -1;
            if (createsContainingBlock) {
              savedAncestors.push({ node: node, saved: save(node, ancestorLiftStyles) });
              apply(node, ancestorLiftStyles);
            }
          }
          node = node.parentElement;
        }
      }

      function reapplyAncestorLift() {
        for (var i = 0; i < savedAncestors.length; i++) {
          apply(savedAncestors[i].node, ancestorLiftStyles);
        }
      }

      function restoreAncestors() {
        for (var i = savedAncestors.length - 1; i >= 0; i--) {
          restore(savedAncestors[i].node, savedAncestors[i].saved);
        }
        savedAncestors = [];
      }

      function enter(element, video, reason) {
        if (active) { exit('replaced', true); }
        if (!element) { return false; }
        nativeTakeoverVideo = null;
        var target = element;
        var targetVideo = video || findVideo(element);
        if (!targetVideo) { return false; }

        var nextMode = target.tagName === 'VIDEO' ? 'video' : 'container';
        active = true;
        activeElement = target;
        activeVideo = targetVideo;
        mode = nextMode;

        if (nextMode === 'video') {
          savedElement = save(target, videoStyles);
          apply(target, videoStyles);
        } else {
          savedElement = save(target, containerStyles);
          apply(target, containerStyles);
        }
        liftAncestors(target);

        savedRoot = save(document.documentElement, { 'overflow': 'hidden' });
        apply(document.documentElement, { 'overflow': 'hidden' });
        if (document.body) {
          savedBody = save(document.body, { 'overflow': 'hidden' });
          apply(document.body, { 'overflow': 'hidden' });
        }

        try { target.setAttribute('data-vela-media-fullscreen', nextMode); } catch (error) {}

        overlayStyle = document.createElement('style');
        overlayStyle.setAttribute('data-vela-media-player', '');
        overlayStyle.textContent =
          '[data-vela-media-fullscreen="container"] video{max-width:100vw!important;max-height:100vh!important;}' +
          '[data-vela-media-fullscreen="video"]::-webkit-media-controls{display:none!important;}';
        try { (document.head || document.documentElement).appendChild(overlayStyle); } catch (error) {}

        bindVideo(targetVideo);

        if (nextMode === 'video') {
          try {
            savedControls = { present: targetVideo.hasAttribute('controls') };
            targetVideo.controls = false;
          } catch (error) {}
        }

        var title = '';
        try { title = String(document.title || ''); } catch (error) {}
        if (!title) {
          try { title = String(targetVideo.getAttribute('title') || ''); } catch (error) {}
        }

        var state = videoState();
        post({
          event: 'enter',
          mode: nextMode,
          title: title,
          duration: state.duration,
          currentTime: state.currentTime,
          paused: state.paused,
          muted: state.muted,
          volume: state.volume,
          ended: state.ended,
          readyState: state.readyState,
          canSeek: state.canSeek,
          isTop: window.top === window,
          frameUrl: String(window.location.href || ''),
          reason: String(reason || 'page')
        });

        setTimeout(function () { notifyFullscreenChange(target); }, 0);
        try { targetVideo.dispatchEvent(new Event('webkitbeginfullscreen')); } catch (error) {}
        try { targetVideo.dispatchEvent(new Event('webkitpresentationmodechanged')); } catch (error) {}
        emit('enter');
        reassertStyles();
        return true;
      }

      function applyActiveStyles() {
        if (!active || !activeElement) { return; }
        if (mode === 'video') {
          apply(activeElement, videoStyles);
          if (activeVideo) {
            try { activeVideo.controls = false; } catch (error) {}
          }
        } else {
          apply(activeElement, containerStyles);
        }
      }

      // A native presentation that is closing can restore the page's layout after
      // this script has already applied its own, and a site's player can resize
      // the video only after it notices the container changed. A few re-applies
      // cover both, and stop as soon as the user leaves.
      function reassertStyles() {
        var delays = [0, 80, 300, 900, 1800];
        for (var i = 0; i < delays.length; i++) {
          (function (delay) {
            setTimeout(function () {
              if (!active) { return; }
              applyActiveStyles();
              reapplyAncestorLift();
              if (mode === 'container') {
                try { window.dispatchEvent(new Event('resize')); } catch (error) {}
              }
            }, delay);
          })(delays[i]);
        }
      }

      function exit(reason, silent) {
        if (!active) { return false; }
        var element = activeElement;
        var video = activeVideo;

        active = false;
        restore(element, savedElement);
        restoreAncestors();
        restore(document.documentElement, savedRoot);
        if (document.body) { restore(document.body, savedBody); }
        if (overlayStyle && overlayStyle.parentNode) {
          try { overlayStyle.parentNode.removeChild(overlayStyle); } catch (error) {}
        }
        if (element) {
          try { element.removeAttribute('data-vela-media-fullscreen'); } catch (error) {}
        }
        if (video && savedControls) {
          try { video.controls = !!savedControls.present; } catch (error) {}
        }

        activeElement = null;
        activeVideo = null;
        savedElement = null;
        savedRoot = null;
        savedBody = null;
        savedControls = null;
        overlayStyle = null;
        lastStateAt = 0;

        if (!silent) {
          post({ event: 'exit', reason: String(reason || 'page') });
          notifyFullscreenChange(element);
          try { video.dispatchEvent(new Event('webkitendfullscreen')); } catch (error) {}
          try { video.dispatchEvent(new Event('webkitpresentationmodechanged')); } catch (error) {}
          emit('exit');
        }
        return true;
      }

      function clampVolume(value) {
        var volume = Number(value);
        if (!isFinite(volume)) { return 1; }
        return Math.max(0, Math.min(1, volume));
      }

      function broadcastCommand(name, value) {
        var frames = document.querySelectorAll('iframe');
        for (var i = 0; i < frames.length; i++) {
          try {
            if (frames[i].contentWindow) {
              frames[i].contentWindow.postMessage(
                { velaMediaPlayer: 'command', name: String(name || ''), value: value },
                '*'
              );
            }
          } catch (error) {}
        }
      }

      function command(name, value) {
        if (!active) {
          broadcastCommand(name, value);
          return false;
        }
        var video = currentVideo();
        try {
          if (name === 'play' && video) {
            var attempt = video.play();
            if (attempt && attempt.catch) { attempt.catch(function () {}); }
            return true;
          }
          if (name === 'pause' && video) { video.pause(); return true; }
          if (name === 'toggle' && video) {
            if (video.paused) {
              var next = video.play();
              if (next && next.catch) { next.catch(function () {}); }
            } else {
              video.pause();
            }
            return true;
          }
          if (name === 'seek' && video) {
            var limit = isFinite(video.duration) && video.duration > 0 ? video.duration : Number(value);
            video.currentTime = Math.max(0, Math.min(Number(value) || 0, limit));
            postState();
            return true;
          }
          if (name === 'skip' && video) {
            var duration = isFinite(video.duration) && video.duration > 0 ? video.duration : null;
            var target = (Number(video.currentTime) || 0) + (Number(value) || 0);
            video.currentTime = duration === null
              ? Math.max(0, target)
              : Math.max(0, Math.min(target, duration));
            postState();
            return true;
          }
          if (name === 'mute' && video) {
            video.muted = !!value;
            postState();
            return true;
          }
          if (name === 'volume' && video) {
            video.volume = clampVolume(value);
            postState();
            return true;
          }
          if (name === 'exit') {
            exit('host');
            return true;
          }
        } catch (error) {}
        return false;
      }

      function enterBest(element, reason) {
        if (!element) { return false; }
        if (element.tagName === 'VIDEO') {
          var container = playerContainerFor(element);
          if (container) { return enter(container, element, reason); }
          return enter(element, element, reason);
        }
        var video = findVideo(element);
        if (!video) { return false; }
        return enter(element, video, reason);
      }

      function requestFrom(element) {
        if (!element) { return false; }
        // A page that makes the whole document fullscreen is not asking for a
        // player; leave that to WebKit's element presentation.
        if (element === document.body || element === document.documentElement) { return false; }
        return enterBest(element, 'page');
      }

      var nativeRequestFullscreen = Element.prototype.requestFullscreen;
      Element.prototype.requestFullscreen = function () {
        if (requestFrom(this)) { return Promise.resolve(); }
        if (typeof nativeRequestFullscreen === 'function') {
          return nativeRequestFullscreen.apply(this, arguments);
        }
        return Promise.reject(new TypeError('Fullscreen is not supported'));
      };

      var nativeWebkitRequestFullscreen = Element.prototype.webkitRequestFullscreen;
      Element.prototype.webkitRequestFullscreen = function () {
        if (requestFrom(this)) { return; }
        if (typeof nativeWebkitRequestFullscreen === 'function') {
          return nativeWebkitRequestFullscreen.apply(this, arguments);
        }
      };

      var videoProto = window.HTMLVideoElement && HTMLVideoElement.prototype;
      if (videoProto && typeof videoProto.webkitEnterFullscreen === 'function') {
        videoProto.webkitEnterFullscreen = function () {
          requestFrom(this);
        };
      }
      if (videoProto && typeof videoProto.webkitSetPresentationMode === 'function') {
        var nativePresentationMode = videoProto.webkitSetPresentationMode;
        videoProto.webkitSetPresentationMode = function (nextMode) {
          if (nextMode === 'fullscreen') {
            requestFrom(this);
            return;
          }
          if (nextMode === 'inline' && active && activeVideo === this) {
            exit('page');
            return;
          }
          return nativePresentationMode.apply(this, arguments);
        };
      }

      // A player that just called webkitEnterFullscreen reads the presentation
      // mode back to decide whether to draw its own fullscreen chrome.
      function patchVideoGetter(name, valueWhenActive) {
        try {
          var descriptor = Object.getOwnPropertyDescriptor(HTMLVideoElement.prototype, name);
          if (!descriptor || typeof descriptor.get !== 'function') { return; }
          var original = descriptor.get;
          Object.defineProperty(HTMLVideoElement.prototype, name, {
            configurable: true,
            enumerable: descriptor.enumerable,
            get: function () {
              return (active && activeVideo === this) ? valueWhenActive : original.call(this);
            }
          });
        } catch (error) {}
      }

      patchVideoGetter('webkitPresentationMode', 'fullscreen');
      patchVideoGetter('webkitDisplayingFullscreen', true);

      var nativeExitFullscreen = document.exitFullscreen;
      document.exitFullscreen = function () {
        if (active) {
          exit('page');
          return Promise.resolve();
        }
        if (typeof nativeExitFullscreen === 'function') {
          return nativeExitFullscreen.apply(document, arguments);
        }
        return Promise.resolve();
      };

      var nativeWebkitExitFullscreen = document.webkitExitFullscreen;
      document.webkitExitFullscreen = function () {
        if (active) {
          exit('page');
          return;
        }
        if (typeof nativeWebkitExitFullscreen === 'function') {
          return nativeWebkitExitFullscreen.apply(document, arguments);
        }
      };

      var nativeWebkitCancelFullScreen = document.webkitCancelFullScreen;
      document.webkitCancelFullScreen = function () {
        if (active) {
          exit('page');
          return;
        }
        if (typeof nativeWebkitCancelFullScreen === 'function') {
          return nativeWebkitCancelFullScreen.apply(document, arguments);
        }
      };

      function patchFullscreenElement(name) {
        try {
          var descriptor = Object.getOwnPropertyDescriptor(Document.prototype, name);
          if (!descriptor || typeof descriptor.get !== 'function') { return; }
          var original = descriptor.get;
          Object.defineProperty(Document.prototype, name, {
            configurable: true,
            enumerable: descriptor.enumerable,
            get: function () { return active ? activeElement : original.call(this); }
          });
        } catch (error) {}
      }

      patchFullscreenElement('fullscreenElement');
      patchFullscreenElement('webkitFullscreenElement');
      patchFullscreenElement('webkitCurrentFullScreenElement');

      // Some players branch on a boolean rather than on the element. Inactive,
      // these delegate to WebKit so a non-video element fullscreen still reads
      // true; active, they describe the presentation this script is running.
      function patchBooleanGetter(name) {
        try {
          var descriptor = Object.getOwnPropertyDescriptor(Document.prototype, name);
          if (!descriptor || typeof descriptor.get !== 'function') { return; }
          var original = descriptor.get;
          Object.defineProperty(Document.prototype, name, {
            configurable: true,
            enumerable: descriptor.enumerable,
            get: function () { return active ? true : original.call(this); }
          });
        } catch (error) {}
      }

      patchBooleanGetter('webkitIsFullScreen');
      patchBooleanGetter('fullscreenEnabled');
      patchBooleanGetter('webkitFullscreenEnabled');

      function frameMatches(frame, url) {
        if (!frame || !url) { return false; }
        var src = frame.getAttribute('src') || frame.getAttribute('data-src') || '';
        if (!src) { return false; }
        try {
          var resolved = new URL(src, window.location.href).href;
          var cleanUrl = String(url).split('#')[0];
          if (resolved.split('#')[0] === cleanUrl) { return true; }
          var resolvedHost = '';
          var urlHost = '';
          try { resolvedHost = new URL(resolved).host; } catch (error) {}
          try { urlHost = new URL(cleanUrl).host; } catch (error) {}
          if (resolvedHost && urlHost && resolvedHost === urlHost) { return true; }
        } catch (error) {}
        return false;
      }

      function largestVisibleFrame() {
        var frames = document.querySelectorAll('iframe');
        var best = null;
        var bestArea = 0;
        for (var i = 0; i < frames.length; i++) {
          var frame = frames[i];
          var rect = null;
          try { rect = frame.getBoundingClientRect(); } catch (error) {}
          if (!rect || rect.width < 120 || rect.height < 80) { continue; }
          var area = rect.width * rect.height;
          if (area > bestArea) { bestArea = area; best = frame; }
        }
        return best;
      }

      function promoteFrame(url) {
        if (window.top !== window) { return false; }
        var target = null;
        var frames = document.querySelectorAll('iframe');
        for (var i = 0; i < frames.length; i++) {
          if (frameMatches(frames[i], url)) { target = frames[i]; break; }
        }
        if (!target) { target = largestVisibleFrame(); }
        if (!target) { return false; }
        if (promotedFrame && promotedFrame !== target) { releaseFrame(); }
        promotedFrame = target;
        savedFrame = save(target, frameStyles);
        apply(target, frameStyles);
        return true;
      }

      function releaseFrame() {
        if (promotedFrame) {
          restore(promotedFrame, savedFrame);
          promotedFrame = null;
          savedFrame = null;
        }
        var frames = document.querySelectorAll('iframe');
        for (var i = 0; i < frames.length; i++) {
          try {
            if (frames[i].contentWindow) {
              frames[i].contentWindow.postMessage({ velaMediaPlayer: 'release' }, '*');
            }
          } catch (error) {}
        }
      }

      function takeOverNativePlayer(video) {
        if (!video || active || nativeTakeoverVideo === video) { return; }
        nativeTakeoverVideo = video;
        try {
          if (typeof video.webkitExitFullscreen === 'function') {
            video.webkitExitFullscreen();
          } else if (typeof video.webkitSetPresentationMode === 'function') {
            video.webkitSetPresentationMode('inline');
          }
        } catch (error) {}
        setTimeout(function () {
          if (nativeTakeoverVideo === video && !active) {
            nativeTakeoverVideo = null;
            enter(video, video, 'takeover');
          }
        }, 120);
      }

      function onNativeBegin(event) {
        var video = event.target;
        if (!video || video.tagName !== 'VIDEO' || active) { return; }
        takeOverNativePlayer(video);
      }

      function onNativeEnd(event) {
        var video = event.target;
        if (nativeTakeoverVideo && video === nativeTakeoverVideo) {
          nativeTakeoverVideo = null;
          enter(video, video, 'takeover');
        }
      }

      // The event is dispatched at the video. WebKit bubbles it to the document,
      // but a direct listener removes any doubt — and the DOMContentLoaded scan
      // covers a video that was on the page before this script installed.
      function watchVideo(video) {
        if (!video || video.tagName !== 'VIDEO' || video.__velaNativeWatch === true) { return; }
        video.__velaNativeWatch = true;
        video.addEventListener('webkitbeginfullscreen', onNativeBegin, true);
        video.addEventListener('webkitendfullscreen', onNativeEnd, true);
      }

      function watchVideos(root) {
        if (!root || !root.querySelectorAll) { return; }
        var videos = root.querySelectorAll('video');
        for (var i = 0; i < videos.length; i++) { watchVideo(videos[i]); }
      }

      document.addEventListener('webkitbeginfullscreen', onNativeBegin, true);
      document.addEventListener('webkitendfullscreen', onNativeEnd, true);
      document.addEventListener('play', function (event) { watchVideo(event.target); }, true);
      document.addEventListener('loadedmetadata', function (event) { watchVideo(event.target); }, true);
      document.addEventListener('DOMContentLoaded', function () { watchVideos(document); }, true);
      setTimeout(function () { watchVideos(document); }, 0);

      window.addEventListener('message', function (event) {
        var data = event && event.data;
        if (!data || data.velaMediaPlayer === undefined) { return; }
        if (data.velaMediaPlayer === 'command') {
          command(data.name, data.value);
          return;
        }
        if (data.velaMediaPlayer === 'release' && active) {
          exit('host', true);
        }
      }, false);

      window.__velaPlayer = {
        version: 1,
        enter: function (element) {
          var target = element || document.querySelector('video');
          if (!target) { return false; }
          return enterBest(target, 'script');
        },
        exit: function () {
          if (active) { return exit('script'); }
          broadcastCommand('exit');
          return false;
        },
        command: command,
        isActive: function () { return active; },
        mode: function () { return active ? mode : ''; },
        video: function () { return activeVideo; },
        state: videoState,
        promoteFrame: promoteFrame,
        releaseFrame: releaseFrame
      };
    })();
    """

}
