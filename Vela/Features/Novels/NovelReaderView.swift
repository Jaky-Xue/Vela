//
//  NovelReaderView.swift
//  Vela
//
//  The novel reading surface.
//
//  It sits in the shell's hierarchy rather than in a presented controller, the
//  same rule the tab overview follows: a layer rotates with the window, while a
//  presented controller can keep its pre-rotation geometry. The chapter itself
//  renders in a web view because novel markup is structure — paragraphs,
//  emphasis, an occasional illustration — and flattening it to plain text would
//  throw that away.
//
//  Reading position is a fraction of the chapter, reported by a small scroll
//  listener and restored on the next visit. The paper behind the text is
//  translucent, so the app's ambient background is visible inside the reader
//  as well as around it.
//

import SwiftUI
import UIKit
import WebKit

struct NovelReaderView: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.browserPalette) private var palette
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.scenePhase) private var scenePhase

    var onClose: () -> Void
    var onOpenInBrowser: (URL) -> Void

    @State private var currentBook: NovelBook
    @State private var chapter: NovelChapter?
    @State private var isLoading = false
    @State private var statusMessage: String?
    @State private var progress: Double = 0
    @State private var lastSavedAt = Date.distantPast
    @State private var fontSize: Double = 19
    @State private var appearance: NovelReadingAppearance = .system
    @State private var loader = NovelChapterLoader()

    init(
        book: NovelBook,
        initialChapter: NovelChapter?,
        onClose: @escaping () -> Void,
        onOpenInBrowser: @escaping (URL) -> Void
    ) {
        self.onClose = onClose
        self.onOpenInBrowser = onOpenInBrowser
        _currentBook = State(initialValue: book)
        _chapter = State(initialValue: initialChapter)
        _progress = State(initialValue: book.progress)
    }

    var body: some View {
        ZStack {
            AmbientSurfaceFill(opacity: 0.88)
                .ignoresSafeArea()

            VStack(spacing: 0) {
                headerInGlassContainer

                Group {
                    if let chapter {
                        NovelChapterWebView(
                            html: styledHtml(for: chapter),
                            initialProgress: progress,
                            onProgress: handleProgress
                        )
                        .id(chapter.url)
                    } else if isLoading {
                        VStack(spacing: 12) {
                            ProgressView()
                            Text("正在载入章节…")
                                .font(.footnote)
                                .foregroundStyle(palette.secondaryText)
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else {
                        EmptyState(
                            systemImage: "book.closed",
                            title: "无法打开这一章",
                            message: statusMessage ?? "这一页没有可阅读的正文，可能需要在浏览器中打开。",
                            actionTitle: "在浏览器中打开",
                            action: openCurrentInBrowser
                        )
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .safeAreaInset(edge: .bottom) { bottomBarInGlassContainer }
        .task { await prepare() }
        .onDisappear {
            saveNow()
            loader.cancel()
        }
        .onChange(of: scenePhase) { _, phase in
            // The reader is not necessarily removed from the hierarchy when
            // the app is backgrounded, so leaving without an `onDisappear`
            // would lose the last couple of seconds of scrolling.
            if phase != .active { saveNow() }
        }
        .alert(
            "无法载入章节",
            isPresented: Binding(
                get: { statusMessage != nil && chapter != nil },
                set: { if !$0 { statusMessage = nil } }
            )
        ) {
            Button("好") { statusMessage = nil }
        } message: {
            Text(statusMessage ?? "")
        }
    }

    // MARK: - Chrome

    private var header: some View {
        HStack(spacing: BrowserSpacing.compact) {
            Button {
                close()
            } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 15, weight: .semibold))
                    .frame(width: 32, height: 32)
                    .contentShape(Rectangle())
            }
            .buttonStyle(ChromeButtonStyle())
            .foregroundStyle(palette.primaryText)
            .accessibilityLabel("关闭小说模式")

            VStack(alignment: .leading, spacing: 1) {
                Text(currentBook.title.isEmpty ? "小说" : currentBook.title)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(palette.primaryText)
                    .lineLimit(1)
                Text(chapter?.title ?? "正在载入…")
                    .font(.caption2)
                    .foregroundStyle(palette.secondaryText)
                    .lineLimit(1)
            }

            Spacer(minLength: 0)

            if isLoading {
                ProgressView()
                    .controlSize(.small)
            }

            Menu {
                Section("字号") {
                    ForEach([16.0, 19.0, 22.0, 25.0], id: \.self) { size in
                        Button {
                            setFontSize(size)
                        } label: {
                            if abs(fontSize - size) < 0.1 {
                                Label(sizeLabel(size), systemImage: "checkmark")
                            } else {
                                Text(sizeLabel(size))
                            }
                        }
                    }
                }
                Section("外观") {
                    ForEach(NovelReadingAppearance.allCases) { option in
                        Button {
                            appearance = option
                            env.settings.update { $0.readerAppearance = option.rawValue }
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
                Button("在浏览器中打开本章", systemImage: "safari") {
                    openCurrentInBrowser()
                }
                .disabled(currentBook.currentChapterUrl.isEmpty)
            } label: {
                Image(systemName: "textformat.size")
                    .font(.system(size: 15, weight: .semibold))
                    .frame(width: 32, height: 32)
                    .contentShape(Rectangle())
            }
            .foregroundStyle(palette.primaryText)
            .accessibilityLabel("阅读设置")
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .browserFloatingChrome(
            radius: BrowserRadius.card,
            material: .regularMaterial,
            tintStrength: 0.45,
            elevation: .card
        )
        .padding(.horizontal, BrowserChrome.sideInset)
        .padding(.top, 6)
    }

    /// The header's glass rides one coordinated layer, the same rule the
    /// browser's command bar follows: a shape on its own system layer can be
    /// left at its pre-rotation frame, which reads as a ghost bar after a turn.
    @ViewBuilder
    private var headerInGlassContainer: some View {
        if #available(iOS 26.0, *) {
            GlassEffectContainer(spacing: BrowserChrome.barGap) {
                header
            }
        } else {
            header
        }
    }

    @ViewBuilder
    private var bottomBarInGlassContainer: some View {
        if #available(iOS 26.0, *) {
            GlassEffectContainer(spacing: BrowserChrome.barGap) {
                bottomBar
            }
        } else {
            bottomBar
        }
    }

    private var bottomBar: some View {        HStack(spacing: BrowserSpacing.compact) {
            Button {
                goPrevious()
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "chevron.left")
                    Text("上一章")
                }
                .font(.system(size: 13, weight: .medium))
                .frame(maxWidth: .infinity, minHeight: 36)
                .contentShape(Rectangle())
            }
            .disabled(!(chapter?.hasPrevious ?? false) || isLoading)

            Text("\(Int((progress * 100).rounded()))%")
                .font(.caption2)
                .foregroundStyle(palette.secondaryText)
                .monospacedDigit()
                .lineLimit(1)

            Button {
                goNext()
            } label: {
                HStack(spacing: 4) {
                    Text("下一章")
                    Image(systemName: "chevron.right")
                }
                .font(.system(size: 13, weight: .medium))
                .frame(maxWidth: .infinity, minHeight: 36)
                .contentShape(Rectangle())
            }
            .disabled(!(chapter?.hasNext ?? false) || isLoading)
        }
        .foregroundStyle(palette.primaryText)
        .buttonStyle(ChromeButtonStyle())
        .padding(.horizontal, 10)
        .frame(height: 44)
        .browserFloatingChrome(
            radius: BrowserRadius.card,
            material: .regularMaterial,
            tintStrength: 0.45,
            elevation: .card
        )
        .padding(.horizontal, BrowserChrome.sideInset)
        .padding(.bottom, 2)
    }

    // MARK: - Loading

    private func prepare() async {
        if let stored = env.settings.preferences.readerFontSize, stored >= 12, stored <= 40 {
            fontSize = stored
        }
        if let raw = env.settings.preferences.readerAppearance,
           let stored = NovelReadingAppearance(rawValue: raw) {
            appearance = stored
        }

        guard chapter == nil else {
            progress = currentBook.progress
            saveNow()
            return
        }

        if let cached = env.novels.cachedChapter(book: currentBook) {
            chapter = cached
            progress = currentBook.progress
            saveNow()
            return
        }

        await load(
            url: currentBook.currentChapterUrl,
            index: currentBook.chapterIndex,
            restoring: currentBook.progress
        )
    }

    private func load(url: String, index: Int, restoring: Double = 0) async {
        guard !isLoading, !url.isEmpty else { return }

        if let cached = env.novels.chapter(bookId: currentBook.id, url: url) {
            chapter = cached
            progress = restoring
            currentBook.currentChapterUrl = cached.url
            currentBook.currentChapterTitle = cached.title
            currentBook.chapterIndex = cached.index
            saveNow()
            return
        }

        isLoading = true
        statusMessage = nil
        let extraction = await loader.load(urlString: url)
        isLoading = false

        guard let extraction else {
            statusMessage = "网络或页面结构让这一章无法载入。"
            return
        }

        let stored = env.novels.store(extraction, bookId: currentBook.id, index: max(index, 0))
            ?? NovelChapter(
                bookId: currentBook.id,
                index: max(index, 0),
                url: extraction.chapterUrl,
                title: extraction.chapterTitle,
                contentHtml: extraction.contentHtml,
                previousUrl: extraction.previousUrl,
                nextUrl: extraction.nextUrl
            )

        progress = 0
        chapter = stored
        currentBook.currentChapterUrl = stored.url
        currentBook.currentChapterTitle = stored.title
        currentBook.chapterIndex = stored.index
        saveNow()
    }

    // MARK: - Navigation

    private func goNext() {
        guard let chapter, chapter.hasNext, !isLoading else { return }
        saveNow()
        Task { @MainActor in
            await load(url: chapter.nextUrl, index: chapter.index + 1)
        }
    }

    private func goPrevious() {
        guard let chapter, chapter.hasPrevious, !isLoading else { return }
        saveNow()
        Task { @MainActor in
            await load(url: chapter.previousUrl, index: max(0, chapter.index - 1))
        }
    }

    private func close() {
        saveNow()
        onClose()
    }

    private func openCurrentInBrowser() {
        let urlString = chapter?.url ?? currentBook.currentChapterUrl
        guard let url = URL(string: urlString) else { return }
        saveNow()
        onOpenInBrowser(url)
    }

    // MARK: - Position

    private func handleProgress(_ value: Double) {
        progress = min(max(value, 0), 1)
        let now = Date()
        guard now.timeIntervalSince(lastSavedAt) > 2 else { return }
        lastSavedAt = now
        env.novels.updateProgress(bookId: currentBook.id, progress: progress)
    }

    private func saveNow() {
        guard let chapter else { return }
        env.novels.markPosition(bookId: currentBook.id, chapter: chapter, progress: progress)
        currentBook.progress = progress
        currentBook.currentChapterUrl = chapter.url
        currentBook.currentChapterTitle = chapter.title
        currentBook.chapterIndex = chapter.index
    }

    private func setFontSize(_ size: Double) {
        fontSize = size
        env.settings.update { $0.readerFontSize = size }
    }

    private func sizeLabel(_ size: Double) -> String {
        switch size {
        case ..<17.5: return "小"
        case ..<20.5: return "中"
        case ..<23.5: return "大"
        default: return "特大"
        }
    }

    // MARK: - HTML

    private var resolvedScheme: ColorScheme {
        appearance.colorScheme ?? colorScheme
    }

    /// The chapter with a reading stylesheet around it.
    ///
    /// The paper is a translucent card rather than the system background: the
    /// reader floats over the app's field, and the text sits on enough of a
    /// surface to stay legible without turning the page into a white rectangle
    /// again. A serif face is deliberate — long-form Chinese reads better in
    /// one, and the reader's own type is the only hint that this is not the
    /// site.
    private func styledHtml(for chapter: NovelChapter) -> String {
        let dark = resolvedScheme == .dark
        let text = dark ? "#e9e9ee" : "#1b1b1f"
        let secondary = dark ? "#a3a3ad" : "#5c5c64"
        let rule = dark ? "rgba(255,255,255,0.14)" : "rgba(0,0,0,0.10)"
        let paper = dark ? "rgba(12,14,20,0.62)" : "rgba(255,255,255,0.64)"
        let accent = dark ? "#87a9ff" : "#2f63d8"
        let scheme = dark ? "dark" : "light"

        return """
        <!doctype html>
        <html>
        <head>
          <meta charset="utf-8">
          <meta name="viewport" content="width=device-width, initial-scale=1, viewport-fit=cover">
          <meta name="color-scheme" content="\(scheme)">
          <style>
            html, body { background: transparent; }
            body {
              margin: 8px 12px 18px 12px;
              padding: 22px 22px 56px 22px;
              border-radius: 24px;
              background: \(paper);
              box-shadow: 0 18px 60px rgba(0, 0, 0, \(dark ? "0.35" : "0.10"));
              -webkit-backdrop-filter: blur(18px);
              font-family: "Songti SC", "Source Han Serif SC", "Noto Serif CJK SC", Georgia, serif;
              font-size: \(Int(fontSize))px;
              line-height: 1.95;
              color: \(text);
              -webkit-text-size-adjust: 100%;
              word-wrap: break-word;
            }
            h1, h2, h3, h4 {
              line-height: 1.45;
              margin: 1.4em 0 0.6em 0;
              font-weight: 600;
            }
            h1 { font-size: 1.35em; margin-top: 0.2em; }
            h2 { font-size: 1.18em; }
            p { margin: 0 0 1.05em 0; }
            a { color: \(accent); text-decoration: none; }
            img, video, figure {
              max-width: 100%;
              height: auto;
              display: block;
              margin: 1.2em auto;
              border-radius: 10px;
            }
            blockquote {
              margin: 1.2em 0;
              padding: 0.35em 0.9em;
              border-left: 3px solid \(rule);
              color: \(secondary);
            }
            pre, code {
              font-family: ui-monospace, "SF Mono", Menlo, monospace;
              font-size: 0.88em;
              background: \(rule);
              border-radius: 6px;
            }
            pre { padding: 0.8em; overflow-x: auto; }
            code { padding: 0.12em 0.32em; }
            pre code { padding: 0; background: none; }
            hr { border: none; border-top: 1px solid \(rule); margin: 2em 0; }
            ::selection { background: \(accent); color: white; }
          </style>
        </head>
        <body>
        \(chapter.contentHtml)
        </body>
        </html>
        """
    }
}

// MARK: - Appearance

/// The reading appearance for novels. Same three-way shape as the app's own
/// setting, for the same reason: "follow the system" is a mode, not a synonym
/// for light.
private enum NovelReadingAppearance: String, CaseIterable, Identifiable {
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

    var colorScheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .light: return .light
        case .dark: return .dark
        }
    }
}

