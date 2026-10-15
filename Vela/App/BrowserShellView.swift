//
//  BrowserShellView.swift
//  Vela
//
//  The browser screen: the web surface, the address bar, the bottom toolbar
//  and every overlay the shell can present.
//
//  One view holds all of it because SwiftUI can express it that way. What the
//  shell owns is *which surface is visible*; the toolbar, the address bar and
//  the overlays are pure functions of that, so a layering of intermediate
//  objects would have nothing to arbitrate.
//
//  The omnibox session — the debounced suggestion list, the highlighted row,
//  the disclosure state — lives in `OmniboxViewModel` rather than here, which
//  is what keeps the suggestion list, the field text and the editing flag from
//  being three pieces of state that have to be kept in step by hand. Two
//  presentation choices follow from the platform: the toolbar is removed
//  outright while the omnibox is open rather than being covered by it, and the
//  chrome collapses under a spring so the toolbar's return reads as one
//  movement instead of two.
//

import SwiftUI
import UIKit
import WebKit

struct BrowserShellView: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.browserPalette) private var palette

    /// The omnibox session. Created here rather than inside the view body
    /// because it is long-lived: it survives every tab switch, and rebuilding it
    /// would throw away the user's collapsed-section choices on each one.
    @State private var omnibox: OmniboxViewModel

    @State private var showTabsOverview = false
    @State private var showBookmarks = false
    @State private var showHistory = false
    @State private var showDownloads = false
    @State private var showSettings = false
    @State private var showMenu = false
    @State private var showShareSheet = false
    @State private var showFindBar = false
    @State private var findQuery = ""

    @State private var isReaderActive = false
    @State private var readerArticle: ReaderArticle?

    /// How far the toolbar has slid out of the way. Positive means hidden.
    @State private var toolbarOffset: CGFloat = 0
    /// The previous scroll offset, used to derive a direction.
    ///
    /// Kept here rather than read off the tab: the coordinator writes the tab's
    /// offset on every scroll message, so comparing against it would always
    /// compare the new value with itself and the toolbar would never collapse.
    @State private var lastScrollOffset: Double = 0

    /// The one animation the chrome uses.
    ///
    /// A spring rather than an ease: the toolbar leaves and returns along a path
    /// the user's own scroll is also moving, and an ease-out over a fixed
    /// duration reads as a separate, laggier movement next to the page.
    private static let chromeAnimation = Animation.spring(response: 0.32, dampingFraction: 0.86)

    @MainActor
    init(environment: AppEnvironment) {
        _omnibox = State(initialValue: OmniboxViewModel(
            settings: environment.settings,
            history: environment.history,
            bookmarks: environment.bookmarks,
            searchHistory: environment.searchHistory,
            tabManager: environment.tabManager
        ))
    }

    private var tabManager: TabManager { env.tabManager }

    private var activeTab: BrowserTabState? { tabManager.activeTab }

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                palette.surface.ignoresSafeArea()

                // The page sits *between* the bars rather than under them. The
                // overlay arrangement this replaced let the chrome cover the
                // last of every document — and covered fixed-position page
                // headers outright once the address bar moved to the top.
                VStack(spacing: 0) {
                    topBar
                    contentSurface(availableHeight: proxy.size.height)
                    bottomBar
                }
            }
            .environment(\.browserPalette, activePalette)
        }
        .animation(Self.chromeAnimation, value: omnibox.isEditing)
        .onAppear {
            wireOmnibox()
            syncAddressText()
        }
        .onChange(of: tabManager.activeTabId) { _, _ in
            isReaderActive = false
            readerArticle = nil
            showFindBar = false
            findQuery = ""
            toolbarOffset = 0
            lastScrollOffset = 0
            env.webCoordinator.clearFindInPage()
            omnibox.endEditing()
            syncAddressText()
        }
        .onChange(of: activeTab?.url) { _, _ in syncAddressText() }
        .sheet(isPresented: $showTabsOverview) {
            TabsOverviewView()
                .environment(env)
        }
        .sheet(isPresented: $showBookmarks) {
            NavigationStack { BookmarksView() }
                .environment(env)
        }
        .sheet(isPresented: $showHistory) {
            NavigationStack { HistoryView() }
                .environment(env)
        }
        .sheet(isPresented: $showDownloads) {
            NavigationStack { DownloadsView() }
                .environment(env)
        }
        .sheet(isPresented: $showSettings) {
            NavigationStack { SettingsView() }
                .environment(env)
        }
        .sheet(isPresented: $showShareSheet) {
            if let tab = activeTab, let url = URL(string: tab.url) {
                ShareSheet(items: [url])
            }
        }
        .confirmationDialog("菜单", isPresented: $showMenu, titleVisibility: .hidden) {
            menuContent
        }
        .alert(
            env.overlays.javascriptDialog?.message ?? "",
            isPresented: Binding(
                get: { env.overlays.javascriptDialog != nil },
                set: { if !$0 { env.webCoordinator.resolveJavaScriptDialog(confirmed: false, text: nil) } }
            ),
            presenting: env.overlays.javascriptDialog
        ) { dialog in
            switch dialog.kind {
            case .alert:
                Button("好") { env.webCoordinator.resolveJavaScriptDialog(confirmed: true, text: nil) }
            case .confirm:
                Button("取消", role: .cancel) {
                    env.webCoordinator.resolveJavaScriptDialog(confirmed: false, text: nil)
                }
                Button("确定") { env.webCoordinator.resolveJavaScriptDialog(confirmed: true, text: nil) }
            case .prompt:
                // A prompt needs a text field, which an alert cannot host on
                // iOS; the shell routes it to the sheet below instead.
                Button("关闭") { env.webCoordinator.resolveJavaScriptDialog(confirmed: false, text: nil) }
            }
        } message: { dialog in
            if dialog.fromUserScript {
                Text("来自用户脚本")
            }
        }
        .alert(
            "要用其他应用打开吗？",
            isPresented: Binding(
                get: { env.overlays.externalNavigation != nil },
                set: { if !$0 { env.webCoordinator.dismissExternalNavigation() } }
            ),
            presenting: env.overlays.externalNavigation
        ) { request in
            Button("打开") { env.webCoordinator.confirmExternalNavigation(allow: true, remember: false) }
            Button("总是允许此网站") {
                env.webCoordinator.confirmExternalNavigation(allow: true, remember: true)
            }
            Button("取消", role: .cancel) { env.webCoordinator.dismissExternalNavigation() }
        } message: { request in
            Text(request.url.absoluteString)
        }
        .sheet(
            isPresented: Binding(
                get: { env.overlays.permissionRequest != nil },
                set: { _ in }
            )
        ) {
            if let request = env.overlays.permissionRequest {
                PermissionPromptView(request: request) { allow, remember in
                    env.webCoordinator.resolvePermissionRequest(allow: allow, remember: remember)
                }
            }
        }
    }

    // MARK: - Web surface

    @ViewBuilder
    private var webSurface: some View {
        if let tab = activeTab {
            // A stable identity per tab keeps SwiftUI from rebuilding the
            // representable when the tab strip changes.
            Group {
                if tab.isHome {
                    NewTabHomeView(
                        onNavigate: { url in navigate(to: url, in: tab) },
                        onOpenBookmarks: { showBookmarks = true }
                    )
                    .id("home-\(tab.id)")
                } else if let webView = tabManager.webView(for: tab.id) {
                    WebViewHost(
                        webView: webView,
                        initialUrl: tab.url,
                        isHome: false,
                        onScroll: { offset in
                            handleScroll(offset: offset)
                        }
                    )
                    .id("web-\(tab.id)")
                } else {
                    // A cold tab whose web view was discarded under memory
                    // pressure. Materialising happens in `onAppear` rather than
                    // here: creating a web view during view evaluation would
                    // mutate published state mid-update.
                    Color.clear
                        .onAppear {
                            tabManager.activateTab(id: tab.id)
                        }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            EmptyState(
                systemImage: "square.on.square",
                title: "没有标签页",
                message: "新建一个标签页就可以开始浏览了。",
                actionTitle: "新建标签页",
                action: { tabManager.createTab(openSource: .user) }
            )
        }
    }

    // MARK: - Palette

    private var activePalette: BrowserPalette {
        BrowserPalette.all.first { $0.id == env.settings.preferences.themePaletteId }
            ?? BrowserPalette.default
    }

    // MARK: - Chrome

    /// The address bar, pinned to the top.
    ///
    /// The material is painted behind the bar rather than by it, so it reaches
    /// up under the status bar without the controls themselves moving.
    private var topBar: some View {
        OmniboxView(
            viewModel: omnibox,
            isLoading: activeTab?.isLoading ?? false,
            progress: activeTab?.estimatedProgress ?? 0,
            placeholder: omniboxPlaceholder,
            onReload: reloadActiveTab,
            onStop: { tabManager.webView(for: tabManager.activeTabId)?.stopLoading() }
        )
        .padding(.horizontal, BrowserSpacing.compact)
        .padding(.vertical, BrowserSpacing.tight)
        .background {
            Rectangle()
                .fill(.bar)
                .ignoresSafeArea(edges: .top)
        }
    }

    /// The page, and whatever floats over it.
    ///
    /// The suggestion card drops out of the address bar instead of rising from
    /// the bottom of the screen, which is where a card anchored to a top bar
    /// belongs. It dims the page and nothing else — the bar being typed into has
    /// to stay legible, and the toolbar is gone while the card is up.
    private func contentSurface(availableHeight: CGFloat) -> some View {
        ZStack(alignment: .top) {
            if isReaderActive, let article = readerArticle {
                ReaderView(
                    article: article,
                    onClose: {
                        isReaderActive = false
                        readerArticle = nil
                    }
                )
                .transition(.move(edge: .bottom))
            } else {
                webSurface
            }

            if omnibox.isEditing {
                Color.black.opacity(0.18)
                    .transition(.opacity)
                    .onTapGesture { omnibox.cancel() }

                OmniboxSuggestionListView(
                    viewModel: omnibox,
                    maxHeight: omniboxCardHeight(for: availableHeight)
                )
                .padding(.horizontal, BrowserSpacing.compact)
                .padding(.top, BrowserSpacing.hairline)
                .transition(
                    .asymmetric(
                        insertion: .opacity.combined(with: .scale(scale: 0.96, anchor: .top)),
                        removal: .opacity
                    )
                )
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// The find bar and the toolbar, pinned to the bottom.
    private var bottomBar: some View {
        VStack(spacing: 0) {
            if showFindBar {
                FindBar(
                    query: $findQuery,
                    result: env.overlays.findResult,
                    onNext: { env.webCoordinator.findInPage(findQuery, forward: true) },
                    onPrevious: { env.webCoordinator.findInPage(findQuery, forward: false) },
                    onClose: {
                        showFindBar = false
                        findQuery = ""
                        env.webCoordinator.clearFindInPage()
                    }
                )
                .transition(.move(edge: .bottom))
            }

            // The toolbar is removed rather than covered while the omnibox is
            // open: a bar underneath a card is a row of controls the user can
            // still hit by accident.
            if !omnibox.isEditing {
                BottomToolbarView(
                    actions: BrowserToolbarAction.defaultOrder,
                    tabCount: tabManager.tabs.count,
                    canGoBack: activeTab?.canGoBack ?? false,
                    canGoForward: activeTab?.canGoForward ?? false,
                    adBlockActive: env.settings.adBlockSettings.preferences.enabled,
                    readerAvailable: env.settings.preferences.readerModeAvailable && !(activeTab?.isHome ?? true),
                    onAction: handleToolbarAction
                )
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .padding(.horizontal, BrowserSpacing.compact)
        .padding(.top, BrowserSpacing.hairline)
        .padding(.bottom, BrowserSpacing.hairline)
        .background {
            Rectangle()
                .fill(.bar)
                .ignoresSafeArea(edges: .bottom)
        }
        .offset(y: toolbarOffset)
    }

    /// The tallest the suggestion card may grow.
    ///
    /// Two ceilings, because either one alone is wrong somewhere: a fraction of
    /// the screen keeps a short list on a tall phone from opening a card with a
    /// lake of empty material in it, and an absolute cap keeps an iPad in
    /// landscape from covering the page it is suggesting destinations in.
    private func omniboxCardHeight(for availableHeight: CGFloat) -> CGFloat {
        min(
            availableHeight * BrowserMetrics.omniboxCardHeightFraction,
            BrowserMetrics.omniboxCardMaxHeight
        )
    }

    private var omniboxPlaceholder: String {
        let engine = env.settings.preferences.searchEngine.activeEngine.name
        return "用 \(engine) 搜索或输入网址"
    }

    private var displayUrl: String {
        guard let tab = activeTab else { return "" }
        return tab.isHome ? "" : tab.url
    }

    /// Pushes the active tab's address into the omnibox.
    ///
    /// The field shows the page's URL while the omnibox is closed — which the
    /// pre-refactor bar did not, leaving the placeholder on screen instead of
    /// the address of the page being read.
    private func syncAddressText() {
        omnibox.currentPageUrl = displayUrl
        guard !omnibox.isEditing else { return }
        if omnibox.text != displayUrl {
            omnibox.text = displayUrl
        }
    }

    // MARK: - Omnibox wiring

    private func wireOmnibox() {
        omnibox.onSelectSuggestion = { suggestion in
            commitSuggestion(suggestion)
        }
        omnibox.onCommitText = { input in
            submitAddressBar(input)
        }
    }

    // MARK: - Scrolling

    /// Collapses the chrome as the page scrolls down and restores it on any
    /// upward movement.
    ///
    /// The restore is unconditional on direction rather than proportional to
    /// distance: a user who scrolls up even slightly is looking for the
    /// controls, and making them scroll a threshold's worth first is the
    /// behaviour that makes a collapsing toolbar feel broken.
    private func handleScroll(offset: Double) {
        // An open omnibox pins the chrome: the user is typing into it, and
        // sliding it away mid-sentence would be hostile.
        guard !omnibox.isEditing else { return }

        let previous = lastScrollOffset
        lastScrollOffset = offset

        let target: CGFloat
        if offset <= 8 {
            target = 0
        } else if offset > previous {
            target = BrowserMetrics.toolbarHeight + BrowserSpacing.loose + 4
        } else {
            target = 0
        }
        guard target != toolbarOffset else { return }

        withAnimation(.spring(response: 0.34, dampingFraction: 0.88)) {
            toolbarOffset = target
        }
    }

    // MARK: - Actions

    private func handleToolbarAction(_ action: BrowserToolbarAction) {
        switch action {
        case .back:
            guard let tab = activeTab, let webView = tabManager.webView(for: tab.id) else { return }
            if webView.canGoBack {
                webView.goBack()
            } else if tab.isTerminalBackAvailable {
                // Backing out of the last page returns to the home surface
                // rather than doing nothing at all.
                tab.isHome = true
                tab.url = ""
                tab.title = ""
                syncAddressText()
            }

        case .forward:
            tabManager.webView(for: activeTab?.id ?? "")?.goForward()

        case .home:
            guard let tab = activeTab else { return }
            // Stop the page before leaving it: a home surface over a document
            // still fetching is a document the user has stopped looking at, and
            // its callbacks would keep arriving into hidden state.
            tabManager.webView(for: tab.id)?.stopLoading()
            isReaderActive = false
            readerArticle = nil
            tab.isHome = true
            tab.url = ""
            tab.title = ""
            syncAddressText()

        case .tabs:
            showTabsOverview = true

        case .bookmarks:
            showBookmarks = true

        case .adBlock:
            toggleAdBlock()

        case .reader:
            activateReaderMode()

        case .share:
            showShareSheet = true

        case .refresh:
            reloadActiveTab()

        case .menu:
            showMenu = true
        }
    }

    @ViewBuilder
    private var menuContent: some View {
        Button("历史记录", systemImage: "clock.arrow.circlepath") { showHistory = true }
        Button("下载", systemImage: "arrow.down.circle") { showDownloads = true }
        Button("在页面中查找", systemImage: "magnifyingglass") { showFindBar = true }
        Button("读取模式", systemImage: "doc.plaintext") { activateReaderMode() }
        Button("隐藏页面元素", systemImage: "eye.slash") {
            guard let tab = activeTab, let webView = tabManager.webView(for: tab.id) else { return }
            env.webCoordinator.armElementPicker()
            // The picker script has to be in the page, and a configuration only
            // applies to the next navigation, so the page is reloaded.
            webView.reload()
        }
        Button("设置", systemImage: "gearshape") { showSettings = true }

        if let tab = activeTab, !tab.isHome {
            Divider()
            Button("添加到书签", systemImage: "bookmark") {
                env.bookmarks.addBookmark(url: tab.url, title: tab.title, parentNodeId: nil)
            }
            Button("请求桌面网站", systemImage: "desktopcomputer") {
                toggleDesktopSite(for: tab)
            }
            Button("重新载入", systemImage: "arrow.clockwise") { reloadActiveTab() }
        }

        if tabManager.activeTab?.privacyMode == .private {
            Divider()
            Button("离开无痕模式", systemImage: "eyeglasses", role: .destructive) {
                Task { await env.endPrivateSession() }
            }
        }
    }

    private func toggleDesktopSite(for tab: BrowserTabState) {
        let next = !env.settings.preferences.desktopSiteByDefault
        // The menu item is an explicit choice between the two built-in
        // identifiers, so it clears a custom one. Leaving the custom string in
        // place would make this look like it did nothing.
        env.settings.update {
            $0.desktopSiteByDefault = next
            $0.customUserAgent = ""
        }
        tabManager.applyUserAgentToAllWebViews()
        tabManager.webView(for: tab.id)?.reload()
    }

    private func toggleAdBlock() {
        let enabled = env.settings.adBlockSettings.preferences.enabled
        env.settings.setAdBlockEnabled(!enabled)
        Task {
            await env.refreshAdBlockRules()
            // Content rules only apply to a new document, so the page is
            // reloaded to make the change visible.
            tabManager.webView(for: tabManager.activeTabId)?.reload()
        }
    }

    private func activateReaderMode() {
        guard let tab = activeTab, !tab.isHome,
              let webView = tabManager.webView(for: tab.id) else { return }
        Task {
            let article = await ReaderModeService.extract(from: webView, url: tab.url)
            if let article {
                readerArticle = article
                isReaderActive = true
            } else {
                // Extraction failed, which is the normal outcome on a non-article
                // page. Rather than a silent no-op, the shell marks the surface
                // with the failure so the user knows the button worked.
                readerArticle = ReaderArticle(
                    title: "无法提取正文",
                    byline: "",
                    contentHtml: "<p>这个页面看起来不是一篇文章，暂时无法用阅读模式打开。</p>",
                    url: tab.url
                )
                isReaderActive = true
            }
        }
    }

    private func reloadActiveTab() {
        guard let tab = activeTab else { return }
        if tab.isHome { return }
        tabManager.webView(for: tab.id)?.reload()
    }

    // MARK: - Navigation

    private func submitAddressBar(_ input: String) {
        guard let tab = activeTab else { return }
        let engine = env.settings.preferences.searchEngine.activeEngine
        guard let url = BrowserUrlResolver.resolveNavigation(input: input, searchEngine: engine) else {
            omnibox.endEditing()
            return
        }

        // A search records the query; a direct URL does not.
        if BrowserUrlResolver.isSearchQuery(input) {
            try? env.searchHistory.record(
                query: input,
                searchEngineId: engine.id,
                boundary: tab.dataBoundary
            )
        }
        omnibox.endEditing()
        navigate(to: url, in: tab)
    }

    private func navigate(to url: URL, in tab: BrowserTabState) {
        // An external scheme cannot be loaded, so it is handed to the system.
        if let scheme = url.scheme?.lowercased(),
           BrowserUrlResolver.externalSchemes.contains(scheme) {
            UIApplication.shared.open(url)
            return
        }

        tab.isHome = false
        tab.url = url.absoluteString
        let webView = tabManager.ensureWebView(for: tab)
        webView.load(URLRequest(url: url))
        // The transition is recorded by the navigation delegate, which is the
        // only place that sees the navigation type.
        syncAddressText()
    }

    private func commitSuggestion(_ suggestion: OmniboxSuggestion) {
        switch suggestion.kind {
        case .openTab(let tabId):
            omnibox.endEditing()
            tabManager.activateTab(id: tabId)

        case let .search(engineId):
            var engine = env.settings.preferences.searchEngine.activeEngine
            if engine.id != engineId {
                env.settings.setDefaultSearchEngine(id: engineId)
                engine = env.settings.preferences.searchEngine.activeEngine
            }
            guard let url = engine.searchUrl(for: suggestion.title) else {
                omnibox.endEditing()
                return
            }
            try? env.searchHistory.record(
                query: suggestion.title,
                searchEngineId: engine.id,
                boundary: activeTab?.dataBoundary ?? .persistent
            )
            omnibox.endEditing()
            if let tab = activeTab { navigate(to: url, in: tab) }

        case .pastQuery:
            // A past query is re-run, not loaded: the row's completion is the
            // query text, not a URL.
            let engine = env.settings.preferences.searchEngine.activeEngine
            guard let url = engine.searchUrl(for: suggestion.completion) else {
                omnibox.endEditing()
                return
            }
            try? env.searchHistory.record(
                query: suggestion.completion,
                searchEngineId: engine.id,
                boundary: activeTab?.dataBoundary ?? .persistent
            )
            omnibox.endEditing()
            if let tab = activeTab { navigate(to: url, in: tab) }

        default:
            guard let url = URL(string: suggestion.completion) else {
                omnibox.endEditing()
                return
            }
            omnibox.endEditing()
            if let tab = activeTab { navigate(to: url, in: tab) }
        }
    }
}

// MARK: - Find bar

struct FindBar: View {
    @Binding var query: String
    var result: FindResult
    var onNext: () -> Void
    var onPrevious: () -> Void
    var onClose: () -> Void

    @Environment(\.browserPalette) private var palette
    @FocusState private var isFocused: Bool

    var body: some View {
        HStack(spacing: BrowserSpacing.compact) {
            HStack(spacing: BrowserSpacing.tight) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 13))
                    .foregroundStyle(palette.secondaryText)
                TextField("在页面中查找", text: $query)
                    .textFieldStyle(.plain)
                    .font(.subheadline)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .focused($isFocused)
                    .onSubmit(onNext)
                if !query.isEmpty {
                    Text(result.displayText)
                        .font(.caption)
                        .foregroundStyle(palette.secondaryText)
                        .monospacedDigit()
                }
            }
            .padding(.horizontal, BrowserSpacing.compact)
            .frame(height: 36)
            .background(palette.controlFill, in: RoundedRectangle(cornerRadius: BrowserRadius.chip, style: .continuous))

            Button(action: onPrevious) {
                Image(systemName: "chevron.up")
            }
            .buttonStyle(.plain)
            .disabled(result.count == 0)

            Button(action: onNext) {
                Image(systemName: "chevron.down")
            }
            .buttonStyle(.plain)
            .disabled(result.count == 0)

            Button(action: onClose) {
                Image(systemName: "xmark")
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, BrowserSpacing.compact)
        .padding(.vertical, BrowserSpacing.tight)
        .background(.bar)
        .onAppear { isFocused = true }
    }
}

// MARK: - Permission prompt

struct PermissionPromptView: View {
    var request: SitePermissionRequest
    var onDecision: (Bool, Bool) -> Void

    @State private var remember = false

    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: iconName)
                .font(.system(size: 34))
                .foregroundStyle(.tint)
                .padding(.top, 28)

            VStack(spacing: 6) {
                Text("允许「\(request.origin)」使用\(request.kind.displayName)？")
                    .font(.headline)
                    .multilineTextAlignment(.center)
                Text("该网站请求访问你的\(request.kind.displayName)。")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .padding(.horizontal, 24)

            Toggle("以后对这个网站都这样", isOn: $remember)
                .padding(.horizontal, 24)

            Spacer()

            VStack(spacing: 10) {
                Button {
                    onDecision(true, remember)
                } label: {
                    Text("允许").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)

                Button {
                    onDecision(false, remember)
                } label: {
                    Text("不允许").frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 28)
        }
        .presentationDetents([.height(360)])
        .presentationDragIndicator(.visible)
    }

    private var iconName: String {
        switch request.kind {
        case .camera: return "camera"
        case .microphone: return "mic"
        case .location: return "location"
        case .sensor: return "gyroscope"
        case .clipboard: return "doc.on.clipboard"
        }
    }
}

// MARK: - Share sheet

/// A `UIActivityViewController` wrapper.
///
/// Shared links go out through the system sheet rather than a hand-built list,
/// which is what gives Vela the same set of destinations as every other app
/// without maintaining a target list.
struct ShareSheet: UIViewControllerRepresentable {
    var items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
