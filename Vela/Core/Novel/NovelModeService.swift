//
//  NovelModeService.swift
//  Vela
//
//  Chapter extraction for novel mode.
//
//  Reader mode's algorithm scores paragraphs and picks a container; that is
//  right for an article but wrong for a novel chapter, where the text is one
//  long stream of `<br>`-separated lines and the surrounding page is a table of
//  navigation links. This extractor therefore works from the containers novel
//  sites actually use (`#content`, `#chaptercontent`, `.read-content`, …),
//  scores them by prose length minus link density, and reads the chapter's
//  neighbours from the links around it.
//
//  The extraction is deliberately conservative: under 200 characters of text is
//  not a chapter, and returning nil is what lets the shell say "this page does
//  not look like a chapter" instead of opening an empty reader.
//

import Foundation
import WebKit

enum NovelModeService {
    /// Extracts one chapter from a live web view.
    static func extract(from webView: WKWebView, url: String) async -> NovelExtraction? {
        do {
            let result = try await webView.evaluateJavaScript(extractionScript)
            return decode(result, url: url)
        } catch {
            return nil
        }
    }

    /// Decodes the script's JSON payload.
    static func decode(_ result: Any?, url: String) -> NovelExtraction? {
        guard let json = result as? String,
              let data = json.data(using: .utf8),
              let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let contentHtml = payload["content"] as? String,
              !contentHtml.isEmpty else {
            return nil
        }

        let plain = contentHtml.replacingOccurrences(
            of: "<[^>]+>",
            with: "",
            options: .regularExpression
        ).trimmingCharacters(in: .whitespacesAndNewlines)

        // A chapter has a body. A page that merely has a container is not one.
        guard plain.count >= 200 else { return nil }

        let chapterTitle = (payload["chapterTitle"] as? String)?.trimmed ?? ""
        let bookTitle = (payload["bookTitle"] as? String)?.trimmed ?? ""
        let author = (payload["author"] as? String)?.trimmed ?? ""

        return NovelExtraction(
            bookTitle: bookTitle.isEmpty ? chapterTitle : bookTitle,
            author: author,
            chapterTitle: chapterTitle.isEmpty ? "正文" : chapterTitle,
            contentHtml: contentHtml,
            chapterUrl: url,
            previousUrl: (payload["previousUrl"] as? String)?.trimmed ?? "",
            nextUrl: (payload["nextUrl"] as? String)?.trimmed ?? "",
            tocUrl: (payload["tocUrl"] as? String)?.trimmed ?? ""
        )
    }

    /// A cheap pre-check so 小说模式 on an obviously non-novel page fails
    /// instantly rather than after a script round-trip.
    ///
    /// Deliberately permissive: a novel can live on any host, so this only
    /// rejects the shapes that never are one — a bare domain, and a search
    /// results page.
    static func isLikelyNovel(_ url: String) -> Bool {
        guard let parsed = URL(string: url), parsed.host != nil else { return false }
        let path = parsed.path.lowercased()
        if path.isEmpty || path == "/" { return false }
        if path.contains("search") || path.contains("query") || path.contains("login") {
            return false
        }
        return true
    }

