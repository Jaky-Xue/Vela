//
//  WebPageScripts.swift
//  Vela
//
//  The document-start and document-end scripts injected into every page.
//
//  These exist because a `WKWebView` reports a navigation only when the document
//  changes. A single-page app calling `history.pushState` changes the URL without
//  ever navigating, so without the bridge below the address bar keeps showing the
//  URL the user arrived on, and back and forward stop reflecting where they
//  actually are.
//

import Foundation
import WebKit

public enum WebPageScripts {
    /// Message handler names. One handler with a `type` field would be smaller,
    /// but separate names let a delegate method be a `switch`-free single case,
    /// which keeps the coordinator readable.
    public enum Handler: String, CaseIterable {
        case historyApi = "velaHistoryApi"
        case scroll = "velaScroll"
        case pageMetrics = "velaPageMetrics"
        case elementPick = "velaElementPick"
        case console = "velaConsole"
        case userScript = "velaUserScript"
        /// Page-side permission questions from the location, clipboard and
        /// notification bridge. Camera, microphone and motion arrive through
        /// `WKUIDelegate` instead.
        case permissionAsk = "velaPermissionAsk"
    }

    // MARK: - Native-looking wrappers

    /// The page-side helper every bridge in this file wraps its replacements
    /// with.
    ///
    /// A bridge replaces a function the page can read back: `history.pushState`,
    /// `navigator.geolocation.getCurrentPosition`, `navigator.clipboard.readText`,
    /// `Notification.requestPermission`, and the accessors that carry a spoofed
    /// identifier. A wrapper's source is visible through `toString()`, and a
    /// site that finds JavaScript source where the platform's `[native code]`
    /// belongs reads the browser as tampered with. That is not a theoretical
    /// concern: it is what the bot check in front of a protected site
    /// (Cloudflare's challenge on grok.com and chatgpt.com is the case this was
    /// reported against) does with the answer, and a page that fails it can sit
    /// on an interstitial that never clears while the same page loads in a
    /// browser that injects nothing.
    ///
    /// Marking a wrapper changes nothing a page can do with the function: the
    /// call, its arguments and its result are identical. It only keeps Vela's
    /// own plumbing from being mistaken for interference with the page.
    /// `velaInstall` places the wrapper the way the platform places its own —
    /// own, non-enumerable, configurable — so a page checking for an own
    /// property (`history.hasOwnProperty('pushState')`) reads what the platform
    /// would have answered.
    static let markNativeHelper = """
      function velaNative(fn, name) {
        try {
          Object.defineProperty(fn, 'name', { value: name, configurable: true });
        } catch (_error) {}
        try {
          Object.defineProperty(fn, 'toString', {
            value: function () { return 'function ' + name + '() { [native code] }'; },
            configurable: true,
            writable: true
          });
        } catch (_error) {}
        return fn;
      }

      function velaInstall(owner, name, value) {
        try {
          Object.defineProperty(owner, name, {
            value: value, configurable: true, writable: true, enumerable: false
          });
        } catch (_error) {
          try { owner[name] = value; } catch (_error2) {}
        }
      }
    """

    // MARK: - History API bridge

