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
//  This script deliberately does nothing about captions. A PiP window is drawn
//  from the video element alone, and the caption mirroring that used to live
//  here — fetching subtitle payloads, restating DOM-painted blocks as cues and
//  hiding the page's own caption paint — never produced a reliable small-window
//  subtitle and interfered with pages that paint their own. Per product
//  decision 小窗 does not show subtitles; the page keeps its own captions and
//  WebKit's player is left alone.
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

      function patch(proto, name) {
        var original = proto && proto[name];
        if (typeof original !== 'function') { return; }
        proto[name] = function () {
          var video = findVideo(this);
          if (video && typeof video.webkitEnterFullscreen === 'function') {
            try { video.webkitEnterFullscreen(); } catch (error) {}
            try { document.dispatchEvent(new Event('fullscreenchange')); } catch (error) {}
            return Promise.resolve();
          }
          return original.apply(this, arguments);
        };
      }

      patch(Element.prototype, 'requestFullscreen');
      patch(Element.prototype, 'webkitRequestFullscreen');
    })();
    """
}
