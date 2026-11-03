//
//  WebPageScripts+Zoom.swift
//  Vela
//
//  The viewport override behind 强制网页缩放. The switch does not choose a
//  factor; it removes the page's own zoom lock so the standard pinch gesture
//  can scale it.
//

import Foundation

extension WebPageScripts {
    public static func gestureZoomViewportScript(enabled: Bool) -> String {
        let flag = enabled ? "true" : "false"
        return """
        (function () {
          try {
            var metas = document.querySelectorAll('meta[name="viewport"]');
            for (var i = 0; i < metas.length; i++) {
              var meta = metas[i];
              if (meta.__velaOriginalViewport === undefined) {
                meta.__velaOriginalViewport = meta.getAttribute('content') || '';
              }
              if (\(flag)) {
                var content = meta.__velaOriginalViewport || 'width=device-width, initial-scale=1';
                content = content
                  .replace(/\\s*user-scalable\\s*=\\s*no/ig, '')
                  .replace(/\\s*maximum-scale\\s*=\\s*[0-9.]+/ig, '')
                  .replace(/\\s*minimum-scale\\s*=\\s*[0-9.]+/ig, '');
                if (content.indexOf('user-scalable=yes') < 0) {
                  content += ', user-scalable=yes, maximum-scale=3, minimum-scale=0.5';
                }
                meta.setAttribute('content', content);
              } else {
                meta.setAttribute('content', meta.__velaOriginalViewport || '');
              }
            }
          } catch (_error) {
          }
        })();
        """
    }
}

extension WebPageScripts {
    /// The desktop layout floor for 桌面版.
    ///
    /// A desktop identifier alone does not give a narrow tablet a desktop
    /// layout: a site that branches on `width=device-width` sees 768–1024
    /// CSS pixels and picks its tablet branch, whatever its user agent says.
    /// This raises such a viewport to 1200 CSS pixels and scales it back to
    /// the screen, which is the shape Android browsers' 桌面版 uses — the
    /// page lays out as it would in a 1200-pixel desktop window, fitted.
    ///
    /// Only a `width=device-width` declaration is rewritten. A site that
    /// named its own width (`width=980`) already made a desktop choice, and a
    /// page with no meta keeps WebKit's 980-pixel default. The zoom flags are
    /// replaced with `user-scalable=yes`, so 强制网页缩放 still works.
    public static let desktopViewportScript = """
    (function () {
      if (window.__velaDesktopViewportInstalled === true) { return; }
      window.__velaDesktopViewportInstalled = true;

      function apply() {
        try {
          // The window's CSS width, not the screen's: a Stage Manager window
          // can be half the screen, and a layout scaled to the screen would
          // overflow it. Only a page that declares width=device-width reaches
          // this line, so innerWidth already reports the window.
          var device = Math.round(window.innerWidth || 0);
          if (!device) {
            device = Math.round((window.screen && window.screen.width) || 0);
          }
          if (device <= 0) { return; }

          var target = Math.max(1200, device);
          if (target <= device) { return; }
          var scale = (device / target).toFixed(4);

          var metas = document.querySelectorAll('meta[name="viewport"]');
          for (var i = 0; i < metas.length; i++) {
            var meta = metas[i];
            var content = meta.getAttribute('content') || '';
            if (!/width\\s*=\\s*device-width/i.test(content)) { continue; }
            meta.setAttribute(
              'content',
              'width=' + target + ', initial-scale=' + scale + ', user-scalable=yes'
            );
          }
        } catch (_error) {}
      }

      apply();
      if (document.readyState === 'loading') {
        document.addEventListener('DOMContentLoaded', apply, { once: true });
      }
      window.addEventListener('load', apply, { once: true });
    })();
    """
}
