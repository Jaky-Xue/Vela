//
//  WebPageScripts+Interaction.swift
//  Vela
//
//  The interaction scripts injected into pages, split from the base script
//  catalogue so each page-script area has its own file.
//

import Foundation

extension WebPageScripts {
    // MARK: - Element picker

    /// The element picker.
    ///
    /// The generated selector prefers a stable id, then a class combination,
    /// then a structural path. An auto-generated class such as `css-1x2y3z`
    /// changes on every deploy, so a rule built on one stops working; the
    /// structural path is ugly but is the only thing that survives.
    public static let elementPickerScript = """
    (function () {
      if (window.__velaElementPickerOverlay) { return; }
      window.__velaElementPickerOverlay = true;
      window.__velaElementPickerInstalled = true;

      // A full-screen transparent layer owned by the picker. It captures the
      // tap before an ad link can, and it is what lets a touch user see which
      // element is about to be selected: the element under the point is
      // outlined, and the outline stays until the confirmation is answered.
      var overlay = document.createElement('div');
      overlay.id = '__vela_picker_overlay__';
      overlay.style.cssText = 'position:fixed;inset:0;z-index:2147483647;' +
        'background:rgba(47,111,216,0.035);cursor:crosshair;touch-action:pan-y;';
      document.documentElement.appendChild(overlay);

      var highlighted = null;
      var previousOutline = '';
      var previousOffset = '';

      function elementAt(x, y) {
        overlay.style.pointerEvents = 'none';
        var element = document.elementFromPoint(x, y);
        overlay.style.pointerEvents = 'auto';
        return element;
      }

      function clearHighlight() {
        if (!highlighted) { return; }
        highlighted.style.outline = previousOutline;
        highlighted.style.outlineOffset = previousOffset;
        highlighted = null;
      }

      function highlight(element) {
        if (element === highlighted) { return; }
        clearHighlight();
        if (!element || element === document.documentElement ||
            element === document.body || element.id === '__vela_picker_overlay__') {
          return;
        }
        highlighted = element;
        previousOutline = element.style.outline;
        previousOffset = element.style.outlineOffset;
        element.style.outline = '2px solid #2f6fd8';
        element.style.outlineOffset = '1px';
      }

      function isGeneratedClass(name) {
        if (!name) { return false; }
        var first = name.charAt(0);
        return /^(css|sc|jsx|styled)-?[0-9a-z]{4,}$/i.test(name) ||
               /^[a-z]+-[0-9a-f]{6,}$/i.test(name) ||
               /^_[0-9a-z]{5,}$/i.test(name) ||
               (first >= '0' && first <= '9');
      }

      function stableClasses(element) {
        var list = [];
        var raw = String(element.className || '');
        var classes = raw.split(/\\s+/);
        for (var i = 0; i < classes.length; i++) {
          var name = classes[i].trim();
          if (!name || isGeneratedClass(name)) { continue; }
          list.push(name);
        }
        return list;
      }

      function selectorFor(element) {
        if (!element || element.nodeType !== 1) { return ''; }
        var id = element.getAttribute('id');
        if (id && !isGeneratedClass(id)) {
          return '#' + (window.CSS && CSS.escape ? CSS.escape(id) : id);
        }
        var classes = stableClasses(element);
        if (classes.length > 0) {
          var escaped = classes.map(function (name) {
            return '.' + (window.CSS && CSS.escape ? CSS.escape(name) : name);
          }).join('');
          try {
            if (document.querySelectorAll(escaped).length === 1) { return escaped; }
          } catch (_error) {
          }
          return element.tagName.toLowerCase() + escaped;
        }
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
        highlight(elementAt(event.clientX, event.clientY));
      }

      function onTap(event) {
        event.preventDefault();
        event.stopPropagation();
        var element = elementAt(event.clientX, event.clientY);
        if (!element || element === document.body || element === document.documentElement) {
          cleanup(false);
          return;
        }
        // Keep the outline: the confirmation sheet names the selector, and the
        // user can still see the exact region on the page behind it.
        highlight(element);
        var selector = selectorFor(element);
        var text = ((element.textContent || '').replace(/\\s+/g, ' ').trim()).slice(0, 120);
        try {
          if (window.webkit && window.webkit.messageHandlers &&
              window.webkit.messageHandlers.\(Handler.elementPick.rawValue)) {
            window.webkit.messageHandlers.\(Handler.elementPick.rawValue).postMessage({
              selector: selector,
              elementCount: selector ? document.querySelectorAll(selector).length : 0,
              tag: String(element.tagName || '').toLowerCase(),
              text: text
            });
          }
        } catch (_error) {
        }
        cleanup(false);
      }

      function cleanup(clear) {
        overlay.removeEventListener('pointermove', onMove, true);
        overlay.removeEventListener('mousemove', onMove, true);
        overlay.removeEventListener('click', onTap, true);
        if (overlay.parentNode) { overlay.parentNode.removeChild(overlay); }
        window.__velaElementPickerOverlay = false;
        window.__velaElementPickerInstalled = false;
        if (clear) { clearHighlight(); }
      }

      overlay.addEventListener('pointermove', onMove, true);
      overlay.addEventListener('mousemove', onMove, true);
      overlay.addEventListener('click', onTap, true);

      window.__velaElementPickerStop = function () { cleanup(true); };
      window.__velaElementPickerClear = function () { clearHighlight(); };
    })();
    """

    public static let stopElementPickerScript = """
    (function () {
      if (typeof window.__velaElementPickerStop === 'function') {
        window.__velaElementPickerStop();
      }
    })();
    """

}
