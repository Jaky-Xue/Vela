//
//  WebPageScripts+Fullscreen.swift
//  Vela
//
//  The fullscreen bridge: video fullscreen goes to Apple's system player, and
//  the page is kept from raising a keyboard or a second caption layer over it.
//

extension WebPageScripts {
    /// Routes fullscreen requests for a video or its player container to the
    /// iOS media player. WebKit's element fullscreen remains the fallback.
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
    /// * **The captions.** The system player draws every text track left
    ///   `showing`, so a page that leaves two languages — or a page track
    ///   beside WebKit's own YouTube caption mirror — produces the same
    ///   sentence twice. The bridge settles on the one track the page is
    ///   actually showing before the player opens: the page's own showing
    ///   track when there is one, and when the page paints its captions into
    ///   the DOM instead the track whose cues carry the painted sentence. Every
    ///   other language is hidden and the mirror is held out of `showing` in
    ///   its own setter, so the extra caption is never produced rather than
    ///   hidden after it has drawn. The selection follows the page while the
    ///   film runs — a language switch changes the painted sentence or the
    ///   showing track — and a choice the viewer makes in the system player's
    ///   字幕 menu is left alone and reaches the page when the film ends.
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
              return returnsPromise ? Promise.resolve() : undefined;
            }
          }
          return original.apply(this, arguments);
        };
      }

      patch('requestFullscreen', true);
      patch('webkitRequestFullscreen', false);

      // The page's own fullscreen roads — the video's legacy method and the
      // presentation-mode API — reach the system player without passing the
      // Element wrappers above. Caption preparation runs before each so the
      // player opens on a single caption track, not beside a second one it
      // would have to be repaired after the fact.
      function openNative(video, method, args) {
        try { prepareNativeCaptions(video); } catch (error) {}
        var result;
        try {
          result = method.apply(video, args);
        } catch (error) {
          if (nativeVideo !== video) { stopCaptionSync(video); }
          throw error;
        }
        // A requestFullscreen continuation can focus an editor before
        // WebKit delivers the presentation event.
        try { beginNative(video); } catch (error) {}
        return result;
      }

      try {
        var videoProto = window.HTMLVideoElement && HTMLVideoElement.prototype;
        if (videoProto && typeof videoProto.webkitEnterFullscreen === 'function') {
          var nativeEnterFullscreen = videoProto.webkitEnterFullscreen;
          videoProto.webkitEnterFullscreen = function () {
            return openNative(this, nativeEnterFullscreen, arguments);
          };
        }
        if (videoProto && typeof videoProto.webkitSetPresentationMode === 'function') {
          var nativeSetPresentationMode = videoProto.webkitSetPresentationMode;
          videoProto.webkitSetPresentationMode = function (mode) {
            if (String(mode) === 'fullscreen') {
              return openNative(this, nativeSetPresentationMode, arguments);
            }
            return nativeSetPresentationMode.apply(this, arguments);
          };
        }
      } catch (error) {
      }

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

      // The sentence the page is painting itself: YouTube's caption windows,
      // Bilibili's strip, the common JavaScript players. A page with its own
      // caption UI usually keeps its text tracks hidden, so the language on
      // screen is not written on any track — the painted sentence is the only
      // statement of which language the viewer is reading.
      var paintedCaptionSelectors = [
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

      // Spacing and zero-width marks differ between a track's cue text and the
      // page's painted copy of the same sentence; they are not what tells two
      // captions apart.
      function normalizeCaptionText(text) {
        var raw = String(text || '');
        var out = '';
        for (var i = 0; i < raw.length; i++) {
          var code = raw.charCodeAt(i);
          if (code <= 32 || code === 0x200B || code === 0x200C ||
              code === 0x200D || code === 0xFEFF) { continue; }
          out += raw.charAt(i);
        }
        return out;
      }

      function paintedCaptionText(video) {
        for (var container = video.parentElement; container; container = container.parentElement) {
          // Beyond this point, captions could belong to another player.
          if (container.querySelectorAll('video').length > 1) { break; }
          var text = captionTextIn(container);
          if (text) { return text; }
        }
        return '';
      }

      function captionTextIn(container) {
        for (var s = 0; s < paintedCaptionSelectors.length; s++) {
          var nodes = container.querySelectorAll(paintedCaptionSelectors[s]);
          var parts = [];
          for (var i = 0; i < nodes.length; i++) {
            // `textContent`, not a visibility test: the system presentation
            // hides the page's caption container and the text has to stay
            // readable there.
            var text = normalizeCaptionText(nodes[i].textContent);
            if (text && parts.indexOf(text) === -1) { parts.push(text); }
          }
          if (parts.length > 0) { return parts.join(''); }
        }
        return '';
      }

      // WebKit's own YouTube caption mirror. It draws beside the page's
      // caption track in the system player; it is a duplicate layer whenever
      // the page already has a track carrying the same sentence.
      function isMirrorTrack(track) {
        return String(track.label || '') === 'YouTube Captions';
      }

      // The page's own caption languages. `forced` tracks are the player's
      // signs and songs, not the subtitle the viewer picked, and are left
      // alone; the mirror is handled separately.
      function pageCaptionTracks(video) {
        var tracks = video && video.textTracks;
        var list = [];
        if (!tracks) { return list; }
        for (var i = 0; i < tracks.length; i++) {
          var track = tracks[i];
          if (isMirrorTrack(track)) { continue; }
          if (track.kind === 'subtitles' || track.kind === 'captions') {
            list.push(track);
          }
        }
        return list;
      }

      function mirrorTracks(video) {
        var tracks = video && video.textTracks;
        var list = [];
        if (!tracks) { return list; }
        for (var i = 0; i < tracks.length; i++) {
          if (isMirrorTrack(tracks[i])) { list.push(tracks[i]); }
        }
        return list;
      }

      function activeCaptionText(track) {
        var cues = track && track.activeCues;
        if (!cues || cues.length === 0) { return ''; }
        var text = '';
        for (var i = 0; i < cues.length; i++) {
          text += String(cues[i].text || '');
        }
        return normalizeCaptionText(text);
      }

      function matchingTrack(tracks, painted) {
        if (!painted) { return null; }
        for (var i = 0; i < tracks.length; i++) {
          var cue = activeCaptionText(tracks[i]);
          if (!cue) { continue; }
          if (cue === painted || cue.indexOf(painted) >= 0 || painted.indexOf(cue) >= 0) {
            return tracks[i];
          }
        }
        return null;
      }

      function captionState(video) {
        var state = video.__velaCaptions;
        if (!state) {
          state = {
            original: [],
            mirrors: [],
            chosen: null,
            painted: '',
            timer: null,
            debounce: null,
            changeHandler: null,
            addHandler: null,
            removeHandler: null
          };
          video.__velaCaptions = state;
        }
        return state;
      }

      // Records a track's mode the first time the bridge writes it, and what
      // the bridge wrote, so leaving the film puts the page back the way it
      // was unless the viewer changed the track themselves in the meantime.
      function setCaptionMode(state, track, mode) {
        if (track.mode === mode) { return; }
        var entry = null;
        for (var i = 0; i < state.original.length; i++) {
          if (state.original[i].track === track) { entry = state.original[i]; break; }
        }
        if (!entry) {
          entry = { track: track, mode: track.mode, set: null };
          state.original.push(entry);
        }
        try { track.mode = mode; } catch (error) { return; }
        entry.set = mode;
      }

      // The page's own caption track is the source. The bridge keeps exactly
      // that one `showing` and every other language `hidden`, so the system
      // player never receives two captions to draw; the mirror is the one
      // extra layer that can appear beside it, and it is held out below.
      function enforceCaptionSelection(video, state) {
        var tracks = pageCaptionTracks(video);
        for (var i = 0; i < tracks.length; i++) {
          setCaptionMode(state, tracks[i], tracks[i] === state.chosen ? 'showing' : 'hidden');
        }
        if (state.chosen !== null) {
          var mirrors = mirrorTracks(video);
          for (var j = 0; j < mirrors.length; j++) {
            setCaptionMode(state, mirrors[j], 'hidden');
          }
        }
      }

      // A track the system player draws regardless of the page: while the
      // page's own caption is showing, the mirror must not enter `showing` at
      // all. Blocking it in its own mode setter is what keeps the duplicate
      // from ever being produced; turning it down after it has drawn would
      // only hide the extra, which is exactly what the viewer still sees
      // flicker.
      function mirrorShouldStayHidden(video) {
        var tracks = pageCaptionTracks(video);
        for (var i = 0; i < tracks.length; i++) {
          if (tracks[i].mode === 'showing') { return true; }
        }
        return false;
      }

      function suppressMirrorTrack(video, track) {
        var state = captionState(video);
        if (!track || state.mirrors.indexOf(track) !== -1 ||
            Object.prototype.hasOwnProperty.call(track, 'mode')) { return; }
        var proto = Object.getPrototypeOf(track);
        var descriptor = proto ? Object.getOwnPropertyDescriptor(proto, 'mode') : null;
        if (!descriptor || typeof descriptor.set !== 'function') { return; }
        try {
          Object.defineProperty(track, 'mode', {
            configurable: true,
            get: function () { return descriptor.get.call(this); },
            set: function (value) {
              if (String(value) === 'showing' && mirrorShouldStayHidden(video)) {
                // The page's own caption is the one on screen. The mirror has
                // nothing of its own to add, so it never becomes visible.
                try { descriptor.set.call(this, 'hidden'); } catch (error) {}
                return;
              }
              descriptor.set.call(this, value);
            }
          });
          state.mirrors.push(track);
        } catch (error) {
        }
      }

      function suppressExistingMirrors(video) {
        var mirrors = mirrorTracks(video);
        for (var i = 0; i < mirrors.length; i++) {
          suppressMirrorTrack(video, mirrors[i]);
        }
      }

      // Decides which single track the native player may draw, and applies it.
      //
      // The page's own showing track wins. When no track is showing — a page
      // that paints captions into the DOM and keeps its tracks hidden — the
      // painted sentence picks the language, but only when that sentence
      // changes: a poll must not resurrect captions the viewer switched off in
      // the system player's own 字幕 menu.
      function syncNativeCaptions(video) {
        var state = captionState(video);
        var tracks = pageCaptionTracks(video);

        var painted = paintedCaptionText(video);
        var paintedChanged = painted !== state.painted;
        state.painted = painted;

        var showing = [];
        for (var i = 0; i < tracks.length; i++) {
          if (tracks[i].mode === 'showing') { showing.push(tracks[i]); }
        }

        var chosen = null;
        if (paintedChanged && painted) {
          chosen = matchingTrack(tracks, painted);
        }
        if (!chosen) {
          if (showing.length === 1) {
            chosen = showing[0];
          } else if (showing.length > 1) {
            // The page left more than one language showing. One of them is
            // the caption on screen and the rest are extras the player must
            // not receive; the painted sentence says which one is real.
            chosen = matchingTrack(showing, painted) || showing[0];
          }
        }

        state.chosen = chosen;
        enforceCaptionSelection(video, state);
        suppressExistingMirrors(video);
      }

      function scheduleCaptionSync(video) {
        var state = video.__velaCaptions;
        if (!state) { return; }
        if (state.debounce !== null) { clearTimeout(state.debounce); }
        state.debounce = setTimeout(function () {
          state.debounce = null;
          if (nativeVideo !== video) { return; }
          syncNativeCaptions(video);
        }, 60);
      }

      function startCaptionSync(video) {
        var state = captionState(video);
        var tracks = video && video.textTracks;
        suppressExistingMirrors(video);
        if (tracks && state.changeHandler === null) {
          state.changeHandler = function () { scheduleCaptionSync(video); };
          state.addHandler = function (event) {
            if (event && isMirrorTrack(event.track)) {
              suppressMirrorTrack(video, event.track);
            }
            scheduleCaptionSync(video);
          };
          state.removeHandler = function () { scheduleCaptionSync(video); };
          try {
            tracks.addEventListener('change', state.changeHandler);
            tracks.addEventListener('addtrack', state.addHandler);
            tracks.addEventListener('removetrack', state.removeHandler);
          } catch (error) {
          }
        }
        if (state.timer === null) {
          state.timer = setInterval(function () {
            if (nativeVideo === video && video.isConnected === false) {
              endNative(video);
              return;
            }
            if (nativeVideo !== video) {
              stopCaptionSync(video);
              return;
            }
            syncNativeCaptions(video);
          }, 500);
        }
        syncNativeCaptions(video);
      }

      // The page gets its own modes back. A track whose mode is no longer the
      // one the bridge wrote belongs to the viewer's choice in the system
      // player's menu and is left where they put it, which is how that choice
      // reaches the page after the film ends.
      function stopCaptionSync(video) {
        var state = video.__velaCaptions;
        if (!state) { return; }
        if (state.timer !== null) { clearInterval(state.timer); state.timer = null; }
        if (state.debounce !== null) { clearTimeout(state.debounce); state.debounce = null; }
        if (video && video.textTracks) {
          try {
            if (state.changeHandler) { video.textTracks.removeEventListener('change', state.changeHandler); }
            if (state.addHandler) { video.textTracks.removeEventListener('addtrack', state.addHandler); }
            if (state.removeHandler) { video.textTracks.removeEventListener('removetrack', state.removeHandler); }
          } catch (error) {
          }
        }
        for (var j = 0; j < state.mirrors.length; j++) {
          delete state.mirrors[j].mode;
        }
        for (var i = 0; i < state.original.length; i++) {
          var entry = state.original[i];
          if (entry.set === null) { continue; }
          if (entry.track.mode !== entry.set) { continue; }
          try { entry.track.mode = entry.mode; } catch (error) {}
        }
        video.__velaCaptions = null;
      }

      // Runs before the system player opens, on every road in: the page's
      // requestFullscreen, its own webkitEnterFullscreen / presentation mode,
      // and the system controls. Trimming the page's tracks here is what
      // keeps the presentation from receiving two captions in the first
      // place, rather than repairing the picture after it has drawn.
      function prepareNativeCaptions(video) {
        if (!video) { return; }
        var tracks = pageCaptionTracks(video);
        if (tracks.length === 0 && mirrorTracks(video).length === 0) { return; }
        syncNativeCaptions(video);
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
        if (nativeVideo === video) { return; }
        if (nativeVideo) { stopCaptionSync(nativeVideo); }
        nativeVideo = video;
        nativeStartedAt = Date.now();
        blurPageEditors();
        reportNative(true);
        startCaptionSync(video);
        scheduleNativeVerification(video);
      }

      function endNative(video) {
        if (nativeVideo !== video) { return; }
        nativeVideo = null;
        if (nativeVerifyTimer) {
          clearTimeout(nativeVerifyTimer);
          nativeVerifyTimer = null;
        }
        if (video) {
          stopCaptionSync(video);
        }
        reportNative(false);
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
      }

      document.addEventListener('fullscreenchange', handleElementFullscreenChange, true);
      document.addEventListener('webkitfullscreenchange', handleElementFullscreenChange, true);
    })();
    """
}
