//
//  ReaderModeService.swift
//  Vela
//
//  Article extraction for reader mode. Ported from the role of
//  `AiraBrowser/entry/src/main/ets/services/reader/ReaderExtractionService.ets`
//  and `ReaderEligibilityService.ets` (Aira Browser 3.7.4, GPL-3.0).
//
//  Aira bundles Mozilla Readability (`third_party/mozilla-readability`) and runs
//  it in the page. Vela implements the same scoring idea directly, because the
//  bundled copy in the upstream tree ships only its licence and readme — there
//  is no script to carry over — and because Readability's own heuristics are a
//  well-known algorithm that is straightforward to express:
//
//    1. Score every paragraph by text length, comma count and link density.
//    2. Credit each paragraph's score to its parent and grandparent.
//    3. Pick the highest-scoring ancestor with a positive score.
//    4. Reject the result when it is too short to be an article.
//
//  The link-density term is what stops a navigation list from winning: an index
//  page has long paragraphs too, but most of their text is inside anchors.
//

import Foundation
import WebKit

/// A extracted article.
struct ReaderArticle: Equatable, Sendable {
    var title: String
    var byline: String
    var contentHtml: String
    var url: String

    var wordCount: Int {
        // A rough count over the extracted HTML. Aira counts characters for its
        // reading-time estimate; CJK text has no spaces, so counting characters
        // is the only measure that works for both scripts.
        contentHtml.reduce(into: 0) { count, character in
            if character.isLetter || character.isNumber { count += 1 }
        }
    }

    var estimatedReadingMinutes: Int {
        // 400 CJK characters per minute is the commonly used figure, and it is
        // close enough to 200 English words per minute that one number serves
        // both.
        max(1, wordCount / 400)
    }
}

enum ReaderModeService {
    /// Extracts the article from a live web view.
    static func extract(from webView: WKWebView, url: String) async -> ReaderArticle? {
        let result: Any?
        do {
            result = try await webView.evaluateJavaScript(extractionScript)
        } catch {
            return nil
        }

        guard let json = result as? String,
              let data = json.data(using: .utf8),
              let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let contentHtml = payload["content"] as? String,
              !contentHtml.isEmpty else {
            return nil
        }

        let title = (payload["title"] as? String) ?? ""
        let byline = (payload["byline"] as? String) ?? ""

        return ReaderArticle(
            title: title.trimmingCharacters(in: .whitespacesAndNewlines),
            byline: byline.trimmingCharacters(in: .whitespacesAndNewlines),
            contentHtml: contentHtml,
            url: url
        )
    }

