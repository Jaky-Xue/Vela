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

}
