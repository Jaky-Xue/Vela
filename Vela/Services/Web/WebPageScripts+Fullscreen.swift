//
//  WebPageScripts+Fullscreen.swift
//  Vela
//
//  The fullscreen bridge: video fullscreen goes to Apple's system player.
//
//  Kept apart from the scripts it is injected with because it is the one
//  script whose job is to *decline* to draw: a page's Fullscreen API request on
//  a video-bearing element is redirected to the video's own native fullscreen,
//  so WebKit presents the system player rather than an app-drawn one.
//

import Foundation
import WebKit

extension WebPageScripts {
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

      // A stylesheet is the only way to keep newly created caption nodes
      // hidden between mirror ticks: the player swaps a segment element for
      // every cue, and a per-node opacity would lag one interval behind each
      // new sentence. The class is toggled only while the video is in PiP.
      (function installPictureInPictureStyle() {
        if (document.getElementById('vela-pip-caption-style')) { return; }
        var style = document.createElement('style');
        style.id = 'vela-pip-caption-style';
        var selectors = [
          '.ytp-caption-window-container',
          '.ytp-caption-segment',
          '.caption-window',
          '.captions-text',
          '.bpx-player-subtitle-panel',
          '.bpx-player-video-subtitle',
          '.vjs-text-track-display',
          '.jw-text-track-cue',
          '.plyr__captions',
          '.dplayer-subtitle',
          '.art-subtitle'
        ];
        style.textContent = selectors.map(function (selector) {
          return 'html.vela-pip-captions-hidden ' + selector +
            '{opacity:0!important;pointer-events:none!important;}';
        }).join('');
        // WebKit renders a native text track inside the video element's own
        // shadow tree, which no page selector can reach. The inline video
        // must stop drawing it while the same track is what the PiP window
        // shows; the presentation window has its own renderer.
        style.textContent +=
          'html.vela-pip-captions-hidden video::-webkit-media-text-track-container' +
          '{display:none!important;}' +
          'html.vela-pip-captions-hidden video::-webkit-media-text-track-display' +
          '{display:none!important;}' +
          'html.vela-pip-captions-hidden video::-webkit-media-text-track-region-container' +
          '{display:none!important;}';
        (document.head || document.documentElement).appendChild(style);
      })();

      function isPictureInPicture(video) {
        return video.webkitPresentationMode === 'picture-in-picture' ||
          document.pictureInPictureElement === video;
      }

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

      // Picture-in-picture keeps the page on screen. The player's own caption
      // paint would stay at the video's old position while the native window
      // draws the mirrored cue, which is the sentence twice — once inside the
      // floating window and once in an empty rectangle where the video used to
      // be. Hide the painted layer for the length of the PiP presentation and
      // restore it when the video returns inline.
      //
      // Opacity rather than `visibility` or `display`: the mirror still has to
      // read the same text while it is hidden, and `innerText` survives an
      // opacity change.
      function hidePaintedCaptions(video) {
        if (!video.__velaHiddenCaptions) { video.__velaHiddenCaptions = []; }
        for (var s = 0; s < captionSelectors.length; s++) {
          var nodes = document.querySelectorAll(captionSelectors[s]);
          for (var i = 0; i < nodes.length; i++) {
            var node = nodes[i];
            if (node.__velaCaptionHidden) { continue; }
            node.__velaCaptionHidden = true;
            node.__velaCaptionOpacity = node.style.opacity;
            node.style.opacity = '0';
            node.style.pointerEvents = 'none';
            video.__velaHiddenCaptions.push(node);
          }
        }
      }

      function restorePaintedCaptions(video) {
        var nodes = video.__velaHiddenCaptions;
        if (!nodes) { return; }
        video.__velaHiddenCaptions = null;
        for (var i = 0; i < nodes.length; i++) {
          var node = nodes[i];
          node.__velaCaptionHidden = false;
          node.style.opacity = node.__velaCaptionOpacity || '';
          node.style.pointerEvents = '';
        }
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
        restorePaintedCaptions(video);
        document.documentElement.classList.remove('vela-pip-captions-hidden');
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
          if (isPictureInPicture(video)) {
            // Hiding the whole caption layer, not only the nodes the mirror
            // read: the player creates a new segment for the next cue, and the
            // stylesheet covers it before the next tick.
            document.documentElement.classList.add('vela-pip-captions-hidden');
            hidePaintedCaptions(video);
          } else {
            document.documentElement.classList.remove('vela-pip-captions-hidden');
            restorePaintedCaptions(video);
          }
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
          if (mode === 'fullscreen' || mode === 'picture-in-picture') {
            exposeSubtitlesToNativePlayer(this);
          }
          return nativeSetPresentationMode.apply(this, arguments);
        };
      }

      // The system PiP button is native; it does not call any of the patched
      // methods. Capture the mode change on the document so the mirror and the
      // page-overlay hide still start. The inline direction is already handled
      // by the per-video listener registered in exposeSubtitlesToNativePlayer.
      document.addEventListener('webkitpresentationmodechanged', function (event) {
        var video = event.target;
        if (!video || video.tagName !== 'VIDEO') { return; }
        if (video.webkitPresentationMode === 'picture-in-picture') {
          exposeSubtitlesToNativePlayer(video);
        }
      }, true);

      // The standard PiP property is the fallback signal for a presentation
      // started by the system controls, which does not always surface as a
      // webkitPresentationMode change in the page's world.
      var lastPictureInPictureVideo = null;
      setInterval(function () {
        var pip = document.pictureInPictureElement;
        if (pip) {
          document.documentElement.classList.add('vela-pip-captions-hidden');
          if (pip !== lastPictureInPictureVideo) {
            lastPictureInPictureVideo = pip;
            exposeSubtitlesToNativePlayer(pip);
          }
        } else if (lastPictureInPictureVideo) {
          lastPictureInPictureVideo = null;
          document.documentElement.classList.remove('vela-pip-captions-hidden');
        }
      }, 250);
    })();
    """
}
