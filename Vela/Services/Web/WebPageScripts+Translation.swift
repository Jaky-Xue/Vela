//
//  WebPageScripts+Translation.swift
//  Vela
//
//  The translation scripts injected into pages, split from the base script
//  catalogue so each page-script area has its own file.
//

import Foundation

extension WebPageScripts {
    // MARK: - Page translation

    /// The functions a translated document needs: block extraction, the
    /// writer, the original-text restore, and the observer that picks up
    /// content added after the first pass.
    ///
    /// Blocks rather than individual text nodes: a paragraph is the unit a
    /// translator needs to produce a sentence that reads like the original,
    /// and its `innerHTML` carries the inline markup (`<b>`, `<a>`) through the
    /// request so the translated page keeps its links and emphasis. Chrome's
    /// own translation does the same thing at paragraph granularity.
    public static let translationSupportScript = """
    (function () {
      if (window.__velaTranslationSupportInstalled === true) { return; }
      window.__velaTranslationSupportInstalled = true;
      window.__velaUnits = window.__velaUnits || {};
      window.__velaNextUnitId = window.__velaNextUnitId || 0;
      window.__velaApplyingTranslation = false;

      var SKIP = {
        SCRIPT: 1, STYLE: 1, NOSCRIPT: 1, CODE: 1, PRE: 1, TEXTAREA: 1,
        SVG: 1, CANVAS: 1, IFRAME: 1, VIDEO: 1, AUDIO: 1, INPUT: 1,
        SELECT: 1, OPTION: 1, HEAD: 1, TITLE: 1, META: 1, LINK: 1
      };
      var BLOCK = {
        P: 1, LI: 1, H1: 1, H2: 1, H3: 1, H4: 1, H5: 1, H6: 1,
        TD: 1, TH: 1, DD: 1, DT: 1, BLOCKQUOTE: 1, FIGCAPTION: 1,
        CAPTION: 1, SUMMARY: 1, LABEL: 1, BUTTON: 1, DIV: 1, ARTICLE: 1,
        SECTION: 1, MAIN: 1, ASIDE: 1, HEADER: 1, FOOTER: 1, NAV: 1,
        FORM: 1, FIELDSET: 1, LEGEND: 1, ADDRESS: 1, DETAILS: 1,
        DIALOG: 1, OUTPUT: 1, UL: 1, OL: 1, TABLE: 1, THEAD: 1,
        TBODY: 1, TFOOT: 1, TR: 1, DL: 1, FIGURE: 1, CENTER: 1
      };
      // Long articles and documentation pages routinely exceed the old
      // 600-block / 90k-character ceiling. The provider batches still cap the
      // request size; these limits only decide how much of the document is
      // eligible for the first pass.
      var MAX_UNITS = 1200;
      var MAX_CHARS = 180000;

      /// The document's declared language fields. Some sites set only the
      /// `<html lang>` attribute, others only a content-language meta or an
      /// Open Graph locale; the recogniser uses whichever is present when the
      /// page's visible text is too short to identify reliably.
      function declaredLanguage() {
        try {
          var html = document.documentElement.getAttribute('lang') || '';
          var meta = document.querySelector(
            'meta[http-equiv="content-language" i], meta[name="language" i]'
          );
          var og = document.querySelector('meta[property="og:locale"]');
          return String(html || (meta && meta.content) || (og && og.content) || '');
        } catch (_error) {
          return '';
        }
      }

      function textOf(element) {
        return (element.textContent || '').replace(/\\s+/g, ' ').trim();
      }

      function hasLetters(value) {
        return /[A-Za-z\\u00C0-\\u024F\\u0370-\\u03FF\\u0400-\\u04FF\\u0590-\\u05FF\\u0600-\\u06FF\\u0900-\\u097F\\u3040-\\u30FF\\u4E00-\\u9FFF\\uAC00-\\uD7AF]/.test(value);
      }

      function hasBlockChild(element) {
        for (var child = element.firstElementChild; child; child = child.nextElementSibling) {
          if (BLOCK[child.nodeName]) { return true; }
        }
        return false;
      }

      function addUnit(element, units, state) {
        if (element.__velaUnitId !== undefined) { return; }
        if (units.length >= MAX_UNITS || state.chars >= MAX_CHARS) { return; }
        var html = element.innerHTML;
        if (!html || html.length < 2) { return; }
        var text = textOf(element);
        if (text.length < 2 || !hasLetters(text)) { return; }
        if (state.chars + html.length > MAX_CHARS) { return; }
        var id = window.__velaNextUnitId++;
        element.__velaUnitId = id;
        window.__velaUnits[id] = element;
        units.push({ id: id, html: html });
        state.chars += html.length;
      }

      function walk(element, units, state, onlyNew) {
        if (!element || element.nodeType !== 1) { return; }
        if (SKIP[element.nodeName] || element.isContentEditable) { return; }
        if (element.hidden === true) { return; }
        // An element that is already a unit was translated as a whole; new
        // content inside it would need a fresh block, which is rare enough to
        // leave for the next full translation.
        if (onlyNew && element.__velaUnitId !== undefined) { return; }
        if (BLOCK[element.nodeName]) {
          if (hasBlockChild(element)) {
            for (var child = element.firstElementChild; child; child = child.nextElementSibling) {
              walk(child, units, state, onlyNew);
            }
          } else {
            addUnit(element, units, state);
          }
          return;
        }
        for (var child = element.firstElementChild; child; child = child.nextElementSibling) {
          walk(child, units, state, onlyNew);
        }
        // Open shadow roots are where a growing number of sites put their
        // article text. querySelectorAll never crosses this boundary, so walk
        // it explicitly; the registry holds the element, and the writer sets
        // its text/HTML exactly as it does for light DOM.
        if (element.shadowRoot) {
          var shadowChildren = element.shadowRoot.children;
          for (var shadowIndex = 0; shadowIndex < shadowChildren.length; shadowIndex++) {
            walk(shadowChildren[shadowIndex], units, state, onlyNew);
          }
        }
      }

      window.__velaExtractUnits = function (root, onlyNew) {
        var units = [];
        var state = { chars: 0 };
        try {
          walk(root || document.body || document.documentElement, units, state, onlyNew === true);
        } catch (_error) {
        }
        // Same-origin embedded documents (documentation frames, embedded
        // readers) are part of the page a person sees. Cross-origin frames
        // throw on access and are skipped.
        if (onlyNew !== true) {
          try {
            var frames = document.querySelectorAll('iframe');
            for (var frameIndex = 0; frameIndex < frames.length; frameIndex++) {
              var frameBody = frames[frameIndex].contentDocument &&
                              frames[frameIndex].contentDocument.body;
              if (frameBody) { walk(frameBody, units, state, false); }
            }
          } catch (_frameError) {
          }
        }
        var sample = '';
        if (onlyNew !== true) {
          try {
            var body = document.body || document.documentElement;
            sample = (body.innerText || body.textContent || '')
              .replace(/\\s+/g, ' ').trim().slice(0, 1200);
          } catch (_error2) {
          }
        }
        return {
          units: units,
          sample: sample,
          url: String(window.location.href || ''),
          title: document.title || '',
          lang: declaredLanguage()
        };
      };

      function collectText(root) {
        var out = [];
        var walker = document.createTreeWalker(root, NodeFilter.SHOW_TEXT, {
          acceptNode: function (node) {
            if (!node.nodeValue || !node.nodeValue.trim()) {
              return NodeFilter.FILTER_REJECT;
            }
            var parent = node.parentNode;
            if (parent && SKIP[parent.nodeName]) {
              return NodeFilter.FILTER_REJECT;
            }
            return NodeFilter.FILTER_ACCEPT;
          }
        });
        while (walker.nextNode()) {
          out.push(walker.currentNode);
        }
        return out;
      }

      // The element-only shape of a subtree. Google returns the tags it was
      // given in the same order, so a matching signature means the translated
      // text nodes line up one-to-one with the originals.
      function signature(root) {
        var parts = [];
        var children = root.childNodes;
        for (var i = 0; i < children.length; i++) {
          var node = children[i];
          if (node.nodeType === 1) {
            parts.push(node.nodeName + '[' + signature(node) + ']');
          }
        }
        return parts.join(',');
      }

      /// Replaces text nodes in place, which keeps the page's own elements,
      /// attributes and listeners. Returns false when the translated markup no
      /// longer has the same shape, in which case the caller falls back to
      /// replacing the block's innerHTML.
      function mergeText(original, translatedRoot) {
        var originals = collectText(original);
        var translated = collectText(translatedRoot);
        if (originals.length === 0 || originals.length !== translated.length) {
          return false;
        }
        // An equal number of text nodes is the condition that matters for
        // preserving the page's elements and listeners. Providers routinely
        // change tag nesting between paragraphs; requiring the old shape
        // signature made those units fall back to a whole-block innerHTML
        // replacement, which recreated links and buttons.
        for (var i = 0; i < originals.length; i++) {
          if (originals[i].__velaOriginalText === undefined) {
            originals[i].__velaOriginalText = originals[i].nodeValue;
          }
          originals[i].nodeValue = translated[i].nodeValue;
        }
        return true;
      }

      window.__velaApplyTranslations = function (payload) {
        var appliedIds = [];
        try {
          var data = typeof payload === 'string' ? JSON.parse(payload) : payload;
          var units = data.units || [];
          window.__velaApplyingTranslation = true;
          for (var i = 0; i < units.length; i++) {
            var unit = units[i];
            var element = window.__velaUnits ? window.__velaUnits[unit.id] : null;
            if (!element || typeof unit.html !== 'string') { continue; }
            if (element.__velaOriginalHTML === undefined) {
              element.__velaOriginalHTML = element.innerHTML;
            }
            var template = document.createElement('template');
            template.innerHTML = unit.html;
            if (mergeText(element, template.content)) {
              appliedIds.push(unit.id);
            } else {
              element.innerHTML = unit.html;
              element.__velaUsedHTMLRestore = true;
              appliedIds.push(unit.id);
            }
          }
        } catch (_error) {
        }
        // The observer fires as a microtask after these writes. Clearing the
        // flag in a timeout makes it ignore them without ignoring the page's
        // own subsequent mutations.
        window.setTimeout(function () {
          window.__velaApplyingTranslation = false;
        }, 0);
        return appliedIds;
      };

      /// Applies the Google response, which comes back as the concatenated
      /// wrappers that were sent, not as a JSON array.
      window.__velaApplyTranslatedHTML = function (html) {
        try {
          var template = document.createElement('template');
          template.innerHTML = html || '';
          var wrappers = template.content.querySelectorAll('[data-vela-unit]');
          var units = [];
          for (var i = 0; i < wrappers.length; i++) {
            var wrapper = wrappers[i];
            units.push({
              id: Number(wrapper.getAttribute('data-vela-unit')),
              html: wrapper.innerHTML
            });
          }
          return window.__velaApplyTranslations({ units: units });
        } catch (_error) {
          return [];
        }
      };

      window.__velaRestoreTranslations = function () {
        try {
          if (window.__velaStopTranslationObserver) {
            window.__velaStopTranslationObserver();
          }
          var registry = window.__velaUnits || {};
          for (var key in registry) {
            if (!Object.prototype.hasOwnProperty.call(registry, key)) { continue; }
            var element = registry[key];
            if (!element) { continue; }
            if (element.__velaUsedHTMLRestore && element.__velaOriginalHTML !== undefined) {
              element.innerHTML = element.__velaOriginalHTML;
            } else {
              var walker = document.createTreeWalker(element, NodeFilter.SHOW_TEXT, null);
              var node;
              while ((node = walker.nextNode())) {
                if (node.__velaOriginalText !== undefined) {
                  node.nodeValue = node.__velaOriginalText;
                  delete node.__velaOriginalText;
                }
              }
            }
            delete element.__velaOriginalHTML;
            delete element.__velaUnitId;
            delete element.__velaUsedHTMLRestore;
          }
          window.__velaUnits = {};
          window.__velaNextUnitId = 0;
          window.__velaApplyingTranslation = false;
          return true;
        } catch (_error) {
          return false;
        }
      };

      window.__velaStopTranslationObserver = function () {
        if (window.__velaTranslationObserver) {
          window.__velaTranslationObserver.disconnect();
          window.__velaTranslationObserver = null;
        }
      };

      /// Watches for content added after the first translation — infinite
      /// scroll, a feed that rerenders, a comment box — and asks the host to
      /// translate just the new blocks.
      window.__velaStartTranslationObserver = function () {
        if (window.__velaTranslationObserver) { return; }
        var timer = null;
        function schedule() {
          if (timer) { return; }
          timer = window.setTimeout(function () {
            timer = null;
            if (window.__velaApplyingTranslation) { return; }
            try {
              var payload = window.__velaExtractUnits(
                document.body || document.documentElement,
                true
              );
              if (payload.units.length > 0 &&
                  window.webkit && window.webkit.messageHandlers &&
                  window.webkit.messageHandlers.\(Handler.translation.rawValue)) {
                window.webkit.messageHandlers.\(Handler.translation.rawValue).postMessage(payload);
              }
            } catch (_error) {
            }
          }, 260);
        }
        window.__velaTranslationObserver = new MutationObserver(function (mutations) {
          if (window.__velaApplyingTranslation) { return; }
          for (var i = 0; i < mutations.length; i++) {
            if (mutations[i].addedNodes && mutations[i].addedNodes.length > 0) {
              schedule();
              return;
            }
          }
        });
        window.__velaTranslationObserver.observe(
          document.body || document.documentElement,
          { childList: true, subtree: true }
        );
      };
    })();
    """

