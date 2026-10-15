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

    // MARK: - Viewport and safe area

    /// Reports viewport metrics and applies the bottom safe-area inset.
    ///
    /// Ported from `WebBottomSafeAreaScriptService` and
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

    /// Reports layout metrics back to the host so the toolbar clearance can be
    /// recomputed after a rotation or a dynamic-toolbar change. Ported from
    /// `BrowserWebViewportCoordinator`'s measurement pass.
    public static let pageMetricsReporter = """
    (function () {
      if (window.__velaPageMetricsInstalled === true) { return; }
      window.__velaPageMetricsInstalled = true;

      function report() {
        try {
          if (!(window.webkit && window.webkit.messageHandlers &&
                window.webkit.messageHandlers.\(Handler.pageMetrics.rawValue))) { return; }
          var root = document.documentElement;
          var body = document.body;
          window.webkit.messageHandlers.\(Handler.pageMetrics.rawValue).postMessage({
            // Whether the page actually scrolls decides whether the toolbar can
            // auto-hide. A page shorter than the viewport must keep it visible,
            // or the controls disappear with no way to bring them back.
            scrollHeight: Math.max(root ? root.scrollHeight : 0, body ? body.scrollHeight : 0),
            viewportHeight: window.innerHeight,
            viewportWidth: window.innerWidth,
            hasViewportFitCover: (function () {
              var meta = document.querySelector('meta[name="viewport"]');
              return !!meta && String(meta.getAttribute('content') || '').indexOf('viewport-fit=cover') >= 0;
            })(),
            colorScheme: (function () {
              var meta = document.querySelector('meta[name="color-scheme"]');
              if (meta) { return String(meta.getAttribute('content') || ''); }
              var computed = window.getComputedStyle(root);
              return String(computed.backgroundColor || '');
            })()
          });
        } catch (_error) {
        }
      }

      report();
      window.addEventListener('resize', function () { setTimeout(report, 120); }, false);
      document.addEventListener('DOMContentLoaded', function () { setTimeout(report, 60); }, false);
    })();
    """

    // MARK: - Scroll

    /// Reports scroll offset and direction. Ported from
    /// `BrowserBottomChromeScrollCoordinator`, which drives the collapsing
    /// toolbar. Direction is computed here rather than on the host so the
    /// threshold is applied once, on the page, where the offset is produced.
    public static let scrollReporter = """
    (function () {
      if (window.__velaScrollReporterInstalled === true) { return; }
      window.__velaScrollReporterInstalled = true;

      var lastY = window.scrollY || 0;
      var ticking = false;

      function emit() {
        ticking = false;
        try {
          var y = window.scrollY || 0;
          var delta = y - lastY;
          // A threshold keeps a one-pixel jitter from toggling the toolbar.
          if (Math.abs(delta) < 6) { return; }
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

    // MARK: - Dark mode

    /// Tells the page whether it should render dark, and reads back whether it
    /// has a dark stylesheet. Ported from `BrowserPageChromeThemeSamplingCoordinator`,
    /// which samples the page's own background to decide whether the browser
    /// chrome should be light or dark against it.
    public static func colorSchemeScript(prefersDark: Bool) -> String {
        """
        (function () {
          try {
            var meta = document.querySelector('meta[name="color-scheme"]');
            if (!meta) {
              meta = document.createElement('meta');
              meta.setAttribute('name', 'color-scheme');
              (document.head || document.documentElement).appendChild(meta);
            }
            meta.setAttribute('content', '\(prefersDark ? "dark light" : "light dark")');
            document.documentElement.style.colorScheme = '\(prefersDark ? "dark" : "light")';
          } catch (_error) {
          }
        })();
        """
    }

    // MARK: - Find in page

    /// Highlights every match of `query` and reports the count.
    ///
    /// Ported from `BrowserPageFindCoordinator`. Implemented with a DOM walk
    /// rather than `window.find()` because `window.find` is not exposed in
    /// WebKit's JavaScript context and selecting text does not survive a scroll
    /// on a long page.
    public static func findInPageScript(query: String, forward: Bool, focusIndex: Int) -> String {
        let encoded = (try? JSONSerialization.data(withJSONObject: [query]))
            .flatMap { String(data: $0, encoding: .utf8) }
            .map { String($0.dropFirst().dropLast()) } ?? "\"\""

        return """
        (function () {
          var HIGHLIGHT_ID = '__vela_find_highlight';
          var ACTIVE_CLASS = '__vela_find_active';

          function clearHighlights() {
            var existing = document.querySelectorAll('.' + ACTIVE_CLASS);
            for (var i = 0; i < existing.length; i++) {
              var parent = existing[i].parentNode;
              if (!parent) { continue; }
              parent.replaceChild(document.createTextNode(existing[i].textContent), existing[i]);
              parent.normalize();
            }
            var style = document.getElementById(HIGHLIGHT_ID);
            if (style) { style.remove(); }
          }

          clearHighlights();

          var query = \(encoded);
          if (!query) {
            if (window.webkit && window.webkit.messageHandlers &&
                window.webkit.messageHandlers.\(Handler.pageMetrics.rawValue)) {
              window.webkit.messageHandlers.\(Handler.pageMetrics.rawValue).postMessage({ findResult: { count: 0, index: -1 } });
            }
            return;
          }

          var lowerQuery = query.toLowerCase();
          var matches = [];
          // A TreeWalker is the only way to visit text nodes without collecting
          // every element in the document into an array first.
          var walker = document.createTreeWalker(
            document.body || document.documentElement,
            NodeFilter.SHOW_TEXT,
            {
              acceptNode: function (node) {
                if (!node.nodeValue || node.nodeValue.toLowerCase().indexOf(lowerQuery) < 0) {
                  return NodeFilter.FILTER_REJECT;
                }
                var tag = node.parentNode ? node.parentNode.nodeName : '';
                if (tag === 'SCRIPT' || tag === 'STYLE' || tag === 'NOSCRIPT') {
                  return NodeFilter.FILTER_REJECT;
                }
                return NodeFilter.FILTER_ACCEPT;
              }
            }
          );

          var current;
          while ((current = walker.nextNode())) {
            var text = current.nodeValue;
            var lowerText = text.toLowerCase();
            var position = lowerText.indexOf(lowerQuery);
            var fragment = document.createDocumentFragment();
            var cursor = 0;
            while (position >= 0) {
              if (position > cursor) {
                fragment.appendChild(document.createTextNode(text.slice(cursor, position)));
              }
              var mark = document.createElement('mark');
              mark.className = ACTIVE_CLASS;
              mark.style.backgroundColor = '#ffd54f';
              mark.style.color = '#000';
              mark.textContent = text.slice(position, position + query.length);
              fragment.appendChild(mark);
              matches.push(mark);
              cursor = position + query.length;
              position = lowerText.indexOf(lowerQuery, cursor);
            }
            if (cursor < text.length) {
              fragment.appendChild(document.createTextNode(text.slice(cursor)));
            }
            current.parentNode.replaceChild(fragment, current);
          }

          var index = matches.length === 0 ? -1 : ((\(focusIndex) % matches.length) + matches.length) % matches.length;
          if (index >= 0) {
            matches[index].style.backgroundColor = '#ff9800';
            matches[index].scrollIntoView({ block: 'center', behavior: 'smooth' });
          }

          if (window.webkit && window.webkit.messageHandlers &&
              window.webkit.messageHandlers.\(Handler.pageMetrics.rawValue)) {
            window.webkit.messageHandlers.\(Handler.pageMetrics.rawValue).postMessage({
              findResult: { count: matches.length, index: index }
            });
          }
        })();
        """
    }

    public static let clearFindInPageScript = """
    (function () {
      var marks = document.querySelectorAll('.__vela_find_active');
      for (var i = marks.length - 1; i >= 0; i--) {
        var mark = marks[i];
        var parent = mark.parentNode;
        if (!parent) { continue; }
        parent.replaceChild(document.createTextNode(mark.textContent), mark);
        parent.normalize();
      }
    })();
    """

    // MARK: - Element picker

    /// The element picker. Ported from
    /// `ElementInspectionRuntimeScriptService` and
    /// `ManualElementHideRuntimeScriptService`: pointing at an element produces
    /// a CSS selector that hides it and its siblings.
    ///
    /// The generated selector prefers a stable id, then a class combination,
    /// then a structural path. An auto-generated class such as `css-1x2y3z`
    /// changes on every deploy, so a rule built on one stops working; the
    /// structural path is ugly but is the only thing that survives.
    public static let elementPickerScript = """
    (function () {
      if (window.__velaElementPickerInstalled === true) { return; }
      window.__velaElementPickerInstalled = true;

      var highlighted = null;
      var previousOutline = '';

      function isGeneratedClass(name) {
        return /^(css|sc|jsx|styled)-?[0-9a-z]{4,}$/i.test(name) ||
               /^[a-z]+-[0-9a-f]{6,}$/i.test(name) ||
               /^_[0-9a-z]{5,}$/i.test(name);
      }

      function stableClasses(element) {
        var list = [];
        var classes = String(element.className || '').split(/\\s+/);
        for (var i = 0; i < classes.length; i++) {
          var name = classes[i].trim();
          if (!name || isGeneratedClass(name)) { continue; }
          list.push(name);
        }
        return list;
      }

      function selectorFor(element) {
        if (!element || element.nodeType !== 1) { return ''; }

        // 1. A stable id wins outright: ids are unique by definition and a
        //    hand-written one rarely changes.
        var id = element.getAttribute('id');
        if (id && !isGeneratedClass(id) && !/^\\d/.test(id)) {
          return '#' + (window.CSS && CSS.escape ? CSS.escape(id) : id);
        }

        var classes = stableClasses(element);
        if (classes.length > 0) {
          var escaped = classes.map(function (name) {
            return '.' + (window.CSS && CSS.escape ? CSS.escape(name) : name);
          }).join('');
          // Only use the class path when it is unique, otherwise the rule would
          // hide unrelated elements the user did not point at.
          try {
            if (document.querySelectorAll(escaped).length === 1) { return escaped; }
          } catch (_error) {
          }
          return element.tagName.toLowerCase() + escaped;
        }

        // 2. Structural path.
        var parts = [];
        var node = element;
        var depth = 0;
        while (node && node.nodeType === 1 && depth < 6) {
          var tag = node.tagName.toLowerCase();
          var parent = node.parentNode;
          if (parent) {
            var siblings = [];
            var children = parent.children || [];
            for (var i = 0; i < children.length; i++) {
              if (children[i].tagName === node.tagName) { siblings.push(children[i]); }
            }
            if (siblings.length > 1) {
              tag += ':nth-of-type(' + (siblings.indexOf(node) + 1) + ')';
            }
          }
          parts.unshift(tag);
          node = parent;
          depth++;
        }
        return parts.join(' > ');
      }

      function onMove(event) {
        var target = event.target;
        if (!target || target === document.documentElement || target === document.body) { return; }
        if (highlighted === target) { return; }
        if (highlighted) {
          highlighted.style.outline = previousOutline;
        }
        highlighted = target;
        previousOutline = target.style.outline;
        target.style.outline = '2px solid #ff5722';
      }

      function onClick(event) {
        event.preventDefault();
        event.stopPropagation();
        var selector = selectorFor(event.target);
        if (highlighted) { highlighted.style.outline = previousOutline; }
        try {
          if (window.webkit && window.webkit.messageHandlers &&
              window.webkit.messageHandlers.\(Handler.elementPick.rawValue)) {
            window.webkit.messageHandlers.\(Handler.elementPick.rawValue).postMessage({
              selector: selector,
              elementCount: selector ? document.querySelectorAll(selector).length : 0
            });
          }
        } catch (_error) {
        }
      }

      window.__velaElementPickerStop = function () {
        document.removeEventListener('mousemove', onMove, true);
        document.removeEventListener('click', onClick, true);
        if (highlighted) { highlighted.style.outline = previousOutline; }
        highlighted = null;
      };

      document.addEventListener('mousemove', onMove, true);
      document.addEventListener('click', onClick, true);
    })();
    """

    public static let stopElementPickerScript = """
    (function () {
      if (typeof window.__velaElementPickerStop === 'function') {
        window.__velaElementPickerStop();
      }
    })();
    """

    // MARK: - Page text extraction

    /// Extracts the page text for translation. Ported from
    /// `WebpageTranslationExtractionService`: text nodes are collected with
    /// their structural path so a translation can be written back into the same
    /// node rather than replacing the page.
    public static let textExtractionScript = """
    (function () {
      var SKIP_TAGS = { SCRIPT: 1, STYLE: 1, NOSCRIPT: 1, CODE: 1, PRE: 1, TEXTAREA: 1, SVG: 1, CANVAS: 1 };
      var segments = [];
      var walker = document.createTreeWalker(
        document.body || document.documentElement,
        NodeFilter.SHOW_TEXT,
        {
          acceptNode: function (node) {
            if (SKIP_TAGS[node.parentNode ? node.parentNode.nodeName : '']) {
              return NodeFilter.FILTER_REJECT;
            }
            var text = (node.nodeValue || '').trim();
            // Skip whitespace-only and single-character nodes: they are almost
            // always layout artefacts and translating them wastes a request.
            if (text.length < 2) { return NodeFilter.FILTER_REJECT; }
            if (!/[a-zA-Z\\u4e00-\\u9fa5]/.test(text)) { return NodeFilter.FILTER_REJECT; }
            return NodeFilter.FILTER_ACCEPT;
          }
        }
      );

      var index = 0;
      var node;
      while ((node = walker.nextNode())) {
        node.__velaTranslationIndex = index;
        segments.push({
          index: index,
          text: (node.nodeValue || '').trim(),
          tag: node.parentNode ? node.parentNode.nodeName.toLowerCase() : ''
        });
        index++;
        // A page with tens of thousands of nodes would produce a request body
        // no translation service accepts, and a latency the user would not
        // tolerate.
        if (index >= 800) { break; }
      }

      return JSON.stringify({ segments: segments, url: String(window.location.href || ''), title: document.title });
    })();
    """

    /// Writes translated text back into the nodes the extraction indexed.
    public static let textApplicationScript = """
    window.__velaApplyTranslation = function (payload) {
      try {
        var data = typeof payload === 'string' ? JSON.parse(payload) : payload;
        var segments = data.segments || [];
        for (var i = 0; i < segments.length; i++) {
          var segment = segments[i];
          var nodes = document.createTreeWalker(document.body, NodeFilter.SHOW_TEXT, null);
          var node;
          while ((node = nodes.nextNode())) {
            if (node.__velaTranslationIndex === segment.index) {
              node.nodeValue = segment.text;
              break;
            }
          }
        }
        return true;
      } catch (_error) {
        return false;
      }
    };
    """
}
