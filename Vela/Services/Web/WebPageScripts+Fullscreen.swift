//
//  WebPageScripts+Fullscreen.swift
//  Vela
//
//  The fullscreen bridge: video fullscreen goes to Apple's system player, and
//  the page is kept from raising a keyboard or a second caption layer over it.
//

extension WebPageScripts {
    /// Routes fullscreen requests for a video or its player container to the
    /// iOS media player. Requests that WebKit cannot promote use the original
    /// API.
    ///
    /// The redirect is only half of the job. The system player is a separate
    /// presentation drawn over the page, so two things the page does to its own
    /// video still reach the film:
    ///
    /// * **The keyboard.** A text field the page focused — a search box, a
    ///   player's hidden input — keeps the focus through the transition, and
    ///   WebKit restores its keyboard over the player the first time the
    ///   player's own controls take and release the first responder. Tapping
    ///   倍速 or any other control at the bottom of the film then raised a
    ///   keyboard that had nothing to do with the tap. The page blurs its
    ///   editors on the way in and refuses focus a tap did not ask for while a
    ///   video is fullscreen; the host dismisses the keyboard as well, which is
    ///   what covers a field living in another frame.
    ///
    /// * **The caption layer.** WebKit builds a text-track representation layer
    ///   while the video is inline and, on the way into the system player, can
    ///   leave that layer painted beside the one the player draws — the same
    ///   sentence on two rows. Taking a showing track out of `showing` and
    ///   putting it back makes WebKit lay the layer down again, which is what
    ///   the viewer does by hand when closing and reopening the player's 字幕
    ///   switch clears the duplicate.
    ///
    ///   YouTube has a second way to double the sentence. WebKit's own caption
    ///   mirror adds a forced track named 'YouTube Captions', shows it for the
    ///   native presentation and hides YouTube's DOM paint — but it never turns
    ///   YouTube's own caption track off, so when both are showing the player
    ///   draws both. Two showing tracks carrying the same sentence are stood
    ///   down to one for the length of the presentation; two languages are
    ///   different sentences and are left alone.
    ///
    /// Only videos are treated as fullscreen here. Element fullscreen of any
    /// other content — an image viewer, a document — falls through untouched,
    /// including its text fields.
    static let fullscreenBridge = """
    (function () {
      if (window.__velaFullscreenBridgeInstalled === true) { return; }
      window.__velaFullscreenBridgeInstalled = true;

      // MARK: - The fullscreen request goes to the system player

      function findVideo(element) {
        if (!element) { return null; }
        if (element.tagName === 'VIDEO') { return element; }
        if (element.querySelector) { return element.querySelector('video'); }
        return null;
      }

      function patch(name, returnsPromise) {
        var original = Element.prototype[name];
        if (typeof original !== 'function') { return; }

        Element.prototype[name] = function () {
          if (document.fullscreenEnabled !== false && this instanceof Element) {
            var video = findVideo(this);
            if (video && video.webkitSupportsFullscreen !== false &&
                typeof video.webkitEnterFullscreen === 'function') {
              try {
                video.webkitEnterFullscreen();
              } catch (error) {
                // WebKit can reject native fullscreen before media is ready.
                return original.apply(this, arguments);
              }
              // The page's `requestFullscreen` continuation runs in the
              // microtask after this returns. Arming the guard before that is
              // what keeps a field the continuation focuses off the screen.
              try { beginNative(video); } catch (error) {}
              return returnsPromise ? Promise.resolve() : undefined;
            }
          }
          return original.apply(this, arguments);
        };
      }

      patch('requestFullscreen', true);
      patch('webkitRequestFullscreen', false);

      // MARK: - Which presentation is up

      // The video the system player is presenting, or null. Set from the
      // events WebKit sends whichever way the video got there — the page's
      // fullscreen request, the video's own `webkitEnterFullscreen`, or the
      // system controls.
      var nativeVideo = null;
      var nativeStartedAt = 0;

      function nativeFullscreenActive() {
        if (nativeVideo === null || nativeVideo.isConnected === false) { return false; }
        // Both fullscreen roads have a flag: the legacy one reports
        // `webkitDisplayingFullscreen`, the presentation-mode one reports its
        // mode. Either says the film owns the screen.
        if (nativeVideo.webkitDisplayingFullscreen === true) { return true; }
        var mode = nativeVideo.webkitPresentationMode;
        if (typeof mode === 'string' && mode === 'fullscreen') { return true; }
        // Both flags switch after the call that starts the player returns, and
        // the page's own continuation runs in between. That hand-over window
        // still counts, or a field the page focuses there would slip past the
        // guard; after it, a player that never opened leaves the page alone.
        return Date.now() - nativeStartedAt < 2000;
      }

      function elementFullscreenVideo() {
        var element = document.fullscreenElement || document.webkitFullscreenElement;
        return element ? findVideo(element) : null;
      }

      function reportNative(active) {
        try {
          var handlers = window.webkit && window.webkit.messageHandlers;
          if (handlers && handlers.\(Handler.mediaFullscreen.rawValue)) {
            handlers.\(Handler.mediaFullscreen.rawValue).postMessage({ active: !!active });
          }
        } catch (error) {
        }
      }

      // MARK: - The keyboard

      function isTextField(node) {
        if (!node || node.nodeType !== 1) { return false; }
        if (node.isContentEditable === true) { return true; }
        if (node.tagName === 'TEXTAREA') { return true; }
        if (node.tagName !== 'INPUT') { return false; }
        var type = String(node.type || 'text').toLowerCase();
        return ['button', 'checkbox', 'color', 'file', 'hidden', 'image',
                'radio', 'range', 'reset', 'submit'].indexOf(type) === -1;
      }

      function deepestTarget(event) {
        if (typeof event.composedPath === 'function') {
          var path = event.composedPath();
          if (path.length > 0) { return path[0]; }
        }
        return event.target;
      }

      function textFieldInEvent(event) {
        if (typeof event.composedPath === 'function') {
          var path = event.composedPath();
          for (var i = 0; i < path.length; i++) {
            if (isTextField(path[i])) { return path[i]; }
          }
          return null;
        }
        return isTextField(event.target) ? event.target : null;
      }

      function activeTextField() {
        var active = document.activeElement;
        var depth = 0;
        while (active && active.shadowRoot && active.shadowRoot.activeElement && depth < 8) {
          active = active.shadowRoot.activeElement;
          depth += 1;
        }
        return isTextField(active) ? active : null;
      }

      // What the last touch landed on. A tap on a field is the one focus a
      // fullscreen player may accept; everything else was the page deciding
      // to type for the viewer, which it cannot mean while the film is up.
      var lastTap = { target: null, at: 0 };

      function rememberTap(event) {
        lastTap.target = deepestTarget(event);
        lastTap.at = Date.now();
      }

      document.addEventListener('touchstart', rememberTap, true);
      document.addEventListener('pointerdown', rememberTap, true);

      function tapLandedOn(field) {
        var target = lastTap.target;
        if (!target || Date.now() - lastTap.at > 1200) { return false; }
        if (target === field) { return true; }
        if (field.contains && field.contains(target)) { return true; }
        // A player's input often sits inside a button-like wrapper the tap
        // lands on. The immediate parent is the one relationship to accept;
        // anything further up is the page, which would let every tap through.
        if (field.parentElement && field.parentElement === target) { return true; }
        // A label is the field's own tap target by convention.
        if (target.tagName === 'LABEL' && target.control === field) { return true; }
        return false;
      }

      document.addEventListener('focusin', function (event) {
        var native = nativeFullscreenActive();
        if (!native && !elementFullscreenVideo()) { return; }
        var field = textFieldInEvent(event);
        if (!field) { return; }
        // Over the system player the page is not on screen at all, so no text
        // field there can be the one being typed into.
        if (native) {
          try { field.blur(); } catch (error) {}
          return;
        }
        if (tapLandedOn(field)) { return; }
        try { field.blur(); } catch (error) {}
      }, true);

      function blurPageEditors() {
        var field = activeTextField();
        if (!field) { return; }
        try { field.blur(); } catch (error) {}
      }

      // MARK: - The caption layer

      function captionTracks(video) {
        var tracks = video && video.textTracks;
        var list = [];
        if (!tracks) { return list; }
        for (var i = 0; i < tracks.length; i++) {
          var kind = tracks[i].kind;
          if (kind === 'subtitles' || kind === 'captions' || kind === 'forced') {
            list.push(tracks[i]);
          }
        }
        return list;
      }

      function relayoutCaptionLayers(video) {
        var tracks = captionTracks(video);
        for (var i = 0; i < tracks.length; i++) {
          var track = tracks[i];
          if (track.mode !== 'showing') { continue; }
          try { track.mode = 'hidden'; } catch (error) { continue; }
          (function (restore) {
            setTimeout(function () {
              try { restore.mode = 'showing'; } catch (error) {}
            }, 60);
          })(track);
        }
      }

      function captionPresentationActive() {
        return nativeFullscreenActive() || elementFullscreenVideo() !== null;
      }

      function scheduleCaptionRepaint(video) {
        if (!captionTracks(video).length) { return; }
        var generation = (video.__velaCaptionRepaint || 0) + 1;
        video.__velaCaptionRepaint = generation;
        var delays = [350, 1600];
        for (var i = 0; i < delays.length; i++) {
          (function (delay) {
            setTimeout(function () {
              if (video.__velaCaptionRepaint !== generation) { return; }
              if (!captionPresentationActive()) { return; }
              relayoutCaptionLayers(video);
            }, delay);
          })(delays[i]);
        }
      }

      // A player often adds its subtitle track only once the film is under
      // way, which can be after the presentation opened.
      function watchCaptionTracks(video) {
        var tracks = video && video.textTracks;
        if (!tracks || video.__velaCaptionWatch === true) { return; }
        video.__velaCaptionWatch = true;
        try {
          tracks.addEventListener('addtrack', function (event) {
            var track = event.track;
            if (!track || (track.kind !== 'subtitles' &&
                           track.kind !== 'captions' &&
                           track.kind !== 'forced')) { return; }
            setTimeout(function () {
              if (!captionPresentationActive()) { return; }
              relayoutCaptionLayers(video);
            }, 300);
          });
        } catch (error) {
        }
      }

      // The sentence is compared without the spacing and the zero-width marks
      // a page or WebKit may put between segments: two tracks drawing the same
      // words are a duplicate whatever the spacing.
      function captionText(track) {
        var cues = track && track.activeCues;
        if (!cues || cues.length === 0) { return ''; }
        var raw = '';
        for (var i = 0; i < cues.length; i++) {
          raw += String(cues[i].text || '');
        }
        var out = '';
        for (var j = 0; j < raw.length; j++) {
          var code = raw.charCodeAt(j);
          if (code <= 32 || code === 0x200B || code === 0x200C ||
              code === 0x200D || code === 0xFEFF) { continue; }
          out += raw.charAt(j);
        }
        return out;
      }

      function isMirrorTrack(track) {
        return String(track.label || '') === 'YouTube Captions';
      }

      // WebKit's mirror is the layer to stand down: the page's own track keeps
      // its cues, and the mirror's mode is WebKit's to set back on the way out.
      // A page track that has to yield is remembered so its own state is
      // restored when the presentation ends.
      function suppressDuplicateCaptionTracks(video) {
        var tracks = captionTracks(video);
        // A null prototype: a caption that happens to read "constructor" is a
        // sentence, not a property of Object.
        var groups = Object.create(null);
        var keys = [];
        var i;
        for (i = 0; i < tracks.length; i++) {
          if (tracks[i].mode !== 'showing') { continue; }
          var key = captionText(tracks[i]);
          if (!key) { continue; }
          if (!groups[key]) {
            groups[key] = [];
            keys.push(key);
          }
          groups[key].push(tracks[i]);
        }
        for (i = 0; i < keys.length; i++) {
          var group = groups[keys[i]];
          if (group.length < 2) { continue; }
          var keep = null;
          for (var j = 0; j < group.length; j++) {
            if (!isMirrorTrack(group[j])) { keep = group[j]; break; }
          }
          if (!keep) { keep = group[0]; }
          for (var k = 0; k < group.length; k++) {
            var track = group[k];
            if (track === keep) { continue; }
            try {
              track.mode = 'hidden';
              if (!isMirrorTrack(track)) {
                if (!video.__velaSuppressedCaptionTracks) {
                  video.__velaSuppressedCaptionTracks = [];
                }
                video.__velaSuppressedCaptionTracks.push(track);
              }
            } catch (error) {
            }
          }
        }
      }

      function restoreSuppressedCaptionTracks(video) {
        var list = video.__velaSuppressedCaptionTracks || [];
        video.__velaSuppressedCaptionTracks = [];
        for (var i = 0; i < list.length; i++) {
          if (list[i].mode === 'hidden') {
            try { list[i].mode = 'showing'; } catch (error) {}
          }
        }
      }

      function startCaptionDedupe(video) {
        if (video.__velaCaptionDedupeTimer) { return; }
        video.__velaCaptionDedupeTimer = setInterval(function () {
          if (nativeVideo !== video || video.isConnected === false) {
            stopCaptionDedupe(video);
            return;
          }
          suppressDuplicateCaptionTracks(video);
        }, 500);
      }

      function stopCaptionDedupe(video) {
        if (!video.__velaCaptionDedupeTimer) { return; }
        clearInterval(video.__velaCaptionDedupeTimer);
        video.__velaCaptionDedupeTimer = null;
      }

      // MARK: - The presentations

      var nativeVerifyTimer = null;

      // The page can ask the system player for media that cannot open it:
      // `webkitEnterFullscreen` then returns without throwing and no event
      // follows. Without a check, the page would stay marked as a full-screen
      // film — and its keyboard stay suppressed — for the life of the tab.
      function scheduleNativeVerification(video) {
        if (nativeVerifyTimer) { clearTimeout(nativeVerifyTimer); }
        nativeVerifyTimer = setTimeout(function () {
          nativeVerifyTimer = null;
          if (nativeVideo !== video) { return; }
          if (nativeFullscreenActive()) { return; }
          endNative(video);
        }, 3500);
      }

      function beginNative(video) {
        if (!video) { return; }
        nativeVideo = video;
        nativeStartedAt = Date.now();
        blurPageEditors();
        reportNative(true);
        watchCaptionTracks(video);
        scheduleCaptionRepaint(video);
        startCaptionDedupe(video);
        scheduleNativeVerification(video);
      }

      function endNative(video) {
        if (nativeVideo === video) { nativeVideo = null; }
        if (nativeVerifyTimer) {
          clearTimeout(nativeVerifyTimer);
          nativeVerifyTimer = null;
        }
        if (video) {
          stopCaptionDedupe(video);
          restoreSuppressedCaptionTracks(video);
        }
        reportNative(nativeVideo !== null);
      }

      document.addEventListener('webkitbeginfullscreen', function (event) {
        var video = event.target;
        if (video && video.tagName === 'VIDEO') { beginNative(video); }
      }, true);

      document.addEventListener('webkitendfullscreen', function (event) {
        var video = event.target;
        if (video && video.tagName === 'VIDEO') { endNative(video); }
      }, true);

      // The presentation-mode road, which the system's own PiP and fullscreen
      // buttons take. Picture-in-picture is not fullscreen: the page is still
      // on screen and its text fields must keep working, so it ends the
      // fullscreen state rather than starting one.
      document.addEventListener('webkitpresentationmodechanged', function (event) {
        var video = event.target;
        if (!video || video.tagName !== 'VIDEO') { return; }
        if (video.webkitPresentationMode === 'fullscreen') {
          beginNative(video);
          return;
        }
        endNative(video);
      }, true);

      function handleElementFullscreenChange() {
        var video = elementFullscreenVideo();
        if (!video) { return; }
        blurPageEditors();
        watchCaptionTracks(video);
        scheduleCaptionRepaint(video);
      }

      document.addEventListener('fullscreenchange', handleElementFullscreenChange, true);
      document.addEventListener('webkitfullscreenchange', handleElementFullscreenChange, true);
    })();
    """
}
