//
//  ReaderView.swift
//  Vela
//
//  The reading surface.
//
//  The article is rendered with the native text system, which is what makes
//  Dynamic Type, VoiceOver and text selection work without the page having to
//  cooperate. The extracted HTML still renders in a `WKWebView` with a stylesheet
//  built from the user's font size and colour scheme, because the source has
//  structure — headings, lists, figures, tables — that flattening to plain text
//  would destroy.
//

import SwiftUI
import UIKit
import WebKit

struct ReaderView: View {
    @Environment(\.browserPalette) private var palette
    @Environment(\.colorScheme) private var systemScheme
    @Environment(\.dismiss) private var dismiss

    var article: ReaderArticle
    var onClose: () -> Void

    @State private var fontSize: Double = 18
    @State private var appearance: ReaderAppearance = .system

    var body: some View {
        VStack(spacing: 0) {
            header
            ReaderWebView(html: styledHtml)
        }
        .browserSurfaceBackground(opacity: 0.40)
    }

    private var header: some View {
        HStack(spacing: BrowserSpacing.compact) {
            Button {
                onClose()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(palette.secondaryText)
                    .frame(width: 28, height: 28)
                    .background(palette.controlFill, in: Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("关闭阅读模式")

            VStack(alignment: .leading, spacing: 1) {
                Text(article.title.isEmpty ? "阅读模式" : article.title)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(palette.primaryText)
                    .lineLimit(1)
                if !article.byline.isEmpty {
                    Text(article.byline)
                        .font(.caption)
                        .foregroundStyle(palette.secondaryText)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 0)

            Text("约 \(article.estimatedReadingMinutes) 分钟")
                .font(.caption)
                .foregroundStyle(palette.secondaryText)
                .monospacedDigit()

            Menu {
                Section("字号") {
                    Button("小") { fontSize = 15 }
                    Button("中") { fontSize = 18 }
                    Button("大") { fontSize = 21 }
                    Button("特大") { fontSize = 24 }
                }
                Section("外观") {
                    ForEach(ReaderAppearance.allCases) { option in
                        Button {
                            appearance = option
                        } label: {
                            if appearance == option {
                                Label(option.displayName, systemImage: "checkmark")
                            } else {
                                Text(option.displayName)
                            }
                        }
                    }
                }
                Divider()
                Button("分享", systemImage: "square.and.arrow.up") {
                    guard let url = URL(string: article.url) else { return }
                    presentShareSheet(url: url)
                }
            } label: {
                Image(systemName: "textformat.size")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(palette.primaryText)
                    .frame(width: 28, height: 28)
                    .background(palette.controlFill, in: Circle())
            }
            .accessibilityLabel("阅读设置")
        }
        .padding(.horizontal, BrowserSpacing.compact + 2)
        .padding(.vertical, BrowserSpacing.tight)
        // The same floating panel as the browser's own chrome, so entering
        // reader mode changes the document rather than the application.
        .browserFloatingChrome(
            radius: BrowserRadius.card,
            material: .regularMaterial,
            tintStrength: 0.5,
            elevation: .card
        )
        .padding(.horizontal, BrowserChrome.sideInset)
        .padding(.top, BrowserChrome.topInset)
        .padding(.bottom, BrowserSpacing.tight)
    }

    /// The article HTML with a reading stylesheet around it.
    ///
    /// `-apple-system` and `-apple-system-systemBackground` are the CSS
    /// spellings of the system font and background, so the reader inherits the
    /// user's Dynamic Type setting and switches with the system appearance
    /// without Vela having to sample anything.
    private var styledHtml: String {
        let scheme = resolvedScheme == .dark ? "dark" : "light"
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

    /// The appearance the article is rendered in.
    ///
    /// `跟随系统` resolves against the environment rather than being a third
    /// fixed mode, and it is the default. The menu used to offer "跟随系统" and
    /// "深色" against a single `isDark` flag, so choosing "跟随系统" forced the
    /// light stylesheet — the one option that names the system was the one
    /// ignoring it.
    private var resolvedScheme: ColorScheme {
        appearance.colorScheme ?? systemScheme
    }

    private func presentShareSheet(url: URL) {
        guard let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
              let root = scene.keyWindow?.rootViewController else { return }
        let controller = UIActivityViewController(activityItems: [url], applicationActivities: nil)
        root.present(controller, animated: true)
    }
}

/// The reading appearance.
///
/// The same three-way choice the app-wide setting offers, for the same reason:
/// "follow the system" is a real mode, not a synonym for "light".
private enum ReaderAppearance: String, CaseIterable, Identifiable {
    case system
    case light
    case dark

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .system: return "跟随系统"
        case .light: return "浅色"
        case .dark: return "深色"
        }
    }

    /// `nil` is what makes `跟随系统` follow rather than decide.
    var colorScheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .light: return .light
        case .dark: return .dark
        }
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
