//
//  ReaderView.swift
//  Vela
//
//  The reading surface. Ported from `ReaderModeApplication.ets` and
//  `BrowserArticleReaderViewModel` under `core/browser/`
//  (Aira Browser 3.7.4, GPL-3.0).
//
//  Aira renders the article through ArkWeb with a template; Vela renders it with
//  the native text system, which is what makes Dynamic Type, VoiceOver and text
//  selection work without a page having to cooperate. The extracted HTML is
//  rendered in a `WKWebView` with a stylesheet built from the user's font size
//  and colour scheme, because the source HTML has structure — headings, lists,
//  figures, tables — that flattening to plain text would destroy.
//

import SwiftUI
import UIKit
import WebKit

struct ReaderView: View {
    @Environment(\.browserPalette) private var palette
    @Environment(\.dismiss) private var dismiss

    var article: ReaderArticle
    var onClose: () -> Void

    @State private var fontSize: Double = 18
    @State private var isDark: Bool = false
    @State private var showOriginal = false

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ReaderWebView(html: styledHtml, isDark: isDark)
        }
        .background(palette.surface)
    }

    private var header: some View {
        HStack(spacing: 12) {
            Button {
                onClose()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 15, weight: .medium))
            }
            .buttonStyle(.plain)

            VStack(alignment: .leading, spacing: 1) {
                Text(article.title.isEmpty ? "阅读模式" : article.title)
                    .font(.system(size: 15, weight: .semibold))
                    .lineLimit(1)
                if !article.byline.isEmpty {
                    Text(article.byline)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 0)

            Menu {
                Section("字号") {
                    Button("小") { fontSize = 15 }
                    Button("中") { fontSize = 18 }
                    Button("大") { fontSize = 21 }
                    Button("特大") { fontSize = 24 }
                }
                Section("外观") {
                    Button("跟随系统") { isDark = false }
                    Button("深色") { isDark = true }
                }
                Divider()
                Button("分享", systemImage: "square.and.arrow.up") {
                    guard let url = URL(string: article.url) else { return }
                    presentShareSheet(url: url)
                }
            } label: {
                Image(systemName: "textformat.size")
                    .font(.system(size: 15, weight: .medium))
            }

            Text("约 \(article.estimatedReadingMinutes) 分钟")
                .font(.caption)
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.bar)
    }

    /// The article HTML with a reading stylesheet around it.
    ///
    /// `-apple-system` and `-apple-system-systemBackground` are the CSS
    /// spellings of the system font and background, so the reader inherits the
    /// user's Dynamic Type setting and switches with the system appearance
    /// without Vela having to sample anything.
    private var styledHtml: String {
        let scheme = isDark ? "dark" : "light"
        return """
        <!doctype html>
        <html>
        <head>
          <meta charset="utf-8">
          <meta name="viewport" content="width=device-width, initial-scale=1, viewport-fit=cover">
          <meta name="color-scheme" content="\(scheme)">
          <style>
            :root { color-scheme: \(scheme); }
            body {
              margin: 0;
              padding: 20px 20px 60px 20px;
              font-family: -apple-system, "PingFang SC", system-ui, sans-serif;
              font-size: \(Int(fontSize))px;
              line-height: 1.75;
              color: -apple-system-label;
              background: -apple-system-systemBackground;
              -webkit-text-size-adjust: 100%;
              word-wrap: break-word;
            }
            h1, h2, h3, h4 {
              line-height: 1.35;
              margin: 1.6em 0 0.6em 0;
              font-weight: 600;
            }
            h1 { font-size: 1.5em; margin-top: 0.4em; }
            h2 { font-size: 1.25em; }
            h3 { font-size: 1.1em; }
            p { margin: 0 0 1.1em 0; }
            a { color: -apple-system-link; text-decoration: none; }
            img, video, figure {
              max-width: 100%;
              height: auto;
              display: block;
              margin: 1.2em auto;
              border-radius: 8px;
            }
            blockquote {
              margin: 1.2em 0;
              padding: 0.4em 1em;
              border-left: 3px solid -apple-system-separator;
              color: -apple-system-secondaryLabel;
            }
            pre, code {
              font-family: ui-monospace, "SF Mono", Menlo, monospace;
              font-size: 0.9em;
              background: -apple-system-secondarySystemBackground;
              border-radius: 6px;
            }
            pre { padding: 0.9em; overflow-x: auto; }
            code { padding: 0.15em 0.35em; }
            pre code { padding: 0; background: none; }
            table {
              width: 100%;
              border-collapse: collapse;
              margin: 1.2em 0;
              font-size: 0.92em;
            }
            th, td {
              border: 1px solid -apple-system-separator;
              padding: 0.5em 0.7em;
              text-align: left;
            }
            hr {
              border: none;
              border-top: 1px solid -apple-system-separator;
              margin: 2em 0;
            }
            ul, ol { padding-left: 1.4em; }
            li { margin: 0.4em 0; }
          </style>
        </head>
        <body>
        \(article.contentHtml)
        </body>
        </html>
        """
    }

    private func presentShareSheet(url: URL) {
        guard let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
              let root = scene.keyWindow?.rootViewController else { return }
        let controller = UIActivityViewController(activityItems: [url], applicationActivities: nil)
        root.present(controller, animated: true)
    }
}

/// Renders the article HTML.
///
/// Navigation inside the reader is cancelled rather than allowed: tapping a link
/// in the extracted copy should leave reader mode and load the link in the
/// browser, not navigate the reader's own web view to a site with no chrome
/// around it.
private struct ReaderWebView: UIViewRepresentable {
    var html: String
    var isDark: Bool

    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        webView.scrollView.contentInsetAdjustmentBehavior = .always
        webView.isOpaque = false
        webView.backgroundColor = .clear
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        webView.loadHTMLString(html, baseURL: nil)
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    final class Coordinator: NSObject, WKNavigationDelegate {
        func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationAction: WKNavigationAction,
            decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
        ) {
            // The initial `loadHTMLString` arrives as `.other` with no URL, and
            // must be allowed; anything the user tapped is a link and is not.
            if navigationAction.navigationType == .other, navigationAction.request.url == nil {
                decisionHandler(.allow)
                return
            }
            if let url = navigationAction.request.url, url.scheme == "about" {
                decisionHandler(.allow)
                return
            }
            decisionHandler(.cancel)
        }
    }
}
