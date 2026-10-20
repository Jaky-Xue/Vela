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
    /// The exact scroll fraction, kept out of view state.
    ///
    /// A scroll message arrives every frame. Storing the fraction in `@State`
    /// would rebuild the reader — including its whole chapter HTML — on each
    /// one, so the box holds the number and only the rounded percentage below
    /// is published.
    @State private var progressBox: NovelProgressBox
    @State private var lastSavedAt = Date.distantPast
    @State private var fontSize: Double = 19
    @State private var appearance: NovelReadingAppearance = .system
    @State private var pageMode: NovelPageMode = .scroll
    @State private var loader = NovelChapterLoader()
    @State private var tocLoader = NovelTOCLoader()
    @State private var tocEntries: [NovelTOCEntry] = []
    @State private var isLoadingTOC = false
    @State private var showTOC = false
    /// Whether the header and chapter controls are on screen. They retreat
    /// after the reader settles so the chapter is the only thing visible; a
    /// tap in the middle of the page brings them back.
    @State private var chromeVisible = true

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
        _progressBox = State(initialValue: NovelProgressBox(book.progress))
    }

    var body: some View {
        ZStack {
            AmbientSurfaceFill(opacity: 0.88)
                .ignoresSafeArea()

            VStack(spacing: 0) {
                if chromeVisible {
                    headerInGlassContainer
                        .transition(.move(edge: .top).combined(with: .opacity))
                }

                Group {
                    if let chapter {
                        NovelChapterWebView(
                            html: styledHtml(for: chapter),
                            initialProgress: progressBox.value,
                            isPaged: pageMode == .paged,
                            onProgress: handleProgress,
                            onCenterTap: toggleChrome
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
        .safeAreaInset(edge: .bottom) {
            if chromeVisible {
                bottomBarInGlassContainer
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.easeInOut(duration: 0.22), value: chromeVisible)
        .task {
            await prepare()
            // The controls introduce the reader, then get out of the reading
            // surface's way. A tap in the middle brings them back.
            try? await Task.sleep(nanoseconds: 2_600_000_000)
            guard !Task.isCancelled else { return }
            if chromeVisible {
                withAnimation(.easeInOut(duration: 0.24)) { chromeVisible = false }
            }
        }
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
        .onChange(of: showTOC) { _, shown in
            if shown {
                Task { await loadTOCIfNeeded(force: true) }
            }
        }
        .sheet(isPresented: $showTOC) {
            NovelTOCSheet(
                entries: $tocEntries,
                currentUrl: chapter?.url ?? "",
                isLoading: $isLoadingTOC,
                onSelect: { entry in
                    showTOC = false
                    let index = tocEntries.firstIndex(where: { $0.url == entry.url }) ?? 0
                    Task { @MainActor in
                        await load(url: entry.url, index: index)
                    }
                },
                onClose: { showTOC = false }
            )
            .environment(env)
            .browserAmbientSheet()
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

            Text(progressLabel)
                .font(.system(size: 10, weight: .medium))
                .monospacedDigit()
                .foregroundStyle(palette.secondaryText)
                .accessibilityHidden(true)

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
                Section("翻页") {
                    ForEach(NovelPageMode.allCases) { option in
                        Button {
                            pageMode = option
                            env.settings.update { $0.novelPageMode = option.rawValue }
                        } label: {
                            if pageMode == option {
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

    private var bottomBar: some View {
        VStack(spacing: 0) {
            NovelReadingProgressBar(progress: progress)
                .padding(.horizontal, 12)
                .padding(.top, 6)

            HStack(spacing: BrowserSpacing.compact) {
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
            .disabled(resolvedPreviousUrl.isEmpty || isLoading)

            Button {
                showTOC = true
            } label: {
                Text("目录")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(palette.primaryText)
                    .frame(minWidth: 52, minHeight: 36)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("目录")

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
            .disabled(resolvedNextUrl.isEmpty || isLoading)
            }
            .foregroundStyle(palette.primaryText)
            .buttonStyle(ChromeButtonStyle())
            .padding(.horizontal, 10)
            .frame(height: 44)
        }
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
        pageMode = NovelPageMode.resolve(env.settings.preferences.novelPageMode)
        tocEntries = env.novels.tocEntries(bookId: currentBook.id)

        if chapter != nil {
            progress = currentBook.progress
            progressBox.value = currentBook.progress
            saveNow()
        } else if let cached = env.novels.cachedChapter(book: currentBook) {
            chapter = cached
            progress = currentBook.progress
            progressBox.value = currentBook.progress
            saveNow()
        } else {
            await load(
                url: currentBook.currentChapterUrl,
                index: currentBook.chapterIndex,
                restoring: currentBook.progress
            )
        }

        await loadTOCIfNeeded()
    }

    /// Loads the cached TOC, or fetches it from the book's TOC page once.
    private func loadTOCIfNeeded(force: Bool = false) async {
        if force {
            tocEntries = env.novels.tocEntries(bookId: currentBook.id)
        }
        guard tocEntries.isEmpty, !isLoadingTOC else { return }

        // A catalog link is not always on the chapter page: on script-driven
        // sites it is a `javascript:` call with no URL to read. The chapter
        // route still points at the book's directory, so derive it and keep
        // it — the next visit does not have to guess again.
        let chapterURL = chapter?.url ?? currentBook.currentChapterUrl
        var source = env.novels.tocSource(bookId: currentBook.id) ?? ""
        if source.isEmpty, let derived = NovelURLRoute.catalogURL(for: chapterURL) {
            source = derived
            env.novels.saveTOCSource(bookId: currentBook.id, url: derived)
        }
        guard !source.isEmpty else { return }

        isLoadingTOC = true
        var result = await tocLoader.load(urlString: source)
        if result == nil || result?.isEmpty == true,
           let derived = NovelURLRoute.catalogURL(for: chapterURL),
           derived != source {
            result = await tocLoader.load(urlString: derived)
            if let entries = result, !entries.isEmpty {
                env.novels.saveTOCSource(bookId: currentBook.id, url: derived)
            }
        }
        isLoadingTOC = false

        if let entries = result, !entries.isEmpty {
            tocEntries = entries
            env.novels.saveTOC(bookId: currentBook.id, entries: entries)
        }
    }

    private func load(url: String, index: Int, restoring: Double = 0) async {
        guard !isLoading, !url.isEmpty else { return }

        if let cached = env.novels.chapter(bookId: currentBook.id, url: url) {
            chapter = cached
            progress = restoring
            progressBox.value = restoring
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
        progressBox.value = 0
        chapter = stored
        currentBook.currentChapterUrl = stored.url
        currentBook.currentChapterTitle = stored.title
        currentBook.chapterIndex = stored.index
        saveNow()
    }

    // MARK: - Navigation

    /// The chapter a step in either direction opens.
    ///
    /// Three sources, in order of trust: the page's own link, the catalog's
    /// neighbour, and the route itself. The last one is what keeps the
    /// buttons alive on single-page sites whose navigation is a
    /// `javascript:` call — there is no URL on the page, but the route is
    /// numbered, and `NovelURLRoute` can take the step.
    private func neighborTarget(offset: Int) -> (url: String, index: Int)? {
        guard let chapter else { return nil }
        if offset > 0, !chapter.nextUrl.isEmpty {
            return (chapter.nextUrl, chapter.index + 1)
        }
        if offset < 0, !chapter.previousUrl.isEmpty {
            return (chapter.previousUrl, max(0, chapter.index - 1))
        }
        if let neighbor = env.novels.tocNeighbor(
            bookId: currentBook.id,
            url: chapter.url,
            offset: offset
        ) {
            return (neighbor.entry.url, neighbor.index)
        }
        guard let derived = NovelURLRoute.shifted(chapter.url, by: offset) else { return nil }
        return (derived, max(0, chapter.index + offset))
    }

    private var resolvedNextUrl: String {
        neighborTarget(offset: 1)?.url ?? ""
    }

    private var resolvedPreviousUrl: String {
        neighborTarget(offset: -1)?.url ?? ""
    }

    private func goNext() {
        guard !isLoading, let target = neighborTarget(offset: 1) else { return }
        saveNow()
        Task { @MainActor in
            await load(url: target.url, index: target.index)
        }
    }

    private func goPrevious() {
        guard !isLoading, let target = neighborTarget(offset: -1) else { return }
        saveNow()
        Task { @MainActor in
            await load(url: target.url, index: target.index)
        }
    }

    private func close() {
        saveNow()
        onClose()
    }

    /// Shows or yields the header and chapter controls. The target is the
    /// middle of the chapter, so taps meant for text selection elsewhere do
    /// not move the chrome.
    private func toggleChrome() {
        withAnimation(.easeInOut(duration: 0.22)) {
            chromeVisible.toggle()
        }
    }

    private var progressLabel: String {
        "\(Int((progress * 100).rounded()))%"
    }

    private func openCurrentInBrowser() {
        let urlString = chapter?.url ?? currentBook.currentChapterUrl
        guard let url = URL(string: urlString) else { return }
        saveNow()
        onOpenInBrowser(url)
    }

    // MARK: - Position

    private func handleProgress(_ value: Double) {
        let fraction = min(max(value, 0), 1)
        progressBox.value = fraction

        // Publish only the rounded percentage the bottom bar draws; the exact
        // fraction stays in the box so a scroll message does not rebuild the
        // chapter HTML on every frame.
        if Int((fraction * 100).rounded()) != Int((progress * 100).rounded()) {
            progress = fraction
        }

        let now = Date()
        guard now.timeIntervalSince(lastSavedAt) > 2 else { return }
        lastSavedAt = now
        env.novels.updateProgress(bookId: currentBook.id, progress: fraction)
    }

    private func saveNow() {
        guard let chapter else { return }
        let fraction = progressBox.value
        env.novels.markPosition(bookId: currentBook.id, chapter: chapter, progress: fraction)
        currentBook.progress = fraction
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
              max-width: 680px;
              width: calc(100% - 24px);
              box-sizing: border-box;
              margin: 8px auto 18px auto;
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

// MARK: - Progress bar

/// The chapter's read fraction, drawn along the top of the chapter controls.
/// It used to be a percentage tucked under the catalog button, which read as
/// part of that button; the bar states the same thing in its natural place.
private struct NovelReadingProgressBar: View {
    @Environment(\.browserPalette) private var palette
    var progress: Double

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(palette.primaryText.opacity(0.10))
                Capsule()
                    .fill(palette.accent)
                    .frame(width: CGFloat(max(0, min(1, progress))) * geo.size.width)
            }
        }
        .frame(height: 2)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

// MARK: - Progress box

/// Holds the exact reading fraction without making it view state.
///
/// A reference box rather than a `@State` Double: the scroll reporter posts on
/// every frame, and republishing the fraction would rebuild the whole reader —
/// chapter HTML included — at that rate.
private final class NovelProgressBox {
    var value: Double

    init(_ value: Double = 0) {
        self.value = value
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
    var isPaged: Bool
    var onProgress: (Double) -> Void
    var onCenterTap: () -> Void

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
        webView.scrollView.isPagingEnabled = isPaged
        webView.allowsBackForwardNavigationGestures = false

        // One tap recognizer for the reading surface. It does not cancel
        // touches, so selecting text or following the copy's own links still
        // works; the coordinate check in the handler keeps taps near the
        // edges from moving the chrome.
        let centerTap = UITapGestureRecognizer(
            target: context.coordinator,
            action: #selector(Coordinator.handleCenterTap(_:))
        )
        centerTap.cancelsTouchesInView = false
        webView.addGestureRecognizer(centerTap)

        context.coordinator.webView = webView
        context.coordinator.initialProgress = initialProgress
        context.coordinator.loadedHtml = html
        context.coordinator.onCenterTap = onCenterTap
        webView.loadHTMLString(html, baseURL: nil)
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        context.coordinator.initialProgress = initialProgress
        context.coordinator.onCenterTap = onCenterTap
        webView.scrollView.isPagingEnabled = isPaged
        guard context.coordinator.loadedHtml != html else { return }
        context.coordinator.loadedHtml = html
        context.coordinator.restoredProgress = false
        webView.loadHTMLString(html, baseURL: nil)
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(onProgress: onProgress, onCenterTap: onCenterTap)
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
        var onCenterTap: () -> Void
        weak var webView: WKWebView?
        var loadedHtml: String?
        var initialProgress: Double = 0
        var restoredProgress = false

        init(onProgress: @escaping (Double) -> Void, onCenterTap: @escaping () -> Void) {
            self.onProgress = onProgress
            self.onCenterTap = onCenterTap
        }

        /// Toggles the chrome only for taps in the middle of the page: the
        /// edges are where links and selection handles live.
        @objc func handleCenterTap(_ recognizer: UITapGestureRecognizer) {
            guard recognizer.state == .ended, let view = recognizer.view else { return }
            let point = recognizer.location(in: view)
            let bounds = view.bounds
            guard bounds.width > 0, bounds.height > 0 else { return }
            let inMiddleHorizontally = point.x >= bounds.width * 0.25
                && point.x <= bounds.width * 0.75
            let inMiddleVertically = point.y >= bounds.height * 0.2
                && point.y <= bounds.height * 0.8
            guard inMiddleHorizontally && inMiddleVertically else { return }
            onCenterTap()
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
