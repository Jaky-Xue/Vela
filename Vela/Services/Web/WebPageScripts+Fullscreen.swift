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
//  Captions in that player, and in picture-in-picture, are a separate problem.
//  A PiP window is rendered by WebKit from the video element alone: an overlay
//  the page paints in its own DOM cannot follow the video into the small
//  window. WebKit can draw only a text track attached to the video. So the
//  order of preference here is:
//
//    1. The site's own caption track, when it is showing and carries cues.
//       WebKit renders it natively, with the site's own timings.
//    2. The site's published caption data, fetched as a real track:
//       YouTube's `captionTracks` payload and Bilibili's subtitle JSON. These
//       keep the real start/end times, so the small window changes sentence
//       when the video does.
//    3. A bridge for players that paint captions into their own DOM and
//       publish nothing (the common case for a custom player). It reads the
//       painted blocks and re-states them as cues, preserving line breaks,
//       alignment and the block's position over the video.
//
//  The old version went straight to (3) for every site and also disabled the
//  page's own caption tracks to avoid a duplicate. That is what made the small
//  window lag: a player that paints from its own track stops painting when the
//  track is disabled, so the bridge kept re-stating the last sentence it had
//  read. Nothing outside this script's own tracks is disabled now.
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

      // Captions a page paints itself, rather than through a text track.
      // Ordered by specificity: the first selector that yields text wins, so a
      // player's outer window cannot duplicate its segments.
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
      // hidden between bridge updates: the player swaps a segment element for
      // every cue. The class is toggled only while the video is in PiP, where
      // the page is still on screen beside the floating window.
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
        // must stop drawing it while the PiP window shows the same track; the
        // presentation window has its own renderer.
        style.textContent +=
          'html.vela-pip-captions-hidden video::-webkit-media-text-track-container' +
          '{display:none!important;}' +
          'html.vela-pip-captions-hidden video::-webkit-media-text-track-display' +
          '{display:none!important;}' +
          'html.vela-pip-captions-hidden video::-webkit-media-text-track-region-container' +
          '{display:none!important;}';
        (document.head || document.documentElement).appendChild(style);
      })();

      function presentationMode(video) {
        if (!video) { return 'inline'; }
        try {
          var mode = video.webkitPresentationMode;
          if (typeof mode === 'string' && mode.length > 0) { return mode; }
          if (video.webkitDisplayingFullscreen) { return 'fullscreen'; }
          if (document.pictureInPictureElement === video) { return 'picture-in-picture'; }
        } catch (_error) {}
        return 'inline';
      }

      function isPresented(video) {
        return presentationMode(video) !== 'inline';
      }

      function isPictureInPicture(video) {
        return presentationMode(video) === 'picture-in-picture';
      }

      function isCaptionKind(kind) {
        return kind === 'subtitles' || kind === 'captions';
      }

      function isOurTrack(video, track) {
        return track === video.__velaRealCaptionTrack ||
          track === video.__velaCaptionMirrorTrack;
      }

      function clearTrackCues(track) {
        if (!track || !track.cues) { return; }
        while (track.cues.length > 0) {
          try { track.removeCue(track.cues[0]); } catch (_error) { break; }
        }
      }

      /// Whether the page itself has a caption track WebKit can render.
      ///
      /// Only a showing track with cues counts: a showing but empty track may
      /// be a player's bookkeeping entry, and a hidden one is a track the
      /// viewer has switched off or a custom player that paints instead.
      function siteCuesAvailable(video) {
        var tracks = video.textTracks;
        if (!tracks) { return false; }
        for (var i = 0; i < tracks.length; i++) {
          var track = tracks[i];
          if (isOurTrack(video, track)) { continue; }
          if (!isCaptionKind(track.kind)) { continue; }
          if (track.mode !== 'showing') { continue; }
          if (track.cues && track.cues.length > 0) { return true; }
        }
        return false;
      }

      function cleanedCaptionText(value) {
        return String(value || '')
          .replace(/\\u200B|\\u200C|\\u200D|\\uFEFF/g, '')
          .replace(/[ \\t]+/g, ' ')
          .replace(/\\s*\\n\\s*/g, '\\n')
          .trim();
      }

      /// The painted caption blocks, one per caption window.
      ///
      /// Segments inside the same player window are joined with a line break
      /// rather than a space, which is how the page draws them and what the
      /// small window has to show.
      function readCaptionBlocks() {
        for (var s = 0; s < captionSelectors.length; s++) {
          var nodes = document.querySelectorAll(captionSelectors[s]);
          var blocks = [];
          var hosts = [];
          for (var i = 0; i < nodes.length; i++) {
            var node = nodes[i];
            var text = cleanedCaptionText(node.innerText || node.textContent || '');
            if (!text) { continue; }
            var host = node;
            try { if (node.closest) { host = node.closest('.caption-window') || node; } } catch (_error) {}
            var rect = null;
            try { rect = node.getBoundingClientRect(); } catch (_error2) {}
            var index = hosts.indexOf(host);
            if (index === -1) {
              hosts.push(host);
              blocks.push({ text: text, host: host, rect: rect });
            } else {
              blocks[index].text += '\\n' + text;
            }
          }
          if (blocks.length) { return blocks; }
        }
        return [];
      }

      /// Where the page put the block, as cue settings.
      ///
      /// Percentages of the video box, which is what VTTCue's non-snapped
      /// position expects. The page's own text-align decides the cue's
      /// alignment, so a left-aligned lower-third stays a left-aligned
      /// lower-third in the small window.
      function cueSettingsFor(video, block) {
        var settings = {
          line: 'auto',
          size: 100,
          position: 50,
          align: 'center',
          positionAlign: 'center',
          snapToLines: true
        };
        try {
          var videoRect = video.getBoundingClientRect();
          var rect = block.rect;
          if (!videoRect || !rect || videoRect.width <= 0 || videoRect.height <= 0) {
            return settings;
          }
          if (rect.height > 0) {
            var line = ((rect.top - videoRect.top) / videoRect.height) * 100;
            if (isFinite(line)) {
              settings.line = Math.max(0, Math.min(98, line));
              settings.snapToLines = false;
            }
          }
          if (rect.width > 0) {
            var width = (rect.width / videoRect.width) * 100;
            if (isFinite(width)) {
              settings.size = Math.max(10, Math.min(100, width));
            }
            var position = ((rect.left + rect.width / 2 - videoRect.left) / videoRect.width) * 100;
            if (isFinite(position)) {
              settings.position = Math.max(0, Math.min(100, position));
            }
          }
          var style = null;
          try { style = getComputedStyle(block.host); } catch (_error) {}
          var textAlign = style && style.textAlign ? String(style.textAlign).toLowerCase() : '';
          if (textAlign === 'left' || textAlign === 'start') {
            settings.align = 'left';
            settings.positionAlign = 'line-left';
          } else if (textAlign === 'right' || textAlign === 'end') {
            settings.align = 'right';
            settings.positionAlign = 'line-right';
          }
        } catch (_error3) {}
        return settings;
      }

      function cueForBlock(video, block) {
        var settings = cueSettingsFor(video, block);
        var cue = new VTTCue(0, 10e7, block.text);
        if (settings.snapToLines === false) { cue.snapToLines = false; }
        cue.line = settings.line;
        cue.size = settings.size;
        cue.position = settings.position;
        cue.align = settings.align;
        cue.positionAlign = settings.positionAlign;
        return cue;
      }

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
        document.documentElement.classList.add('vela-pip-captions-hidden');
      }

      function restorePaintedCaptions(video) {
        var nodes = video.__velaHiddenCaptions;
        video.__velaHiddenCaptions = null;
        if (!nodes) { return; }
        for (var i = 0; i < nodes.length; i++) {
          nodes[i].__velaCaptionHidden = false;
          nodes[i].style.opacity = nodes[i].__velaCaptionOpacity || '';
          nodes[i].style.pointerEvents = '';
        }
      }

      // WebKit's own YouTube and CNN quirks mirror the page's captions into a
      // `forced` track of their own. It is a mirror of the same paint, not the
      // site's data, so it is the one track that is safe to stand down while
      // ours carries the sentence; every other track is left exactly as the
      // page set it.
      function suppressWebKitMirrorTracks(video, activeTrack, hasText) {
        var tracks = video.textTracks;
        if (!tracks) { return; }
        if (!video.__velaSuppressedMirrorTracks) { video.__velaSuppressedMirrorTracks = []; }
        for (var i = 0; i < tracks.length; i++) {
          var track = tracks[i];
          if (track === activeTrack || isOurTrack(video, track)) { continue; }
          if (track.kind !== 'forced') { continue; }
          var label = String(track.label || '');
          if (label !== 'YouTube Captions' && label !== 'CNN Captions') { continue; }
          if (!hasText || track.mode === 'disabled') { continue; }
          video.__velaSuppressedMirrorTracks.push({ track: track, mode: track.mode });
          try { track.mode = 'disabled'; } catch (_error) {}
        }
      }

      function restoreSuppressedMirrorTracks(video) {
        var saved = video.__velaSuppressedMirrorTracks;
        video.__velaSuppressedMirrorTracks = null;
        if (!saved) { return; }
        for (var i = 0; i < saved.length; i++) {
          try { saved[i].track.mode = saved[i].mode; } catch (_error) {}
        }
      }

      // MARK: Real caption data

      function decodeCaptionEntities(text) {
        var area = document.createElement('textarea');
        area.innerHTML = String(text || '');
        return area.value;
      }

      function stripCaptionMarkup(text) {
        return decodeCaptionEntities(String(text || '').replace(/<[^>]*>/g, ''))
          .replace(/[ \\t]+/g, ' ')
          .replace(/\\s*\\n\\s*/g, '\\n')
          .trim();
      }

      function parseTimecode(value) {
        var parts = String(value || '0').replace(/,/g, '.').split(':');
        var seconds = 0;
        for (var i = 0; i < parts.length; i++) {
          seconds = seconds * 60 + (parseFloat(parts[i]) || 0);
        }
        return seconds;
      }

      function parseWebVTT(text) {
        var lines = String(text || '').split(/\\r?\\n/);
        var cues = [];
        var current = null;
        for (var i = 0; i < lines.length; i++) {
          var line = lines[i];
          if (line.indexOf('-->') !== -1) {
            var pieces = line.split('-->');
            var startText = pieces[0].replace(/^\\s+|\\s+$/g, '').split(' ')[0];
            var endText = pieces[1].replace(/^\\s+|\\s+$/g, '').split(' ')[0];
            current = { start: parseTimecode(startText), end: parseTimecode(endText), lines: [] };
            cues.push(current);
            continue;
          }
          if (!current) { continue; }
          if (line.replace(/\\s+/g, '') === '') { current = null; continue; }
          current.lines.push(line);
        }
        var out = [];
        for (var j = 0; j < cues.length; j++) {
          var value = stripCaptionMarkup(cues[j].lines.join('\\n'));
          if (value) { out.push({ start: cues[j].start, end: cues[j].end, text: value }); }
        }
        return out;
      }

      function parseXMLCaptions(text) {
        try {
          var doc = new DOMParser().parseFromString(String(text || ''), 'text/xml');
          var nodes = doc.getElementsByTagName('text');
          var out = [];
          for (var i = 0; i < nodes.length; i++) {
            var node = nodes[i];
            var start = parseFloat(node.getAttribute('start') || '0');
            var duration = parseFloat(node.getAttribute('dur') || '0');
            var value = stripCaptionMarkup(node.textContent || '');
            if (value) { out.push({ start: start, end: start + duration, text: value }); }
          }
          return out;
        } catch (_error) { return []; }
      }

      function parseJSON3Captions(text) {
        try {
          var json = JSON.parse(String(text || '{}'));
          var events = json && json.events ? json.events : [];
          var out = [];
          for (var i = 0; i < events.length; i++) {
            var event = events[i];
            if (!event || !event.segs) { continue; }
            var value = '';
            for (var j = 0; j < event.segs.length; j++) {
              value += event.segs[j].utf8 || '';
            }
            value = stripCaptionMarkup(value);
            if (!value) { continue; }
            var start = (event.tStartMs || 0) / 1000;
            var duration = (event.dDurationMs || 0) / 1000;
            out.push({ start: start, end: start + duration, text: value });
          }
          return out;
        } catch (_error2) { return []; }
      }

      function parseCaptionPayload(text) {
        if (!text) { return []; }
        if (text.indexOf('WEBVTT') === 0 || text.indexOf('-->') !== -1) {
          return parseWebVTT(text);
        }
        if (text.indexOf('<transcript') !== -1 || text.indexOf('<text') !== -1) {
          return parseXMLCaptions(text);
        }
        if (text.charAt(0) === '{' || text.charAt(0) === '[') {
          return parseJSON3Captions(text);
        }
        return [];
      }

      function fetchCaptionPayload(url, done) {
        try {
          fetch(url, { credentials: 'include' }).then(function (response) {
            if (!response.ok) { throw new Error('caption http'); }
            return response.text();
          }).then(function (text) {
            done(parseCaptionPayload(text));
          }).catch(function () { done(null); });
        } catch (_error) { done(null); }
      }

      function installRealCues(video, cues, label, language) {
        if (!video.addTextTrack || !cues || !cues.length) { return false; }
        var track = video.__velaRealCaptionTrack;
        if (!track) {
          try { track = video.addTextTrack('subtitles', label || '字幕', language || 'und'); }
          catch (_error) { return false; }
          video.__velaRealCaptionTrack = track;
        }
        clearTrackCues(track);
        var added = 0;
        for (var i = 0; i < cues.length; i++) {
          var value = cues[i];
          if (!value || !value.text || !(value.end > value.start)) { continue; }
          try {
            track.addCue(new VTTCue(value.start, value.end, value.text));
            added += 1;
          } catch (_error2) {}
        }
        if (!added) { return false; }
        try { track.mode = isPresented(video) ? 'showing' : 'hidden'; } catch (_error3) {}
        return true;
      }

      function youtubePlayer() {
        if (!/(^|\\.)youtube\\.com$/.test(location.hostname)) { return null; }
        var byId = document.getElementById('movie_player');
        if (byId && typeof byId.getPlayerResponse === 'function') { return byId; }
        var players = document.querySelectorAll('.html5-video-player');
        for (var i = 0; i < players.length; i++) {
          if (typeof players[i].getPlayerResponse === 'function') { return players[i]; }
        }
        return null;
      }

      function youtubeCaptionsOn(player) {
        try {
          if (player && typeof player.isSubtitlesOn === 'function') {
            return !!player.isSubtitlesOn();
          }
          var current = player && player.getOption ? player.getOption('captions', 'track') : null;
          return !!(current && (current.languageCode || current.vss_id));
        } catch (_error) { return false; }
      }

      function youtubeTrackInfo(player) {
        var response = null;
        try { response = player.getPlayerResponse(); } catch (_error) {}
        var captions = response && response.captions;
        var renderer = captions && captions.playerCaptionsTracklistRenderer;
        var list = renderer && renderer.captionTracks;
        if (!list || !list.length) { return null; }

        var current = null;
        try { current = player.getOption ? player.getOption('captions', 'track') : null; } catch (_error2) {}
        if (current && current.languageCode) {
          for (var i = 0; i < list.length; i++) {
            if (list[i].languageCode === current.languageCode &&
                String(list[i].kind || '') === String(current.kind || '')) {
              return list[i];
            }
          }
          for (var j = 0; j < list.length; j++) {
            if (list[j].languageCode === current.languageCode) { return list[j]; }
          }
        }
        for (var k = 0; k < list.length; k++) {
          if (list[k].kind !== 'asr') { return list[k]; }
        }
        return list[0];
      }

      function youtubeTrackLabel(info) {
        try {
          if (info.name && info.name.simpleText) { return info.name.simpleText; }
          if (info.name && info.name.runs && info.name.runs.length) {
            return info.name.runs[0].text;
          }
        } catch (_error) {}
        return '字幕';
      }

      function loadYouTubeCaptions(video, player, done) {
        var info = youtubeTrackInfo(player);
        if (!info || !info.baseUrl) { done(false); return; }
        var base = info.baseUrl;
        var label = youtubeTrackLabel(info);
        var language = info.languageCode || 'und';
        fetchCaptionPayload(base + '&fmt=vtt', function (cues) {
          if (cues && cues.length) {
            done(installRealCues(video, cues, label, language));
            return;
          }
          fetchCaptionPayload(base + '&fmt=json3', function (jsonCues) {
            if (jsonCues && jsonCues.length) {
              done(installRealCues(video, jsonCues, label, language));
              return;
            }
            done(false);
          });
        });
      }

      function bilibiliCaptionList() {
        if (!/(^|\\.)bilibili\\.com$/.test(location.hostname)) { return null; }
        try {
          var state = window.__INITIAL_STATE__;
          var list = state && state.videoData && state.videoData.subtitle &&
            state.videoData.subtitle.list;
          return list && list.length ? list : null;
        } catch (_error) { return null; }
      }

      function bilibiliCaptionsVisible() {
        return !!document.querySelector(
          '.bpx-player-subtitle-panel-text, .bpx-player-video-subtitle'
        );
      }

      function loadBilibiliCaptions(video, done) {
        var list = bilibiliCaptionList();
        if (!list || !list.length) { done(false); return; }
        var chosen = list[0];
        var url = String(chosen.subtitle_url || '');
        if (url.indexOf('//') === 0) { url = 'https:' + url; }
        if (!url) { done(false); return; }
        try {
          fetch(url).then(function (response) {
            if (!response.ok) { throw new Error('caption http'); }
            return response.json();
          }).then(function (json) {
            var body = json && json.body ? json.body : [];
            var cues = [];
            for (var i = 0; i < body.length; i++) {
              var item = body[i];
              if (!item || !item.content) { continue; }
              var start = parseFloat(item.from) || 0;
              var end = parseFloat(item.to) || (start + 3);
              if (end > start) { cues.push({ start: start, end: end, text: item.content }); }
            }
            done(installRealCues(
              video,
              cues,
              chosen.lan_doc || '字幕',
              chosen.lan || 'und'
            ));
          }).catch(function () { done(false); });
        } catch (_error) { done(false); }
      }

      function tryLoadRealCaptions(video, done) {
        var player = youtubePlayer();
        if (player) {
          if (!youtubeCaptionsOn(player)) { done(false); return; }
          loadYouTubeCaptions(video, player, done);
          return;
        }
        if (bilibiliCaptionList() && bilibiliCaptionsVisible()) {
          loadBilibiliCaptions(video, done);
          return;
        }
        done(false);
      }

      // MARK: Bridge for DOM-painted captions

      function bridgeSync(video) {
        if (!isPresented(video)) { stopCaptionBridge(video); return; }
        if (!video.isConnected) { stopPresentation(video); return; }
        if (siteCuesAvailable(video)) { stopCaptionBridge(video); return; }

        var mirror = video.__velaCaptionMirrorTrack;
        if (!mirror) { return; }

        if (isPictureInPicture(video)) {
          hidePaintedCaptions(video);
        } else {
          restorePaintedCaptions(video);
          document.documentElement.classList.remove('vela-pip-captions-hidden');
        }

        var blocks = readCaptionBlocks();
        var signature = '';
        for (var i = 0; i < blocks.length; i++) {
          var settings = cueSettingsFor(video, blocks[i]);
          signature += blocks[i].text + '@' + settings.line + ',' +
            settings.position + ',' + settings.align + ';';
        }

        if (signature !== video.__velaCaptionSignature) {
          video.__velaCaptionSignature = signature;
          clearTrackCues(mirror);
          for (var j = 0; j < blocks.length; j++) {
            try { mirror.addCue(cueForBlock(video, blocks[j])); } catch (_error) {}
          }
        }

        try { mirror.mode = blocks.length ? 'showing' : 'hidden'; } catch (_error2) {}
        if (blocks.length) {
          suppressWebKitMirrorTracks(video, mirror, true);
        } else {
          restoreSuppressedMirrorTracks(video);
        }
      }

      function startCaptionBridge(video) {
        if (video.__velaCaptionTimer) { return; }
        var mirror = video.__velaCaptionMirrorTrack;
        if (!mirror) {
          if (typeof video.addTextTrack !== 'function') { return; }
          try { mirror = video.addTextTrack('forced', '字幕', 'und'); }
          catch (_error) {
            try { mirror = video.addTextTrack('captions', '字幕', 'und'); }
            catch (_error2) { return; }
          }
          video.__velaCaptionMirrorTrack = mirror;
        }
        video.__velaCaptionSignature = null;

        var scheduled = false;
        function schedule() {
          if (scheduled) { return; }
          scheduled = true;
          setTimeout(function () { scheduled = false; bridgeSync(video); }, 80);
        }

        try {
          if (window.MutationObserver) {
            video.__velaCaptionObserver = new MutationObserver(schedule);
            video.__velaCaptionObserver.observe(document.body || document.documentElement, {
              subtree: true,
              childList: true,
              characterData: true
            });
          }
        } catch (_error3) {}

        // The observer is the fresh path; the interval is the safety net for a
        // player that swaps the whole caption container without a mutation the
        // observer is attached to.
        video.__velaCaptionTimer = setInterval(function () { bridgeSync(video); }, 300);
        bridgeSync(video);
      }

      function stopCaptionBridge(video) {
        if (video.__velaCaptionTimer) {
          clearInterval(video.__velaCaptionTimer);
          video.__velaCaptionTimer = null;
        }
        if (video.__velaCaptionObserver) {
          try { video.__velaCaptionObserver.disconnect(); } catch (_error) {}
          video.__velaCaptionObserver = null;
        }
        // Suppression belongs to the presentation, not to the bridge: while a
        // real track of ours is showing, stopping the bridge must not bring
        // WebKit's mirror track back beside it.
        var mirror = video.__velaCaptionMirrorTrack;
        if (mirror) {
          clearTrackCues(mirror);
          try { mirror.mode = 'hidden'; } catch (_error2) {}
        }
        video.__velaCaptionSignature = null;
      }

      // MARK: Presentation lifecycle

      function evaluateCaptions(video) {
        if (!isPresented(video)) { return; }

        if (isPictureInPicture(video)) {
          document.documentElement.classList.add('vela-pip-captions-hidden');
        } else {
          document.documentElement.classList.remove('vela-pip-captions-hidden');
        }

        // Captions the viewer switched off stay off. No site track is turned
        // on here, and the bridge has nothing to read while the page paints
        // nothing.
        if (siteCuesAvailable(video)) {
          // The page's own track is what the small window should draw now.
          // Our track would duplicate it, and WebKit's own mirror tracks are
          // allowed back because nothing of ours carries the sentence.
          var ours = video.__velaRealCaptionTrack;
          if (ours) {
            try { ours.mode = 'hidden'; } catch (_error0) {}
          }
          stopCaptionBridge(video);
          restoreSuppressedMirrorTracks(video);
          return;
        }

        var player = youtubePlayer();
        if (player && !youtubeCaptionsOn(player)) {
          if (video.__velaRealCaptionTrack) {
            try { video.__velaRealCaptionTrack.mode = 'hidden'; } catch (_error) {}
          }
          stopCaptionBridge(video);
          return;
        }

        var real = video.__velaRealCaptionTrack;
        if (real && real.cues && real.cues.length > 0) {
          try { real.mode = 'showing'; } catch (_error2) {}
          suppressWebKitMirrorTracks(video, real, true);
          stopCaptionBridge(video);
          return;
        }

        if (video.__velaRealLoading) { return; }
        // A failed fetch has to fall back to the bridge once, not retry on
        // every poll tick.
        if (video.__velaRealAttemptAt &&
            Date.now() - video.__velaRealAttemptAt < 4000) {
          startCaptionBridge(video);
          return;
        }

        video.__velaRealLoading = true;
        video.__velaRealAttemptAt = Date.now();
        tryLoadRealCaptions(video, function (loaded) {
          video.__velaRealLoading = false;
          if (!isPresented(video)) { return; }
          if (loaded) {
            var track = video.__velaRealCaptionTrack;
            if (track) {
              try { track.mode = 'showing'; } catch (_error3) {}
              suppressWebKitMirrorTracks(video, track, true);
            }
            stopCaptionBridge(video);
            return;
          }
          startCaptionBridge(video);
        });
      }

      function startPresentation(video) {
        armVideo(video);
        if (!isPresented(video)) { return; }
        evaluateCaptions(video);
      }

      function stopPresentation(video) {
        stopCaptionBridge(video);
        var real = video.__velaRealCaptionTrack;
        if (real) {
          try { real.mode = 'hidden'; } catch (_error) {}
        }
        restoreSuppressedMirrorTracks(video);
        restorePaintedCaptions(video);
        document.documentElement.classList.remove('vela-pip-captions-hidden');
      }

      function armVideo(video) {
        if (!video || video.__velaPresentationListening) { return; }
        video.__velaPresentationListening = true;
        video.addEventListener('webkitpresentationmodechanged', function () {
          if (isPresented(video)) { startPresentation(video); }
          else { stopPresentation(video); }
        });
        video.addEventListener('webkitbeginfullscreen', function () {
          startPresentation(video);
        });
        video.addEventListener('webkitendfullscreen', function () {
          stopPresentation(video);
        });
        video.addEventListener('emptied', function () {
          stopPresentation(video);
          video.__velaRealCaptionTrack = null;
        });
      }

      // MARK: Fullscreen API redirection

      function patch(proto, name) {
        var original = proto && proto[name];
        if (typeof original !== 'function') { return; }
        proto[name] = function () {
          var video = findVideo(this);
          if (video && typeof video.webkitEnterFullscreen === 'function') {
            armVideo(video);
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
          armVideo(this);
          return nativeEnterFullscreen.apply(this, arguments);
        };
      }
      if (videoProto && typeof videoProto.webkitSetPresentationMode === 'function') {
        var nativeSetPresentationMode = videoProto.webkitSetPresentationMode;
        videoProto.webkitSetPresentationMode = function (mode) {
          if (mode === 'fullscreen' || mode === 'picture-in-picture') {
            armVideo(this);
          }
          return nativeSetPresentationMode.apply(this, arguments);
        };
      }

      // The system PiP button is native; it does not call any patched method.
      // Capture the mode change on the document so a presentation started by
      // the system controls enters the same path.
      document.addEventListener('webkitpresentationmodechanged', function (event) {
        var video = event.target;
        if (!video || video.tagName !== 'VIDEO') { return; }
        armVideo(video);
        if (isPresented(video)) { startPresentation(video); }
        else { stopPresentation(video); }
      }, true);

      // The standard PiP property is the fallback signal for a presentation
      // started by the system controls, which does not always surface as a
      // `webkitPresentationMode` change in the page's world.
      var lastPictureInPictureVideo = null;
      setInterval(function () {
        var pip = document.pictureInPictureElement;
        if (pip) {
          armVideo(pip);
          if (pip !== lastPictureInPictureVideo) {
            lastPictureInPictureVideo = pip;
            startPresentation(pip);
          } else if (!pip.__velaCaptionTimer &&
                     !(pip.__velaRealCaptionTrack &&
                       pip.__velaRealCaptionTrack.cues &&
                       pip.__velaRealCaptionTrack.cues.length > 0) &&
                     !siteCuesAvailable(pip)) {
            // A player can turn a track on, or start painting, after the
            // presentation opened; this keeps the decision from being frozen
            // at the moment PiP was entered.
            evaluateCaptions(pip);
          }
        } else if (lastPictureInPictureVideo) {
          var previous = lastPictureInPictureVideo;
          lastPictureInPictureVideo = null;
          stopPresentation(previous);
        }
      }, 500);
    })();
    """
}
