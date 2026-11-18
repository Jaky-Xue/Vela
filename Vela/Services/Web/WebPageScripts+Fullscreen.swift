extension WebPageScripts {
    /// Routes fullscreen requests for a video or its player container to the
    /// iOS media player. Requests that WebKit cannot promote use the original API.
    static let fullscreenBridge = """
    (function () {
      if (window.__velaFullscreenBridgeInstalled) { return; }
      window.__velaFullscreenBridgeInstalled = true;

      function patch(name, returnsPromise) {
        var original = Element.prototype[name];
        if (typeof original !== 'function') { return; }

        Element.prototype[name] = function () {
          if (document.fullscreenEnabled !== false && this instanceof Element) {
            var video = this.tagName === 'VIDEO' ? this : this.querySelector('video');
            if (video && video.webkitSupportsFullscreen !== false &&
                typeof video.webkitEnterFullscreen === 'function') {
              try {
                video.webkitEnterFullscreen();
                return returnsPromise ? Promise.resolve() : undefined;
              } catch (error) {
                // WebKit can reject native fullscreen before media is ready.
              }
            }
          }
          return original.apply(this, arguments);
        };
      }

      patch('requestFullscreen', true);
      patch('webkitRequestFullscreen', false);
    })();
    """
}
