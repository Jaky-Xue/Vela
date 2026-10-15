//
//  BrowserShellView.swift
//  Vela
//
//  The browser screen. Ported from `AiraBrowser/entry/src/main/ets/app/pages/BrowserShellPage.ets`
//  and the shell coordinates it drives — `BrowserShellViewModel.ets`,
//  `BrowserShellPresentationCoordinator.ets`, `BrowserShellRouteCoordinator.ets`
//  and `BrowserRootBottomPanelSessionCoordinator.ets` (Aira Browser 3.7.4,
//  GPL-3.0).
//
//  Aira splits the shell across a page, a view model and about twenty
//  coordinators because ArkUI has no observation system that can survive that
//  much state in one component. SwiftUI's `@Observable`/`@Published` handles it
//  in one view, so the layering collapses — but the *composition rules* are
//  kept: the shell owns which surface is visible, and the toolbar, address bar
//  and overlays are pure functions of that state.
//

import SwiftUI
import UIKit
import WebKit

struct BrowserShellView: View {
    @EnvironmentObject private var env: AppEnvironment
    @Environment(\.browserPalette) private var palette

    @State private var addressText: String = ""
    @State private var isEditingAddress = false
    @State private var suggestions: [OmniboxSuggestion] = []

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

    private var tabManager: TabManager { env.tabManager }

    private var activeTab: BrowserTabState? { tabManager.activeTab }

