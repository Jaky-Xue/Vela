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