    /// Reports `pushState` / `replaceState` / `popstate` / `hashchange` to the
    /// host, with a "only report a real change" guard: a `replaceState` that
    /// keeps the same URL must not produce an event, or an SPA that normalises
    /// its URL on every render would fire a spurious navigation on each frame.
    public static let historyApiBridge = """
    (function () {
      if (window.__velaHistoryApiBridgeInstalled === true) { return; }
      window.__velaHistoryApiBridgeInstalled = true;
      window.__velaHistoryApiBridgeLastUrl = String(window.location && window.location.href || '');

    \(WebPageScripts.markNativeHelper)

      function notify(kind, oldUrl, newUrl) {
        try {
          var normalizedOldUrl = String(oldUrl || '');
          var normalizedNewUrl = String(newUrl || '');
          if (!normalizedNewUrl || normalizedOldUrl === normalizedNewUrl) { return; }
          if (window.webkit && window.webkit.messageHandlers &&
              window.webkit.messageHandlers.\(Handler.historyApi.rawValue)) {
            window.webkit.messageHandlers.\(Handler.historyApi.rawValue).postMessage({
              kind: String(kind || ''),
              oldUrl: normalizedOldUrl,
              newUrl: normalizedNewUrl,
              timestamp: Date.now()
            });
          }
          window.__velaHistoryApiBridgeLastUrl = normalizedNewUrl;
        } catch (_error) {
        }
      }

      // The hook lives on `History.prototype`, wrapped as the platform's own
      // function, so the page finds the method where the platform keeps it and
      // reads the answer the platform would have given (`markNativeHelper`).
      function installHistoryHook(methodName) {
        var owner = history;
        try {
          var proto = Object.getPrototypeOf(history);
          if (proto && proto !== Object.prototype) { owner = proto; }
        } catch (_error) {}
        var original = owner[methodName];
        if (typeof original !== 'function') { return; }
        var hook = velaNative(function (state, title, url) {
          var before = String(window.location.href || '');
          var result = original.apply(this, arguments);
          var after = String(window.location.href || '');
          notify(methodName === 'pushState' ? 'pushState' : 'replaceState', before, after);
          return result;
        }, methodName);
        velaInstall(owner, methodName, hook);
      }

      installHistoryHook('pushState');
      installHistoryHook('replaceState');

      window.addEventListener('popstate', function () {
        var before = window.__velaHistoryApiBridgeLastUrl;
        var after = String(window.location.href || '');
        notify('popstate', before, after);
      }, true);

      window.addEventListener('hashchange', function () {
        var before = window.__velaHistoryApiBridgeLastUrl;
        var after = String(window.location.href || '');
        notify('hashchange', before, after);
      }, true);

      // The initial report lets the host settle a URL the page rewrote before
      // the bridge was installed.
      notify('init', '', String(window.location.href || ''));
    })();
    """

    // MARK: - Web appearance

    static func makeAppearanceScript() -> WKUserScript {
        WKUserScript(
            source: appearanceFallback,
            injectionTime: .atDocumentEnd,
            forMainFrameOnly: true,
            in: .defaultClient
        )
    }

