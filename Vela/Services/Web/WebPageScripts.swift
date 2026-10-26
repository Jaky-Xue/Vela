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
        case adBlockReport = "velaAdBlockReport"
        /// New text blocks found by the translation observer after a page
        /// has been translated once. The service answers with a batch of
        /// translated HTML.
        case translation = "velaTranslation"
        /// A page's fullscreen video request, and the playback state it
        /// reports while the app's player is up.
        case mediaFullscreen = "velaMediaFullscreen"
    }

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

      function installHistoryHook(methodName) {
        var original = history[methodName];
        if (typeof original !== 'function') { return; }
        history[methodName] = function (state, title, url) {
          var before = String(window.location.href || '');
          var result = original.apply(this, arguments);
          var after = String(window.location.href || '');
          notify(methodName === 'pushState' ? 'pushState' : 'replaceState', before, after);
          return result;
        };
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

    // MARK: - Identifier consistency

    /// Makes a hand-picked identifier hold together as a whole.
    ///
    /// A preset only rewrites the `User-Agent` header; everything else a page
    /// can ask stays WebKit's own — `navigator.vendor` reports Apple,
    /// `navigator.userAgentData` is absent, `window.chrome` is missing. A
    /// site's risk control reads exactly those, and a UA claiming Chrome
    /// beside a vendor saying Apple is the textbook mismatch such a check
    /// exists to catch — the shape of YouTube's 「出了点问题」 screens. So
    /// when a tab presents a hand-picked identifier, this script aligns the
    /// rest of the surface with the claim:
    ///
    /// * A Chromium claim (`Chrome/`, `Edg/`) gains the `userAgentData`
    ///   object real Chromium exposes — brands, platform, mobility, and a
    ///   `getHighEntropyValues` answer — plus Google's vendor and
    ///   `window.chrome`.
    /// * A Chrome-on-iOS claim (`CriOS/`) gains only the vendor: real Chrome
    ///   on iOS runs on WebKit and has no `userAgentData`, so adding one
    ///   would be its own mismatch.
    /// * A Firefox claim gains Firefox's empty vendor and nothing else —
    ///   Firefox has no `userAgentData` either.
    /// * Vela's default and the Safari presets send no script at all:
    ///   WebKit already is Safari, and its surface is consistent by
    ///   construction.
    ///
    /// Returns nil when there is nothing to align.
    public static func identityConsistencyScript(userAgent: String) -> String? {
        let lowered = userAgent.lowercased()
        let claimsChromiumData = lowered.contains("chrome/") || lowered.contains("edg/")
        let claimsCriOS = lowered.contains("crios/")
        let claimsFirefox = lowered.contains("firefox/")
        guard claimsChromiumData || claimsCriOS || claimsFirefox else { return nil }

        func majorToken(after marker: String) -> String? {
            guard let range = lowered.range(of: marker) else { return nil }
            let digits = lowered[range.upperBound...].prefix { $0.isNumber }
            return digits.isEmpty ? nil : String(digits)
        }
        let chromiumMajor = majorToken(after: "chrome/") ?? majorToken(after: "edg/") ?? "120"
        let isEdge = lowered.contains("edg/")

        let vendor: String = (claimsChromiumData || claimsCriOS) ? "Google Inc." : ""

        let platform: String
        if lowered.contains("android") { platform = "Android" }
        else if lowered.contains("macintosh") { platform = "macOS" }
        else if lowered.contains("windows") { platform = "Windows" }
        else { platform = "Chrome OS" }
        let mobile = lowered.contains("android")

        let platformVersion: String
        switch platform {
        case "Android": platformVersion = "\(majorToken(after: "android ") ?? "14").0.0"
        case "macOS": platformVersion = "13.5.0"
        default: platformVersion = "10.0.0"
        }

        // The platform and the touch-point count were still the iPad's on
        // every preset: a Windows Chrome claim beside a platform of "MacIntel"
        // and five touch points is the mismatch a site's browser check reads
        // first. Chrome on iOS is left alone — it really is WebKit on iOS.
        let claimedPlatform: String
        switch platform {
        case "Android": claimedPlatform = "Linux armv8l"
        case "macOS": claimedPlatform = "MacIntel"
        case "Windows": claimedPlatform = "Win32"
        default: claimedPlatform = "Linux x86_64"
        }
        let claimedTouchPoints = mobile ? 5 : 0
        let platformLiteral = Self.jsonString(claimedPlatform)

        let grease = ["brand": "Not_A Brand", "version": "24"]
        let brands: [[String: String]] = isEdge
            ? [["brand": "Microsoft Edge", "version": majorToken(after: "edg/") ?? chromiumMajor],
               ["brand": "Chromium", "version": chromiumMajor],
               grease]
            : [["brand": "Google Chrome", "version": chromiumMajor],
               ["brand": "Chromium", "version": chromiumMajor],
               grease]
        let brandsJSON = (try? JSONSerialization.data(withJSONObject: brands))
            .flatMap { String(data: $0, encoding: .utf8) } ?? "[]"

        let vendorBlock = """
          try {
            Object.defineProperty(Navigator.prototype, 'vendor', {
              get: function () { return \(Self.jsonString(vendor)); },
              configurable: true
            });
          } catch (error) {}
        """

        let userAgentDataBlock = claimsChromiumData ? """
          try {
            if (!navigator.userAgentData) {
              var brands = \(brandsJSON);
              var data = {
                brands: brands,
                mobile: \(mobile),
                platform: '\(platform)'
              };
              data.getHighEntropyValues = function (hints) {
                return Promise.resolve({
                  brands: brands,
                  mobile: \(mobile),
                  platform: '\(platform)',
                  platformVersion: '\(platformVersion)',
                  architecture: 'x86',
                  bitness: '64',
                  model: '',
                  uaFullVersion: '\(chromiumMajor).0.0.0',
                  fullVersionList: brands
                });
              };
              data.toJSON = function () {
                return { brands: brands, mobile: \(mobile), platform: '\(platform)' };
              };
              Object.defineProperty(Navigator.prototype, 'userAgentData', {
                get: function () { return data; },
                configurable: true
              });
            }
          } catch (error) {}
        """ : ""

        let windowChromeBlock = claimsChromiumData ? """
          try { if (!window.chrome) { window.chrome = { runtime: {} }; } } catch (error) {}
        """ : ""

        let platformBlock = (claimsChromiumData || claimsFirefox) ? """
          try {
            Object.defineProperty(Navigator.prototype, 'platform', {
              get: function () { return \(platformLiteral); },
              configurable: true
            });
          } catch (error) {}
          try {
            Object.defineProperty(Navigator.prototype, 'maxTouchPoints', {
              get: function () { return \(claimedTouchPoints); },
              configurable: true
            });
          } catch (error) {}
        """ : ""

        return """
        (function () {
          if (window.__velaIdentityConsistency === true) { return; }
          window.__velaIdentityConsistency = true;
        \(vendorBlock)
        \(userAgentDataBlock)
        \(windowChromeBlock)
        \(platformBlock)
        })();
        """
    }

    /// A JSON string literal for embedding a Swift string in injected
    /// JavaScript.
    private static func jsonString(_ value: String) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: [value]),
              let array = String(data: data, encoding: .utf8), array.count >= 2 else {
            return "\"\""
        }
        return String(array.dropFirst().dropLast())
    }

    // MARK: - Viewport and safe area

    /// Reports viewport metrics and applies the bottom safe-area inset.
    ///
    /// `BrowserWebViewportCoordinator`. The inset is applied to the document
    /// element rather than by shrinking the web view, because shrinking the web
    /// view would make fixed-position page chrome sit above the toolbar, which
    /// looks like a rendering bug to the user.
    public static func safeAreaScript(bottomInset: Double, toolbarClearance: Double, topInset: Double) -> String {
        """
        (function () {
          var root = document.documentElement;
          if (!root) { return; }
          var styleId = '__vela_safe_area_style';
          var style = document.getElementById(styleId);
          if (!style) {
            style = document.createElement('style');
            style.id = styleId;
            (document.head || root).appendChild(style);
          }
          // A page that declares a viewport-fit of cover draws under the
          // toolbar; one that does not needs the padding to be visible at all.
          style.textContent =
            ':root { --vela-safe-area-bottom: \(Int(bottomInset))px; --vela-safe-area-top: \(Int(topInset))px; }' +
            'body { padding-bottom: \(Int(bottomInset + toolbarClearance))px !important; }';
          try {
            root.style.setProperty('--vela-safe-area-bottom', '\(Int(bottomInset))px');
            root.style.setProperty('--vela-safe-area-top', '\(Int(topInset))px');
          } catch (_error) {
          }
        })();
        """
    }

    // MARK: - Scroll

    /// Reports scroll offset and direction.
    public static let scrollReporter = """
    (function () {
      if (window.__velaScrollReporterInstalled === true) { return; }
      window.__velaScrollReporterInstalled = true;

      var lastY = window.scrollY || 0;
      var lastEmitAt = 0;
      var ticking = false;

      function emit() {
        ticking = false;
        try {
          var y = window.scrollY || 0;
          var delta = y - lastY;
          // A distance threshold plus a time gate keeps the script bridge quiet
          // during a fling: the chrome only needs to know which side of its
          // threshold the accumulated movement is on, not every frame.
          if (Math.abs(delta) < 8) { return; }
          var now = Date.now();
          // Reaching the top is always reported: a thinned-out final frame
          // must not leave the bar hidden on a page the user has returned to
          // the start of.
          if (y > 0 && now - lastEmitAt < 70) { return; }
          lastEmitAt = now;
          if (window.webkit && window.webkit.messageHandlers &&
              window.webkit.messageHandlers.\(Handler.scroll.rawValue)) {
            window.webkit.messageHandlers.\(Handler.scroll.rawValue).postMessage({
              offsetY: y,
              deltaY: delta,
              direction: delta > 0 ? 'down' : 'up',
              atTop: y <= 0
            });
          }
          lastY = y;
        } catch (_error) {
        }
      }

      window.addEventListener('scroll', function () {
        if (ticking) { return; }
        ticking = true;
        window.requestAnimationFrame(emit);
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