    /// Returns the page's translation units and a text sample for language
    /// detection. Expects `translationSupportScript` to have been evaluated.
    public static let textExtractionScript = """
    (function () {
      var payload = window.__velaExtractUnits
        ? window.__velaExtractUnits(document.body || document.documentElement, false)
        : { units: [], sample: '', url: String(window.location.href || ''), title: document.title || '' };
      return JSON.stringify(payload);
    })();
    """

    /// A short sample used to recognise the page's language without touching
    /// its text. Used by the translation bar's automatic offer.
    public static let textSampleScript = """
    (function () {
      function textOf(element) {
        return ((element && (element.innerText || element.textContent)) || '')
          .replace(/\\s+/g, ' ').trim();
      }

      /// The document's declared language, if it has one. This is a stronger
      /// signal than a two-word sample and covers pages whose body text is
      /// mostly navigation or numbers.
      function declaredLanguage() {
        try {
          var html = document.documentElement.getAttribute('lang') || '';
          var meta = document.querySelector(
            'meta[http-equiv="content-language" i], meta[name="language" i]'
          );
          var og = document.querySelector('meta[property="og:locale"]');
          return String(html || (meta && meta.content) || (og && og.content) || '');
        } catch (_error) {
          return '';
        }
      }

      // Prefer the article body when the site marks one; body text on a
      // navigation-heavy page is mostly menu labels and footer links.
      var selectors = [
        'article', 'main', '[role="main"]', '[itemprop="articleBody"]',
        '.article-content', '.article-body', '.post-content', '.entry-content',
        '.read-content', '#content', '.content'
      ];
      var best = '';
      for (var i = 0; i < selectors.length; i++) {
        var nodes = document.querySelectorAll(selectors[i]);
        for (var j = 0; j < nodes.length; j++) {
          var text = textOf(nodes[j]);
          if (text.length > best.length) { best = text; }
        }
      }
      var body = document.body || document.documentElement;
      var sample = best.length >= 200 ? best : textOf(body);
      return JSON.stringify({
        sample: sample.slice(0, 1200),
        url: String(window.location.href || ''),
        lang: declaredLanguage()
      });
    })();
    """

    /// Puts the page's own text back after a translation.
    public static let textRestoreScript = """
    (function () {
      if (typeof window.__velaRestoreTranslations === 'function') {
        return window.__velaRestoreTranslations();
      }
      return false;
    })();
    """
}