    /// The extraction script. Returns a JSON string, because
    /// `evaluateJavaScript` bridges a plain object inconsistently across
    /// WebKit versions and a string is unambiguous.
    static let extractionScript = """
    (function () {
      function textLength(element) {
        return (element.textContent || '').replace(/\\s+/g, ' ').trim().length;
      }

      function linkDensity(element) {
        var text = textLength(element);
        if (text === 0) { return 0; }
        var linkText = 0;
        var anchors = element.querySelectorAll('a');
        for (var i = 0; i < anchors.length; i++) {
          linkText += textLength(anchors[i]);
        }
        return linkText / text;
      }

      function classNameWeight(element) {
        var name = ((element.className || '') + ' ' + (element.id || '')).toLowerCase();
        var weight = 0;
        // Positive signals.
        if (/article|content|post|entry|main|body|story|text/.test(name)) { weight += 25; }
        // Negative signals. These are the containers that routinely outscore a
        // real article on length alone.
        if (/comment|sidebar|footer|header|nav|menu|share|related|promo|ad-|广告|推荐|评论/.test(name)) {
          weight -= 35;
        }
        return weight;
      }

      function scoreParagraph(element) {
        var text = (element.textContent || '').trim();
        if (text.length < 30) { return 0; }

        var score = 0;
        // Base: length, capped so one enormous paragraph cannot dominate.
        score += Math.min(text.length / 100, 30);
        // Commas are a strong proxy for prose over markup or a list.
        score += (text.match(/[，,]/g) || []).length;
        // Penalise link-heavy paragraphs, which are navigation rather than prose.
        var density = linkDensity(element);
        score *= (1 - density);
        // A paragraph with substantial text should not be thrown away just
        // because a site wraps every sentence in a link.
        if (density > 0.8 && text.length < 120) { score = 0; }
        return score;
      }

      var paragraphs = document.querySelectorAll('p, article > div, section > div, .content p');
      var scores = new Map();

      for (var i = 0; i < paragraphs.length; i++) {
        var paragraph = paragraphs[i];
        var score = scoreParagraph(paragraph);
        if (score <= 0) { continue; }

        // Credit the paragraph's parent fully and its grandparent at half.
        var parent = paragraph.parentNode;
        if (parent && parent.nodeType === 1) {
          scores.set(parent, (scores.get(parent) || 0) + score);
          var grandparent = parent.parentNode;
          if (grandparent && grandparent.nodeType === 1) {
            scores.set(grandparent, (scores.get(grandparent) || 0) + score / 2);
          }
        }
      }

      var best = null;
      var bestScore = 0;
      scores.forEach(function (score, element) {
        var adjusted = score + classNameWeight(element);
        // An article is never a whole page or a single paragraph.
        if (element.tagName === 'BODY' || element.tagName === 'HTML') { adjusted -= 50; }
        if (adjusted > bestScore) {
          bestScore = adjusted;
          best = element;
        }
      });

      // Fall back to `<article>` when the scoring found nothing, which happens
      // on a site that marks its content up semantically but uses short
      // paragraphs.
      if (!best) {
        best = document.querySelector('article') || document.querySelector('[role="main"]');
      }
      if (!best) {
        return JSON.stringify({ title: document.title || '', byline: '', content: '' });
      }

      var content = best.cloneNode(true);

      // Strip the parts that are never article content.
      var junk = content.querySelectorAll(
        'script, style, noscript, iframe, form, nav, aside, footer, header, button, ' +
        '.ad, .ads, .advertisement, [class*="share"], [class*="comment"], [class*="related"], ' +
        '[class*="recommend"], [class*="promo"], [class*="newsletter"]'
      );
      for (var j = junk.length - 1; j >= 0; j--) {
        if (junk[j].parentNode) { junk[j].parentNode.removeChild(junk[j]); }
      }

      // Drop attributes that would let the page restyle or track the copy.
      var all = content.querySelectorAll('*');
      for (var k = 0; k < all.length; k++) {
        var element = all[k];
        var attributes = element.attributes;
        for (var a = attributes.length - 1; a >= 0; a--) {
          var name = attributes[a].name.toLowerCase();
          if (name === 'class' || name === 'id' || name === 'style' ||
              name.indexOf('on') === 0 || name.indexOf('data-') === 0) {
            element.removeAttribute(attributes[a].name);
          }
        }
      }

      // Remove empty containers, which the clones above leave behind.
      var empties = content.querySelectorAll('div, section, span');
      for (var m = empties.length - 1; m >= 0; m--) {
        if ((empties[m].textContent || '').trim().length === 0 &&
            empties[m].querySelectorAll('img, video, picture').length === 0) {
          if (empties[m].parentNode) { empties[m].parentNode.removeChild(empties[m]); }
        }
      }

      // A byline is worth showing when the page marks one up.
      var byline = '';
      var bylineElement = document.querySelector('[rel="author"], .author, .byline, [class*="byline"]');
      if (bylineElement) { byline = (bylineElement.textContent || '').trim().slice(0, 120); }

      var title = '';
      var heading = document.querySelector('h1');
      if (heading) { title = (heading.textContent || '').trim(); }
      if (!title) {
        var metaTitle = document.querySelector('meta[property="og:title"]');
        title = metaTitle ? String(metaTitle.getAttribute('content') || '') : (document.title || '');
      }

      var html = content.innerHTML || '';
      // Under 400 characters is a fragment, not an article. Ported from the
      // length gate in `ReaderEligibilityService`.
      if (html.replace(/<[^>]*>/g, '').trim().length < 400) {
        return JSON.stringify({ title: title, byline: byline, content: '' });
      }

      return JSON.stringify({
        title: title,
        byline: byline,
        content: html
      });
    })();
    """

    /// Whether reader mode should be offered for a page.
    ///
    /// Ported from `ReaderEligibilityService`: the button is enabled from the
    /// URL alone, and the real decision happens at extraction. Checking the URL
    /// for article-shaped paths first avoids offering the mode on a search
    /// results page, where extraction would fail and the failure would look like
    /// a bug.
    static func isLikelyArticle(_ url: String) -> Bool {
        guard let parsed = URL(string: url), let host = parsed.host else { return false }
        let path = parsed.path.lowercased()

        // A bare domain is a home page, never an article.
        if path.isEmpty || path == "/" { return false }

        let articleShapes = ["/article", "/post", "/news", "/story", "/p/", "/blog/", "/archives/", "/wiki/"]
        if articleShapes.contains(where: { path.contains($0) }) { return true }

        // A long numeric or slug-like tail is usually a content page.
        let segments = path.split(separator: "/")
        if let last = segments.last, last.count > 12, last.contains("-") { return true }
        if segments.contains(where: { $0.count > 6 && $0.allSatisfy(\.isNumber) }) { return true }

        // Known article-heavy hosts.
        let articleHosts = ["zhihu.com", "juejin.cn", "csdn.net", "medium.com", "substack.com",
                            "sspai.com", "cnblogs.com", "infoq.cn", "36kr.com", "wikipedia.org"]
        if articleHosts.contains(where: { host == $0 || host.hasSuffix("." + $0) }) { return true }

        return false
    }
}
