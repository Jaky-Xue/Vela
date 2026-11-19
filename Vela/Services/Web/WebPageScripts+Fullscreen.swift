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
    /// Not every page reaches the system player, and the ones that do not are
    /// where both problems came back for a non-default 网页标识: the site
    /// answers that identifier with its own player and puts that player
    /// fullscreen through the element API. The page is still on screen there,
    /// so the same two rules are applied to it — no keyboard a tap did not ask
    /// for, and no second caption — while a field the viewer can see and did
    /// tap stays usable, which is what a fullscreen player's own comment box
    /// needs. Only videos are treated that way. Element fullscreen of any other
    /// content — an image viewer, a document — falls through untouched,
    /// including its text fields.
    static let fullscreenBridge = """
    (function () {
      if (window.__velaFullscreenBridgeInstalled === true) { return; }
      window.__velaFullscreenBridgeInstalled = true;

      // MARK: - The fullscreen request goes to the system player

      // The video a player container is actually presenting.
      //
      // A container can hold more than one video — a preview, an ad frame, a
      // background loop — and `querySelector('video')` returns whichever the
      // page happened to write first. Handing the system player the wrong
      // element is why a fullscreen request could look like it did nothing:
      // the element that carries the picture is the one with loaded media,
      // and among those the one that covers the container.
      function findVideo(element) {
        if (!element) { return null; }
        if (element.tagName === 'VIDEO') { return element; }
        if (!element.querySelectorAll) { return null; }
        var videos = element.querySelectorAll('video');
        if (videos.length === 0) { return null; }
        if (videos.length === 1) { return videos[0]; }
        var best = videos[0];
        var bestScore = -1;
        for (var i = 0; i < videos.length; i++) {
          var video = videos[i];
          var score = 0;
          if (video.readyState > 0) { score += 1e9; }
          if (video.paused === false || video.currentTime > 0) { score += 1e8; }
          try {
            var rect = video.getBoundingClientRect();
            score += Math.max(0, rect.width) * Math.max(0, rect.height);
          } catch (error) {
          }
          if (score > bestScore) {
            bestScore = score;
            best = video;
          }
        }
        return best;
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

      // A video the page has put fullscreen through the element Fullscreen
      // API. The page stays on screen there, so this is not the system player
      // — but the film still owns the screen, and the page can still raise a
      // keyboard and a second caption over it. It is held like a native
      // presentation for exactly those two jobs.
      var elementFilmVideo = null;

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

      // Which presentation is showing `video`: '' when it owns no screen,
      // 'native' for the system player, 'element' for the page's own
      // fullscreen. The caption rules below depend on the difference — over
      // the system player the page is not visible, while element fullscreen
      // still paints it.
      function filmMode(video) {
        if (!video) { return ''; }
        if (nativeVideo === video && nativeFullscreenActive()) { return 'native'; }
        if (elementFilmVideo === video) { return 'element'; }
        return '';
      }

      function anyFilmActive() {
        return nativeFullscreenActive() || elementFilmVideo !== null;
      }

      // The host keeps the keyboard off the film, including a field in another
      // frame that no page-side script can reach. The two presentations are
      // reported apart: over the system player the page is invisible, so the
      // host may keep dismissing the keyboard for the whole film; an element
      // film keeps the page on screen, and a field the viewer taps there is
      // theirs to type into. One report per state change; repeating it would
      // cost the host a round trip per tap.
      var reportedFilm = 'none';

      function reportFilmActive() {
        var state = nativeFullscreenActive()
            ? 'native'
            : (elementFilmVideo !== null ? 'element' : 'none');
        if (state === reportedFilm) { return; }
        var wasActive = reportedFilm !== 'none';
        reportedFilm = state;
        try {
          var handlers = window.webkit && window.webkit.messageHandlers;
          if (handlers && handlers.\(Handler.mediaFullscreen.rawValue)) {
            handlers.\(Handler.mediaFullscreen.rawValue).postMessage({
              active: state !== 'none',
              native: state === 'native',
              // A film that is still up but has changed kind (the system
              // player taking over the page's fullscreen) is not a new start.
              started: state !== 'none' && !wasActive
            });
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
        // A label is the field's own tap target by convention.
        if (target.tagName === 'LABEL' && target.control === field) { return true; }
        // A wrapper the field merely sits inside is not the field. This was
        // the hole a player's hidden input took a keyboard through: the input
        // sat inside the very control the finger landed on, and the parent
        // rule read that control as the field's own tap target.
        return false;
      }

      // Whether a field could be the one the viewer typed into. A player's
      // hidden input is usually invisible or parked off screen; the guard
      // only lets a focus through for a field the viewer can actually see.
      function fieldIsOnScreen(field) {
        try {
          if (field.getClientRects().length === 0) { return false; }
          var rect = field.getBoundingClientRect();
          if (rect.width < 1 || rect.height < 1) { return false; }
          if (rect.bottom <= 0 || rect.right <= 0) { return false; }
          if (rect.top >= window.innerHeight || rect.left >= window.innerWidth) { return false; }
          var style = window.getComputedStyle(field);
          if (style.visibility === 'hidden' || style.display === 'none') { return false; }
          if (parseFloat(style.opacity) === 0) { return false; }
          return true;
        } catch (error) {
          return false;
        }
      }

      document.addEventListener('focusin', function (event) {
        if (!anyFilmActive()) { return; }
        var field = textFieldInEvent(event);
        if (!field) { return; }
        // Over the system player the page is not on screen at all, so no text
        // field there can be the one being typed into.
        if (nativeFullscreenActive()) {
          try { field.blur(); } catch (error) {}
          return;
        }
        // Element fullscreen keeps the page visible: its controls are on it,
        // and a field the viewer can see and tapped — a player's search box, a
        // comment box in a fullscreen player — is one the page may focus. A
        // field the tap did not land on, or one that is not on screen, is the
        // page typing for the viewer.
        if (tapLandedOn(field) && fieldIsOnScreen(field)) { return; }
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
      function syncCaptions(video, mode) {
        var state = captionState(video);
        var tracks = pageCaptionTracks(video);

        var painted = paintedCaptionText(video);
        var paintedChanged = painted !== state.painted;
        state.painted = painted;

        // Element fullscreen keeps the page on screen. When the page paints
        // its own caption, a text track left showing is drawn by WebKit on top
        // of that paint and the same sentence appears twice; the paint is the
        // caption there, so every track — the mirror included — stands down
        // while the film is up. With no paint, one showing track is the
        // caption and the rules below still apply.
        if (mode === 'element' && painted) {
          state.chosen = null;
          for (var i = 0; i < tracks.length; i++) {
            setCaptionMode(state, tracks[i], 'hidden');
          }
          var mirrors = mirrorTracks(video);
          for (var j = 0; j < mirrors.length; j++) {
            setCaptionMode(state, mirrors[j], 'hidden');
          }
          suppressExistingMirrors(video);
          return;
        }

        var showing = [];
        for (var k = 0; k < tracks.length; k++) {
          if (tracks[k].mode === 'showing') { showing.push(tracks[k]); }
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
          var mode = filmMode(video);
          if (!mode) { return; }
          syncCaptions(video, mode);
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
            // The page can drop its own fullscreen presentation without an
            // event the bridge hears — a player that swaps itself out, a
            // document that is taken down. The state is checked here so a
            // film cannot outlive the screen it owned.
            if (elementFilmVideo === video && nativeVideo !== video) {
              var element = document.fullscreenElement || document.webkitFullscreenElement;
              if (!element || findVideo(element) !== video) {
                endElementFilm();
                return;
              }
            }
            var mode = filmMode(video);
            if (!mode) {
              // The film this sync belonged to is gone.
              if (nativeVideo === video) { endNative(video); }
              if (elementFilmVideo === video) { endElementFilm(); }
              stopCaptionSync(video);
              return;
            }
            syncCaptions(video, mode);
          }, 500);
        }
        syncCaptions(video, filmMode(video) || 'native');
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
        syncCaptions(video, 'native');
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
        if (elementFilmVideo !== null) {
          // The system player has taken the screen from the page's own
          // fullscreen presentation.
          if (elementFilmVideo !== video) { stopCaptionSync(elementFilmVideo); }
          elementFilmVideo = null;
        }
        nativeVideo = video;
        nativeStartedAt = Date.now();
        blurPageEditors();
        reportFilmActive();
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
        reportFilmActive();
        // The system player can close back into a page that is still in its
        // own element fullscreen — the page's player stayed up underneath.
        // That is a film again, not an unguarded page.
        var elementVideo = elementFullscreenVideo();
        if (elementVideo) { beginElementFilm(elementVideo); }
      }

      // The page's own fullscreen. The page is still drawn, but the film owns
      // the screen: it may not take a keyboard the viewer did not ask for and
      // it may not draw a caption twice.
      function beginElementFilm(video) {
        if (!video) { return; }
        if (elementFilmVideo === video) { return; }
        if (elementFilmVideo !== null) { stopCaptionSync(elementFilmVideo); }
        elementFilmVideo = video;
        blurPageEditors();
        reportFilmActive();
        startCaptionSync(video);
      }

      function endElementFilm() {
        var video = elementFilmVideo;
        if (video === null) { return; }
        elementFilmVideo = null;
        stopCaptionSync(video);
        reportFilmActive();
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
        if (!video) {
          // An image viewer, a document: not a film. A native presentation is
          // tracked by its own events and is left alone.
          endElementFilm();
          return;
        }
        beginElementFilm(video);
        blurPageEditors();
      }

      document.addEventListener('fullscreenchange', handleElementFullscreenChange, true);
      document.addEventListener('webkitfullscreenchange', handleElementFullscreenChange, true);
    })();
    """
}