    /// The extraction script. It returns a JSON string, because
    /// `evaluateJavaScript` bridges objects inconsistently across WebKit
    /// versions and a string is unambiguous.
    static let extractionScript = """
    (function () {
      function textOf(element) {
        return ((element && element.textContent) || '').replace(/\\s+/g, ' ').trim();
      }

      function linkDensity(element) {
        var text = textOf(element);
        if (!text) { return 1; }
        var linkText = 0;
        var anchors = element.querySelectorAll('a');
        for (var i = 0; i < anchors.length; i++) {
          linkText += textOf(anchors[i]).length;
        }
        return Math.min(1, linkText / text.length);
      }

      function absolute(href) {
        if (!href) { return ''; }
        try {
          var url = new URL(href, document.baseURI);
          if (url.protocol !== 'http:' && url.protocol !== 'https:') { return ''; }
          return url.href;
        } catch (error) {
          return '';
        }
      }

      function meta(property) {
        var element = document.querySelector(
          'meta[property="' + property + '"], meta[name="' + property + '"]'
        );
        return element ? String(element.getAttribute('content') || '').trim() : '';
      }

      function firstText(selectors) {
        for (var i = 0; i < selectors.length; i++) {
          var element = document.querySelector(selectors[i]);
          var text = textOf(element);
          if (text) { return text; }
        }
        return '';
      }

      // MARK: Content container

      var selectors = [
        '#content', '#chaptercontent', '#chapter-content', '#booktext',
        '#htmlContent', '#txtContent', '#chapterContent', '#bookContent',
        '.read-content', '.chapter-content', '.article-content', '.content',
        '.showtxt', '.txtnav', '.yd_text2', '.read-content', '.novel-content',
        '.chapter-body', '.read-content', 'article', '[role="main"]'
      ];

      var best = null;
      var bestScore = 0;
      for (var i = 0; i < selectors.length; i++) {
        var candidates = document.querySelectorAll(selectors[i]);
        for (var j = 0; j < candidates.length; j++) {
          var element = candidates[j];
          var text = textOf(element);
          if (text.length < 120) { continue; }
          var score = text.length * (1 - linkDensity(element));
          if (element.tagName === 'ARTICLE') { score *= 1.08; }
          if (element.tagName === 'BODY' || element.tagName === 'HTML') { score *= 0.05; }
          if (score > bestScore) {
            bestScore = score;
            best = element;
          }
        }
      }

      if (!best) {
        return JSON.stringify({ content: '' });
      }

      // MARK: Cleaning

      var clone = best.cloneNode(true);
      var junkSelectors = [
        'script', 'style', 'noscript', 'iframe', 'svg', 'canvas', 'form',
        'button', 'input', 'select', 'textarea', 'nav', 'aside', 'footer',
        'header', '.ad', '.ads', '.advertisement', '.adsbygoogle',
        '[class*="advert"]', '[class*="recommend"]', '[class*="related"]',
        '[class*="comment"]', '[class*="toolbar"]', '[class*="pagination"]',
        '[class*="chapter-nav"]', '[class*="read-nav"]', '[class*="banner"]',
        '[class*="popup"]', '[id*="advert"]', '[id*="recommend"]',
        '[id*="comment"]', '[id*="toolbar"]'
      ];
      for (var k = 0; k < junkSelectors.length; k++) {
        var junk = clone.querySelectorAll(junkSelectors[k]);
        for (var m = junk.length - 1; m >= 0; m--) {
          if (junk[m].parentNode) { junk[m].parentNode.removeChild(junk[m]); }
        }
      }

      // Drop empty wrappers left behind by the removals, but keep media.
      var empties = clone.querySelectorAll('div, section, span, p');
      for (var n = empties.length - 1; n >= 0; n--) {
        var item = empties[n];
        if (textOf(item).length === 0 &&
            item.querySelectorAll('img, video, picture, audio').length === 0) {
          if (item.parentNode) { item.parentNode.removeChild(item); }
        }
      }

      // Lazy-loaded images keep their URL in a data attribute, and the
      // extraction document has no base URL, so every source is resolved
      // before the data-* attributes are stripped below.
      var images = clone.querySelectorAll('img');
      for (var r = 0; r < images.length; r++) {
        var image = images[r];
        var source = absolute(
          image.getAttribute('src') ||
          image.getAttribute('data-src') ||
          image.getAttribute('data-original') ||
          image.getAttribute('data-lazy-src') || ''
        );
        if (source) { image.setAttribute('src', source); }
      }

      // Strip attributes that could restyle the copy or track it.
      var all = clone.querySelectorAll('*');
      for (var p = 0; p < all.length; p++) {
        var node = all[p];
        var attributes = node.attributes;
        for (var q = attributes.length - 1; q >= 0; q--) {
          var name = attributes[q].name.toLowerCase();
          if (name === 'class' || name === 'id' || name === 'style' ||
              name.indexOf('on') === 0 || name.indexOf('data-') === 0) {
            node.removeAttribute(attributes[q].name);
          }
        }
      }

      var content = clone.innerHTML || '';
      if (textOf(clone).length < 200) {
        content = '';
      }

      // MARK: Chapter navigation

      function linkFor(pattern) {
        var anchors = document.querySelectorAll('a');
        for (var i = 0; i < anchors.length; i++) {
          var anchor = anchors[i];
          var label = textOf(anchor).replace(/\\s+/g, '');
          if (!label || label.length > 12) { continue; }
          if (!pattern.test(label)) { continue; }
          var href = absolute(anchor.getAttribute('href'));
          if (href && href !== String(location.href)) { return href; }
        }
        return '';
      }

      function relLink(rel) {
        var anchor = document.querySelector('a[rel~="' + rel + '"]');
        return anchor ? absolute(anchor.getAttribute('href')) : '';
      }

      var nextUrl = linkFor(/^(下一[章节页]|下章|下一页|下一張|next(\\s*chapter)?)$/i) ||
                    relLink('next');
      var previousUrl = linkFor(/^(上一[章节页]|上章|上一页|上一張|prev(ious)?(\\s*chapter)?)$/i) ||
                        relLink('prev');
      var tocUrl = linkFor(/^(目录|章节目录|返回目录|全部章节|章节列表|index|contents)$/i);

      // MARK: Titles

      var chapterTitle = meta('og:novel:chapter_name') ||
                         firstText([
                           '.chapter-title', '#chaptertitle', '#chapterTitle',
                           '.chapter-name', '.title', '.bookname h1', 'h1'
                         ]);

      var documentTitle = String(document.title || '').trim();
      if (!chapterTitle && documentTitle) {
        chapterTitle = documentTitle.split(/[_|\\-—]/)[0].trim();
      }

      var bookTitle = meta('og:novel:book_name') ||
                      meta('og:book:title') ||
                      meta('book:title') ||
                      firstText([
                        '.bookname h1', '.book-name', '.book-title',
                        '#bookname', '#info h1', '.book_info h1', '.book-info h1'
                      ]);

      // Document titles are usually "书名 - 第x章 标题" or the reverse. Pick
      // the segment that is not a chapter heading as the book.
      if (!bookTitle && documentTitle) {
        var segments = documentTitle.split(/[_|\\-—]/);
        for (var s = 0; s < segments.length; s++) {
          var segment = segments[s].trim();
          if (segment.length < 2) { continue; }
          if (/第?\\s*\\d+\\s*[章节回]|章|节|卷/.test(segment)) { continue; }
          if (segment === chapterTitle) { continue; }
          bookTitle = segment;
          break;
        }
      }
      if (!bookTitle) { bookTitle = meta('og:site_name'); }
      if (!bookTitle) { bookTitle = chapterTitle; }

      var author = meta('og:novel:author') || meta('book:author');
      if (!author) {
        var infoText = firstText(['#info', '.book-info', '.book_info', '.author']);
        if (infoText) {
          var match = infoText.match(/作\\s*者\\s*[:：]\\s*([^\\s,，|/]{1,40})/);
          if (match) { author = match[1]; }
        }
      }

      return JSON.stringify({
        bookTitle: bookTitle || '',
        chapterTitle: chapterTitle || '',
        author: author || '',
        content: content,
        previousUrl: previousUrl || '',
        nextUrl: nextUrl || '',
        tocUrl: tocUrl || ''
      });
    })();
    """
}

private extension String {
    var trimmed: String {
        trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