    var body: some View {
        ZStack(alignment: .bottom) {
            palette.surface.ignoresSafeArea()

            // The web surface. A stable identity per tab keeps SwiftUI from
            // rebuilding the representable when the tab strip changes.
            if let tab = activeTab {
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
                        // pressure. Materialising happens in `onAppear` rather
                        // than here: creating a web view during view evaluation
                        // would mutate published state mid-update.
                        Color.clear
                            .onAppear {
                                tabManager.activateTab(id: tab.id)
                            }
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                BrowserEmptyState(
                    systemImage: "square.on.square",
                    title: "没有标签页",
                    message: "点击标签页按钮新建一个。"
                )
            }

            // The reading surface replaces the web view when reader mode is on.
            if isReaderActive, let article = readerArticle {
                ReaderView(
                    article: article,
                    onClose: {
                        isReaderActive = false
                        readerArticle = nil
                    }
                )
                .transition(.move(edge: .bottom))
            }

            chrome
        }
        .environment(\.browserPalette, activePalette)
        .onAppear(perform: syncAddressText)
        .onChange(of: tabManager.activeTabId) { _, _ in
            isReaderActive = false
            readerArticle = nil
            showFindBar = false
            findQuery = ""
            env.webCoordinator.clearFindInPage()
            syncAddressText()
        }
        .onChange(of: activeTab?.url) { _, _ in syncAddressText() }
        .sheet(isPresented: $showTabsOverview) {
            TabsOverviewView()
                .environmentObject(env)
        }
        .sheet(isPresented: $showBookmarks) {
            NavigationStack { BookmarksView() }
                .environmentObject(env)
        }
        .sheet(isPresented: $showHistory) {
            NavigationStack { HistoryView() }
                .environmentObject(env)
        }
        .sheet(isPresented: $showDownloads) {
            NavigationStack { DownloadsView() }
                .environmentObject(env)
        }
        .sheet(isPresented: $showSettings) {
            NavigationStack { SettingsView() }
                .environmentObject(env)
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
            env.webCoordinator.pendingJavaScriptDialog?.message ?? "",
            isPresented: Binding(
                get: { env.webCoordinator.pendingJavaScriptDialog != nil },
                set: { if !$0 { env.webCoordinator.resolveJavaScriptDialog(confirmed: false, text: nil) } }
            ),
            presenting: env.webCoordinator.pendingJavaScriptDialog
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
                get: { env.webCoordinator.pendingExternalNavigation != nil },
                set: { if !$0 { env.webCoordinator.dismissExternalNavigation() } }
            ),
            presenting: env.webCoordinator.pendingExternalNavigation
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
                get: { env.webCoordinator.pendingPermissionRequest != nil },
                set: { _ in }
            )
        ) {
            if let request = env.webCoordinator.pendingPermissionRequest {
                PermissionPromptView(request: request) { allow, remember in
                    env.webCoordinator.resolvePermissionRequest(allow: allow, remember: remember)
                }
            }
        }
    }

    // MARK: - Palette

    private var activePalette: BrowserPalette {
        BrowserPalette.all.first { $0.id == env.settings.preferences.themePaletteId }
            ?? BrowserPalette.default
    }

    // MARK: - Chrome

    private var chrome: some View {
        VStack(spacing: 0) {
            if showFindBar {
                FindBar(
                    query: $findQuery,
                    result: env.webCoordinator.findResult,
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

            if isEditingAddress {
                OmniboxSuggestionList(
                    suggestions: suggestions,
                    onSelect: { suggestion in
                        commitSuggestion(suggestion)
                    }
                )
                .frame(maxHeight: 320)
                .transition(.opacity)
            }

            VStack(spacing: 8) {
                AddressBarView(
                    text: $addressText,
                    isEditing: $isEditingAddress,
                    isLoading: activeTab?.isLoading ?? false,
                    progress: activeTab?.estimatedProgress ?? 0,
                    privacyMode: activeTab?.privacyMode ?? .regular,
                    displayUrl: displayUrl,
                    onCommit: { input in
                        isEditingAddress = false
                        suggestions = []
                        submitAddressBar(input)
                    },
                    onCancel: {
                        isEditingAddress = false
                        suggestions = []
                        syncAddressText()
                    },
                    onReload: reloadActiveTab
                )
                .onChange(of: addressText) { _, newValue in
                    guard isEditingAddress else { return }
                    suggestions = env.makeOmniboxSuggestions(for: newValue)
                }

                BottomToolbarView(
                    actions: BrowserToolbarAction.defaultOrder,
                    tabCount: tabManager.tabs.count,
                    canGoBack: activeTab?.canGoBack ?? false,
                    canGoForward: activeTab?.canGoForward ?? false,
                    adBlockActive: env.settings.adBlockSettings.preferences.enabled,
                    readerAvailable: env.settings.preferences.readerModeAvailable && !(activeTab?.isHome ?? true),
                    onAction: handleToolbarAction
                )
            }
            .padding(.horizontal, 12)
            .padding(.top, 8)
            .padding(.bottom, 4)
            .background(.bar)
            .offset(y: toolbarOffset)
        }
    }

    private var displayUrl: String {
        guard let tab = activeTab else { return "" }
        return tab.isHome ? "" : tab.url
    }

    private func syncAddressText() {
        guard !isEditingAddress else { return }
        addressText = ""
    }

    // MARK: - Scrolling

    /// Collapses the chrome as the page scrolls down and restores it on any
    /// upward movement. Ported from `BrowserBottomChromeScrollCoordinator`.
    ///
    /// The restore is unconditional on direction rather than proportional to
    /// distance: a user who scrolls up even slightly is looking for the
    /// controls, and making them scroll a threshold's worth first is the
    /// behaviour that makes a collapsing toolbar feel broken.
    private func handleScroll(offset: Double) {
        let previous = lastScrollOffset
        lastScrollOffset = offset

        withAnimation(.easeOut(duration: 0.2)) {
            if offset <= 8 {
                toolbarOffset = 0
            } else if offset > previous {
                toolbarOffset = BrowserMetrics.toolbarHeight + 28
            } else {
                toolbarOffset = 0
            }
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
                // Backing out of the last page returns to the home surface,
                // which is `BrowserHomeTerminalBackPlan` in the ArkTS tree.
                tab.isHome = true
                tab.url = ""
                tab.title = ""
            }

        case .forward:
            tabManager.webView(for: activeTab?.id ?? "")?.goForward()

        case .home:
            guard let tab = activeTab else { return }
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
            // applies to the next navigation, so the page is reloaded. Aira has
            // the same constraint and reloads too.
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
        guard let webView = tabManager.webView(for: tab.id) else { return }
        let preferences = env.settings.preferences
        let next = !preferences.desktopSiteByDefault
        env.settings.update { $0.desktopSiteByDefault = next }
        webView.customUserAgent = next ? BrowserUserAgent.defaultUserAgent : BrowserUserAgent.mobileUserAgent
        webView.reload()
    }

    private func toggleAdBlock() {
        let enabled = env.settings.adBlockSettings.preferences.enabled
        env.settings.setAdBlockEnabled(!enabled)
        Task {
            await env.refreshAdBlockRules()
            // Content rules only apply to a new document, so the page is
            // reloaded to make the change visible. Ported from
            // `AdBlockRuntimeGenerationCoordinator`, which reloads for the same
            // reason.
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
        guard let url = BrowserUrlResolver.resolveNavigation(input: input, searchEngine: engine) else { return }

        // A search records the query; a direct URL does not. Ported from the
        // split in `BrowserSearchInvocationAdapter`.
        if BrowserUrlResolver.isSearchQuery(input) {
            try? env.searchHistory.record(
                query: input,
                searchEngineId: engine.id,
                boundary: tab.dataBoundary
            )
        }
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
    }

    private func commitSuggestion(_ suggestion: OmniboxSuggestion) {
        isEditingAddress = false
        suggestions = []

        switch suggestion.kind {
        case .openTab(let tabId):
            tabManager.activateTab(id: tabId)
        case let .search(engineId):
            var engine = env.settings.preferences.searchEngine.activeEngine
            if engine.id != engineId {
                env.settings.setDefaultSearchEngine(id: engineId)
                engine = env.settings.preferences.searchEngine.activeEngine
            }
            guard let url = engine.searchUrl(for: suggestion.title) else { return }
            try? env.searchHistory.record(
                query: suggestion.title,
                searchEngineId: engine.id,
                boundary: activeTab?.dataBoundary ?? .persistent
            )
            if let tab = activeTab { navigate(to: url, in: tab) }
        default:
            guard let url = URL(string: suggestion.completion) else { return }
            if let tab = activeTab { navigate(to: url, in: tab) }
        }
        addressText = ""
    }
}

// MARK: - Suggestion list

struct OmniboxSuggestionList: View {
    var suggestions: [OmniboxSuggestion]
    var onSelect: (OmniboxSuggestion) -> Void

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(suggestions) { suggestion in
                    Button {
                        onSelect(suggestion)
                    } label: {
                        HStack(spacing: 12) {
                            if suggestion.host.isEmpty {
                                Image(systemName: suggestion.iconName)
                                    .frame(width: 28, height: 28)
                                    .foregroundStyle(.secondary)
                            } else {
                                SiteIconView(host: suggestion.host, size: 28)
                            }

                            VStack(alignment: .leading, spacing: 1) {
                                Text(suggestion.title)
                                    .font(.system(size: 15))
                                    .lineLimit(1)
                                    .foregroundStyle(.primary)
                                if !suggestion.subtitle.isEmpty {
                                    Text(suggestion.subtitle)
                                        .font(.caption)
                                        .lineLimit(1)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            Spacer(minLength: 0)
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 9)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)

                    Divider().padding(.leading, 56)
                }
            }
        }
        .background(.bar)
    }
}

// MARK: - Find bar

struct FindBar: View {
    @Binding var query: String
    var result: FindResult
    var onNext: () -> Void
    var onPrevious: () -> Void
    var onClose: () -> Void

    @FocusState private var isFocused: Bool

    var body: some View {
        HStack(spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                TextField("在页面中查找", text: $query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 15))
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .focused($isFocused)
                    .onSubmit(onNext)
                if !query.isEmpty {
                    Text(result.displayText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }
            .padding(.horizontal, 10)
            .frame(height: 36)
            .background(Color(.tertiarySystemFill), in: RoundedRectangle(cornerRadius: 10, style: .continuous))

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
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
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