// MARK: - The chapter view

/// Renders one chapter and reports the reading position.
private struct NovelChapterWebView: UIViewRepresentable {
    var html: String
    var initialProgress: Double
    var onProgress: (Double) -> Void

    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()

        let controller = WKUserContentController()
        controller.add(
            WeakScriptMessageHandler(target: context.coordinator),
            name: Self.scrollHandler
        )
        controller.addUserScript(
            WKUserScript(
                source: Self.scrollReporter,
                injectionTime: .atDocumentEnd,
                forMainFrameOnly: true
            )
        )
        configuration.userContentController = controller

        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        webView.isOpaque = false
        webView.backgroundColor = .clear
        webView.scrollView.backgroundColor = .clear
        webView.scrollView.contentInsetAdjustmentBehavior = .never
        webView.allowsBackForwardNavigationGestures = false

        context.coordinator.webView = webView
        context.coordinator.initialProgress = initialProgress
        context.coordinator.loadedHtml = html
        webView.loadHTMLString(html, baseURL: nil)
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        context.coordinator.initialProgress = initialProgress
        guard context.coordinator.loadedHtml != html else { return }
        context.coordinator.loadedHtml = html
        context.coordinator.restoredProgress = false
        webView.loadHTMLString(html, baseURL: nil)
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(onProgress: onProgress)
    }

    static let scrollHandler = "velaNovelScroll"

    /// Reports the fraction read. A frame is requested once per scroll burst so
    /// a fast fling does not post a message per event.
    static let scrollReporter = """
    (function () {
      function post() {
        try {
          var root = document.documentElement;
          var max = Math.max((root.scrollHeight || 0) - (root.clientHeight || 0), 1);
          var y = window.scrollY || root.scrollTop || 0;
          var fraction = Math.min(1, Math.max(0, y / max));
          if (window.webkit && window.webkit.messageHandlers &&
              window.webkit.messageHandlers.\(scrollHandler)) {
            window.webkit.messageHandlers.\(scrollHandler).postMessage(fraction);
          }
        } catch (error) {}
      }

      var scheduled = false;
      window.addEventListener('scroll', function () {
        if (scheduled) { return; }
        scheduled = true;
        window.requestAnimationFrame(function () {
          scheduled = false;
          post();
        });
      }, { passive: true });

      window.addEventListener('load', function () { setTimeout(post, 300); });
      setTimeout(post, 500);
    })();
    """

    final class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
        let onProgress: (Double) -> Void
        weak var webView: WKWebView?
        var loadedHtml: String?
        var initialProgress: Double = 0
        var restoredProgress = false

        init(onProgress: @escaping (Double) -> Void) {
            self.onProgress = onProgress
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            guard !restoredProgress else { return }
            restoredProgress = true
            let fraction = min(max(initialProgress, 0), 1)
            guard fraction > 0.001 else { return }
            let script = """
            (function () {
              var root = document.documentElement;
              var max = Math.max((root.scrollHeight || 0) - (root.clientHeight || 0), 1);
              window.scrollTo(0, max * \(fraction));
            })();
            """
            webView.evaluateJavaScript(script, completionHandler: nil)
        }

        /// A link in the extracted copy leaves the reader rather than
        /// navigating it: the chapter's next/previous controls are the way to
        /// move, and a tap on a site link would otherwise replace the chapter
        /// with a page that has no reader around it.
        func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationAction: WKNavigationAction,
            decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
        ) {
            if navigationAction.request.url == nil {
                decisionHandler(.allow)
                return
            }
            if let url = navigationAction.request.url, url.scheme == "about" {
                decisionHandler(.allow)
                return
            }
            decisionHandler(.cancel)
        }

        func userContentController(
            _ userContentController: WKUserContentController,
            didReceive message: WKScriptMessage
        ) {
            guard message.name == NovelChapterWebView.scrollHandler else { return }
            if let number = message.body as? NSNumber {
                onProgress(number.doubleValue)
            }
        }
    }
}

/// Breaks the retain cycle WebKit's user-content controller creates: it holds
/// its message handlers strongly, and the handler here is the coordinator that
/// owns the web view.
private final class WeakScriptMessageHandler: NSObject, WKScriptMessageHandler {
    weak var target: WKScriptMessageHandler?

    init(target: WKScriptMessageHandler) {
        self.target = target
    }

    func userContentController(
        _ userContentController: WKUserContentController,
        didReceive message: WKScriptMessage
    ) {
        target?.userContentController(userContentController, didReceive: message)
    }
}