    private static let appearanceFallback = #"""
    (() => {
      const root = document.documentElement;
      if (!root || document.contentType !== 'text/html') return;
      const scheme = matchMedia('(prefers-color-scheme: dark)');
      const marker = 'data-vela-dark-fallback';
      let stylesheet;

      function isDark(color) {
        const channels = color.match(/^rgba?\(([^)]+)\)$/)?.[1].split(',').map(Number);
        if (!channels || channels.length < 3 || channels[3] === 0) return null;
        const [r, g, b, a = 1] = channels;
        return (0.2126 * r + 0.7152 * g + 0.0722 * b) * a + 255 * (1 - a) < 128;
      }

      function update() {
        root.removeAttribute(marker);
        if (!scheme.matches) return;

        const rootStyle = getComputedStyle(root);
        const body = document.body;
        const bodyStyle = body ? getComputedStyle(body) : null;
        if (/\bdark\b/.test(rootStyle.colorScheme) || /\bdark\b/.test(bodyStyle?.colorScheme || '')) return;
        if ((isDark(bodyStyle?.backgroundColor || '') ?? isDark(rootStyle.backgroundColor)) === true) return;

        if (!stylesheet) {
          stylesheet = new CSSStyleSheet();
          stylesheet.replaceSync(`
            @media (prefers-color-scheme: dark) {
              html[data-vela-dark-fallback] {
                background-color: white;
                filter: invert(0.92) hue-rotate(180deg) !important;
              }
              html[data-vela-dark-fallback] :is(img, video, canvas, iframe) {
                filter: hue-rotate(180deg) invert(0.92) !important;
              }
            }
          `);
          document.adoptedStyleSheets = [...document.adoptedStyleSheets, stylesheet];
        }
        root.setAttribute(marker, '');
      }

      update();
      scheme.addEventListener('change', update);
      window.addEventListener('pageshow', update);
    })();
    """#

    // MARK: - Page background

    /// Reports the colour the page paints behind itself.
    ///
    /// The web view's frame ends above the command bar, so the strip the bar
    /// sits in is painted by the shell. Using the document's own background
    /// there keeps the page reading as one continuous surface under the
    /// glass; without it the app's backdrop showed as a band beneath every
    /// site.
    ///
    /// The colour is read from `body` and then `html` — the page's own
    /// declared surface — and only when both are transparent does it walk up
    /// from the element painted at the bottom of the viewport, which is the
    /// one shape that follows a page whose colour lives on a full-height
    /// wrapper rather than on the document. Reports are de-duplicated, and
    /// the handful of calls per load is deliberately not a frame-rate
    /// observer: the strip only has to be right, not live.
    public static let pageBackgroundReporter = """
    (function () {
      if (window.__velaPageBackgroundInstalled === true) { return; }
      window.__velaPageBackgroundInstalled = true;
      var HANDLER = '\(Handler.pageMetrics.rawValue)';
      var last = '';

      function parseColour(value) {
        var match = /rgba?\\(([^)]+)\\)/i.exec(value || '');
        if (!match) { return null; }
        var parts = match[1].split(',');
        if (parts.length < 3) { return null; }
        var alpha = parts.length > 3 ? parseFloat(parts[3]) : 1;
        if (isNaN(alpha)) { alpha = 1; }
        return {
          red: parseFloat(parts[0]) || 0,
          green: parseFloat(parts[1]) || 0,
          blue: parseFloat(parts[2]) || 0,
          alpha: alpha
        };
      }

      function isOpaque(value) {
        var colour = parseColour(value);
        return !!colour && colour.alpha > 0.01;
      }

      // The canvas WebKit paints behind a page that declares no background:
      // white, unless the page opted into a dark colour scheme.
      function canvasColour() {
        var scheme = '';
        try {
          scheme = String(window.getComputedStyle(document.documentElement).colorScheme || '').toLowerCase();
        } catch (_error) {
        }
        var prefersDark = false;
        try {
          prefersDark = window.matchMedia('(prefers-color-scheme: dark)').matches;
        } catch (_error) {
        }
        var isDark = scheme.indexOf('dark') >= 0 &&
          (scheme.indexOf('light') < 0 || prefersDark);
        return isDark ? 'rgb(0, 0, 0)' : 'rgb(255, 255, 255)';
      }

      // Composites a translucent colour onto the canvas colour.
      function normalize(value) {
        var colour = parseColour(value);
        if (!colour) { return canvasColour(); }
        var canvas = canvasColour();
        var base = /rgb\\(\\s*0\\s*,\\s*0\\s*,\\s*0\\s*\\)/i.test(canvas) ? 0 : 255;
        function blend(channel) {
          var mixed = channel * colour.alpha + base * (1 - colour.alpha);
          return Math.round(Math.min(255, Math.max(0, mixed)));
        }
        return 'rgb(' + blend(colour.red) + ', ' + blend(colour.green) + ', ' + blend(colour.blue) + ')';
      }

      function sample() {
        try {
          if (document.documentElement.hasAttribute('data-vela-dark-fallback') &&
              window.matchMedia('(prefers-color-scheme: dark)').matches) {
            return 'rgb(20, 20, 20)';
          }
          // `body` and `html` first: when either paints a background it is
          // the page's own surface, not whatever content happens to sit at
          // the bottom edge at this instant.
          var roots = [document.body, document.documentElement];
          for (var i = 0; i < roots.length; i++) {
            if (!roots[i]) { continue; }
            var rootBackground = window.getComputedStyle(roots[i]).backgroundColor;
            if (isOpaque(rootBackground)) { return normalize(rootBackground); }
          }
          // A page painted on a full-height wrapper leaves both transparent;
          // follow the paint upward from the bottom edge instead.
          var element = document.elementFromPoint(
            Math.max(1, window.innerWidth / 2),
            Math.max(1, window.innerHeight - 2)
          );
          while (element) {
            var background = window.getComputedStyle(element).backgroundColor;
            if (isOpaque(background)) { return normalize(background); }
            element = element.parentElement;
          }
        } catch (_error) {
        }
        return canvasColour();
      }

      function report() {
        try {
          var colour = sample();
          if (colour === last) { return; }
          last = colour;
          if (window.webkit && window.webkit.messageHandlers &&
              window.webkit.messageHandlers[HANDLER]) {
            window.webkit.messageHandlers[HANDLER].postMessage({ pageBackground: colour });
          }
        } catch (_error) {
        }
      }

      report();
      // Lazy images, web fonts and framework-rendered shells can hand the page
      // its real background after the document-end pass.
      window.setTimeout(report, 350);
      window.setTimeout(report, 1200);
      window.addEventListener('pageshow', report);
      window.addEventListener('resize', report);
      try {
        var scheme = window.matchMedia('(prefers-color-scheme: dark)');
        if (scheme && scheme.addEventListener) {
          scheme.addEventListener('change', report);
        }
      } catch (_error) {
      }
    })();
    """

    // MARK: - Scroll

    /// Samples the document offset for session restoration.
    public static let scrollReporter = """
    (function () {
      if (window.__velaScrollReporterInstalled === true) { return; }
      window.__velaScrollReporterInstalled = true;

      var lastY = window.scrollY || 0;
      var pending = null;

      function emit() {
        pending = null;
        var y = window.scrollY || 0;
        if (y === lastY) return;
        var handler = window.webkit?.messageHandlers?.\(Handler.scroll.rawValue);
        if (!handler) return;
        handler.postMessage({ offsetY: y });
        lastY = y;
      }

      window.addEventListener('scroll', function () {
        if (window.scrollY <= 0 && lastY > 0) {
          if (pending !== null) window.clearTimeout(pending);
          emit();
        } else if (pending === null) {
          pending = window.setTimeout(emit, 100);
        }
      }, { passive: true });
    })();
    """

    /// Puts a restored tab back where the user left it.
    ///
    /// Called once after a discarded tab's page has finished loading. Two
    /// animation frames after the call let layout settle first — scrolling a
    /// document whose height is still being computed is silently clamped to
    /// the height it had at that instant.
    public static func scrollRestoreScript(offsetY: Double) -> String {
        let target = max(0, Int(offsetY.rounded()))
        return """
        (function () {
          try {
            var target = \(target);
            function apply() {
              try { window.scrollTo(0, target); } catch (_error) {}
            }
            apply();
            if (window.requestAnimationFrame) {
              window.requestAnimationFrame(function () {
                apply();
                window.requestAnimationFrame(apply);
              });
            }
            // Late images and lazy content can grow the document after the
            // first frames; one more pass keeps a restored position from
            // being clamped to a height the page had only for a moment.
            window.setTimeout(apply, 320);
          } catch (_error) {
          }
        })();
        """
    }

    // MARK: - Find in page

    /// The in-page find script.
    ///
    /// It highlights with the CSS Custom Highlight API — ranges, not elements —
    /// so a search never rewrites the page's DOM. The earlier version wrapped
    /// every match in a `mark` element and unwrapped it again on the next
    /// keystroke; on a framework-rendered page that mutates text nodes React or
    /// Vue still hold references to, and the page can stop updating after a
    /// search. Highlights leave the document untouched.
    ///
    /// The match list and the current index live on the page, so "next" cannot
    /// race a report message that has not arrived yet. `reset` means the query
    /// changed: start at its first match. WebKit without the highlight API
    /// falls back to wrapping marks, and rebuilds the list on every step
    /// because wrapping invalidates the ranges.
    public static func findInPageScript(query: String, forward: Bool, reset: Bool) -> String {
        let encoded = (try? JSONSerialization.data(withJSONObject: [query]))
            .flatMap { String(data: $0, encoding: .utf8) }
            .map { String($0.dropFirst().dropLast()) } ?? "\"\""
        let forwardLiteral = forward ? "true" : "false"
        let resetLiteral = reset ? "true" : "false"

        return """
        (function () {
          var HANDLER = '\(Handler.pageMetrics.rawValue)';
          var STYLE_ID = '__vela_find_style';
          var ALL = 'vela-find';
          var ACTIVE = 'vela-find-active';

          function report(count, index) {
            if (window.webkit && window.webkit.messageHandlers &&
                window.webkit.messageHandlers[HANDLER]) {
              window.webkit.messageHandlers[HANDLER].postMessage({
                findResult: { count: count, index: index }
              });
            }
          }

          function hasHighlightAPI() {
            return !!(window.CSS && CSS.highlights && window.Highlight &&
                      window.Highlight.prototype && window.Highlight.prototype.add);
          }

          function ensureStyle(supported) {
            if (document.getElementById(STYLE_ID)) { return; }
            var style = document.createElement('style');
            style.id = STYLE_ID;
            style.textContent = supported
              ? '::highlight(vela-find){background-color:#ffd54f;color:#000;}' +
                '::highlight(vela-find-active){background-color:#ff9800;color:#000;}'
              : 'mark.__vela_find_all{background-color:#ffd54f;color:#000;}' +
                'mark.__vela_find_active{background-color:#ff9800;color:#000;}';
            (document.head || document.documentElement).appendChild(style);
          }

          function clearAll() {
            if (window.CSS && CSS.highlights) {
              CSS.highlights.delete(ALL);
              CSS.highlights.delete(ACTIVE);
            }
            var marks = document.querySelectorAll('mark.__vela_find_all, mark.__vela_find_active');
            for (var i = marks.length - 1; i >= 0; i--) {
              var mark = marks[i];
              var parent = mark.parentNode;
              if (!parent) { continue; }
              parent.replaceChild(document.createTextNode(mark.textContent), mark);
              parent.normalize();
            }
          }

          function collect(query) {
            var ranges = [];
            var lower = query.toLowerCase();
            if (!lower) { return ranges; }
            var walker = document.createTreeWalker(
              document.body || document.documentElement,
              NodeFilter.SHOW_TEXT,
              {
                acceptNode: function (node) {
                  if (!node.nodeValue) { return NodeFilter.FILTER_REJECT; }
                  var parent = node.parentNode;
                  var name = parent ? parent.nodeName : '';
                  if (name === 'SCRIPT' || name === 'STYLE' || name === 'NOSCRIPT' ||
                      name === 'TEXTAREA' || name === 'INPUT' || name === 'SELECT') {
                    return NodeFilter.FILTER_REJECT;
                  }
                  if (parent && parent.isContentEditable) {
                    return NodeFilter.FILTER_REJECT;
                  }
                  if (node.nodeValue.toLowerCase().indexOf(lower) < 0) {
                    return NodeFilter.FILTER_REJECT;
                  }
                  return NodeFilter.FILTER_ACCEPT;
                }
              }
            );
            var node;
            while ((node = walker.nextNode())) {
              var text = node.nodeValue;
              var haystack = text.toLowerCase();
              var at = haystack.indexOf(lower);
              while (at >= 0) {
                var range = document.createRange();
                range.setStart(node, at);
                range.setEnd(node, at + query.length);
                ranges.push(range);
                at = haystack.indexOf(lower, at + query.length);
              }
            }
            return ranges;
          }

          function wrapMarks(ranges, activeIndex) {
            var byNode = [];
            for (var i = 0; i < ranges.length; i++) {
              var node = ranges[i].startContainer;
              var group = null;
              for (var g = 0; g < byNode.length; g++) {
                if (byNode[g].node === node) { group = byNode[g]; break; }
              }
              if (!group) {
                group = { node: node, hits: [] };
                byNode.push(group);
              }
              group.hits.push({
                start: ranges[i].startOffset,
                end: ranges[i].endOffset,
                index: i
              });
            }
            for (var b = 0; b < byNode.length; b++) {
              var entry = byNode[b];
              var text = entry.node.nodeValue;
              if (!text || !entry.node.parentNode) { continue; }
              entry.hits.sort(function (a, b2) { return a.start - b2.start; });
              var fragment = document.createDocumentFragment();
              var cursor = 0;
              for (var h = 0; h < entry.hits.length; h++) {
                var hit = entry.hits[h];
                if (hit.start < cursor) { continue; }
                if (hit.start > cursor) {
                  fragment.appendChild(document.createTextNode(text.slice(cursor, hit.start)));
                }
                var mark = document.createElement('mark');
                mark.className = hit.index === activeIndex
                  ? '__vela_find_active'
                  : '__vela_find_all';
                mark.textContent = text.slice(hit.start, hit.end);
                fragment.appendChild(mark);
                cursor = hit.end;
              }
              if (cursor < text.length) {
                fragment.appendChild(document.createTextNode(text.slice(cursor)));
              }
              entry.node.parentNode.replaceChild(fragment, entry.node);
            }
          }

          var query = \(encoded);
          var forward = \(forwardLiteral);
          var reset = \(resetLiteral);
          var supported = hasHighlightAPI();
          var state = window.__velaFindState ||
            (window.__velaFindState = { query: '', ranges: [], index: -1 });

          if (!query) {
            clearAll();
            state.query = '';
            state.ranges = [];
            state.index = -1;
            report(0, -1);
            return;
          }

          ensureStyle(supported);

          var sameQuery = state.query === query && state.ranges.length > 0;
          // The wrapping fallback invalidates the ranges it uses, so it is
          // rebuilt on every step; the native path keeps them between steps.
          var rebuild = reset || !supported || !sameQuery;

          if (rebuild) {
            clearAll();
            state.ranges = collect(query);
            state.query = query;
            if (!sameQuery) { state.index = -1; }
          }

          var count = state.ranges.length;
          var index = -1;
          if (count > 0) {
            if (state.index < 0) {
              index = forward ? 0 : count - 1;
            } else {
              index = ((state.index + (forward ? 1 : -1)) % count + count) % count;
            }
          }
          state.index = index;

          if (supported) {
            var all = new Highlight();
            for (var i = 0; i < count; i++) {
              if (i !== index) { all.add(state.ranges[i]); }
            }
            CSS.highlights.set(ALL, all);
            if (index >= 0 && index < count) {
              var active = new Highlight();
              active.add(state.ranges[index]);
              CSS.highlights.set(ACTIVE, active);
            } else {
              CSS.highlights.delete(ACTIVE);
            }
          } else if (count > 0) {
            clearAll();
            wrapMarks(state.ranges, index);
          }

          if (index >= 0 && index < count) {
            var range = state.ranges[index];
            var node = range.startContainer;
            var element = node.nodeType === 1 ? node : node.parentElement;
            if (element && element.scrollIntoView) {
              element.scrollIntoView({ block: 'center', behavior: 'smooth' });
            }
          }

          report(count, index);
        })();
        """
    }

    /// Removes the find highlights and forgets the match list.
    ///
    /// Both highlight paths are cleared: the registry entries of the native
    /// API, and — for WebKit without it — the marks the fallback wrapped.
    public static let clearFindInPageScript = """
    (function () {
      if (window.CSS && CSS.highlights) {
        CSS.highlights.delete('vela-find');
        CSS.highlights.delete('vela-find-active');
      }
      var marks = document.querySelectorAll('mark.__vela_find_all, mark.__vela_find_active');
      for (var i = marks.length - 1; i >= 0; i--) {
        var mark = marks[i];
        var parent = mark.parentNode;
        if (!parent) { continue; }
        parent.replaceChild(document.createTextNode(mark.textContent), mark);
        parent.normalize();
      }
      var state = window.__velaFindState;
      if (state) {
        state.query = '';
        state.ranges = [];
        state.index = -1;
      }
    })();
    """

}
