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

    /// Set when an omnibox submission was refused, so the shell can say why
    /// instead of closing the field as if nothing had happened.
    @State private var addressNotice: String?
    /// The input that was refused, kept so the alert can offer to search for it.
    @State private var rejectedInput = ""

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
            // The tab's back/forward flags were written when it last finished
            // loading. If its web view was discarded and rebuilt since — which
            // is what the live-web-view cap does to a background tab — the flags
            // describe a web view that no longer exists, so they are re-read
            // from the one that does.
            env.webCoordinator.refreshNavigationAvailability()
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
                // Applied to the stack rather than to the list so every pushed
                // screenshot — the day groups, an entry's detail sheet — shares
                // the palette without each one restating it.
                .browserListSurface()
        }
        .sheet(isPresented: $showDownloads) {
            NavigationStack { DownloadsView() }
                .environment(env)
                .browserListSurface()
        }
        .sheet(isPresented: $showSettings) {
            NavigationStack { SettingsView() }
                .environment(env)
                .browserListSurface()
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
            "无法打开该地址",
            isPresented: Binding(
                get: { addressNotice != nil },
                set: { if !$0 { addressNotice = nil } }
            ),
            presenting: addressNotice
        ) { _ in
            Button("搜索「\(rejectedInput)」") {
                let input = rejectedInput
                addressNotice = nil
                searchRefusedInput(input)
            }
            Button("好", role: .cancel) { addressNotice = nil }
        } message: { notice in
            Text(notice)
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
                } else if let failure = tab.lastFailure, tab.loadState.isFailure {
                    // A failed navigation shows the error surface *instead of*
                    // the web view, but the web view is kept: it is what the
                    // retry re-uses, and it holds whatever the process still has.
                    WebPageErrorView(
                        failure: failure,
                        canGoBack: tabManager.webView(for: tab.id)?.canGoBack ?? false,
                        onReload: { retry(tab) },
                        onGoBack: {
                            env.webCoordinator.goBack()
                        },
                        onCopyAddress: {},
                        onHome: { goHome(tab) }
                    )
                    .id("error-\(tab.id)-\(tab.navigationSerial)")
                } else if let webView = tabManager.webView(for: tab.id) {
                    WebViewHost(
                        webView: webView,
                        onScroll: { offset in
                            handleScroll(offset: offset)
                        },
                        onProgress: { progress in
                            tab.estimatedProgress = progress
                        }
                    )
                    .id("web-\(tab.id)")
                } else {
                    // A cold tab with no web view at all. Materialising happens
                    // in `onAppear` rather than here: creating a web view during
                    // view evaluation would mutate published state mid-update.
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
    /// up under the status bar without the omnibox itself moving — which is what
    /// lets the omnibox be inset from the top edge and still have the blur
    /// behind it start at the very top of the screen.
    private var topBar: some View {
        OmniboxView(
            viewModel: omnibox,
            isLoading: activeTab?.isLoading ?? false,
            progress: activeTab?.estimatedProgress ?? 0,
            placeholder: omniboxPlaceholder,
            onReload: reloadActiveTab,
            onStop: {
                guard let tab = activeTab else { return }
                tabManager.stopLoading(tab: tab)
            }
        )
        .padding(.horizontal, BrowserChrome.sideInset)
        .padding(.top, BrowserChrome.topInset)
        .padding(.bottom, BrowserChrome.topInset)
        .browserChromeSubstrate(edge: .top)
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
        VStack(spacing: BrowserSpacing.tight) {
            // An HTTP error status is reported here, over the page the server
            // sent, rather than replacing it.
            if let tab = activeTab, tab.serverStatus >= 400, !tab.isHome {
                ServerStatusNotice(status: tab.serverStatus) {
                    tab.serverStatus = 0
                }
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }

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
                    canGoBack: canGoBack,
                    canGoForward: canGoForward,
                    adBlockActive: env.settings.adBlockSettings.preferences.enabled,
                    readerAvailable: env.settings.preferences.readerModeAvailable && !(activeTab?.isHome ?? true),
                    onAction: handleToolbarAction
                )
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .padding(.horizontal, BrowserChrome.sideInset)
        .padding(.top, BrowserSpacing.tight)
        .padding(.bottom, BrowserChrome.bottomInset)
        .browserChromeSubstrate(edge: .bottom)
        .offset(y: toolbarOffset)
    }

    // MARK: - Back and forward availability

    /// Whether the back button should be live.
    ///
    /// True on any page, not only on a page with history: backing out of the
    /// first page of a tab returns to the home surface rather than doing
    /// nothing.
    ///
    /// True on the home surface too, when there is a page behind it. The home
    /// surface is not a document — it is the shell choosing to show the native
    /// surface instead of the web view, which still holds the page — so backing
    /// out of it returns to that page rather than walking WebKit's list. That
    /// distinction matters: with the old code, pressing back from the home
    /// surface called `goBack()` on the hidden web view, which stepped one
    /// entry *further* down the history and re-opened the page before the one
    /// the user had actually been reading.
    private var canGoBack: Bool {
        guard let tab = activeTab else { return false }
        if tab.isHome { return !tab.url.isEmpty }
        return true
    }

    /// Whether the forward button should be live.
    ///
    /// Read from the tab's mirrored copy of WebKit's list rather than asked of
    /// the web view directly, so the toolbar is a pure function of observable
    /// state and re-renders when the list changes. The home surface pins it off
    /// because the list's position is only meaningful relative to a document
    /// that is on screen.
    private var canGoForward: Bool {
        guard let tab = activeTab, !tab.isHome else { return false }
        return tab.canGoForward
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
            target = BrowserMetrics.toolbarCollapseDistance
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
            guard let tab = activeTab else { return }
            if tab.isHome {
                // Coming back out of the home surface, which is not a page.
                returnToPage(tab)
                return
            }
            // WebKit is the authority here, not the button's own enabled state:
            // the flags are a mirror of its list, and acting on the mirror
            // instead of on the list is what would let a stale `true` issue a
            // `goBack()` that does nothing. When there is genuinely nothing
            // behind the page, the fallback is the home surface.
            if !env.webCoordinator.goBack() {
                goHome(tab)
            }

        case .forward:
            env.webCoordinator.goForward()

        case .home:
            guard let tab = activeTab else { return }
            goHome(tab)

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

    /// Returns a tab to the native home surface.
    ///
    /// The page is stopped before it is left: a home surface over a document
    /// still fetching is a document the user has stopped looking at, and its
    /// callbacks would keep arriving into hidden state.
    ///
    /// The tab keeps its URL, its title and its web view. That is what makes the
    /// surface a place the user can come back from — the address bar already
    /// shows nothing while `isHome` is set, so there is no reason to throw the
    /// page away, and throwing it away is what made the old home button a
    /// one-way door.
    private func goHome(_ tab: BrowserTabState) {
        tabManager.webView(for: tab.id)?.stopLoading()
        isReaderActive = false
        readerArticle = nil
        showFindBar = false
        findQuery = ""
        env.webCoordinator.clearFindInPage()
        tab.isHome = true
        tab.isLoading = false
        tab.estimatedProgress = 0
        toolbarOffset = 0
        lastScrollOffset = 0
        tabManager.persistSession()
        syncAddressText()
    }

    /// Shows the page a tab is already holding, without navigating.
    ///
    /// The counterpart to `goHome`. The URL is taken from the web view when it
    /// has one, because an in-page history change updates the web view before
    /// anything else knows about it, and the tab's copy would otherwise restore
    /// the address of an earlier document.
    private func returnToPage(_ tab: BrowserTabState) {
        if let current = tabManager.webView(for: tab.id)?.url?.absoluteString, !current.isEmpty {
            tab.url = current
        }
        guard !tab.url.isEmpty else { return }
        tab.isHome = false
        // The flags were last written when the tab was on this page, but the web
        // view may have been rebuilt since; re-reading them is what keeps the
        // forward button honest the moment the page reappears.
        env.webCoordinator.refreshNavigationAvailability()
        syncAddressText()
    }

    @ViewBuilder
    private var menuContent: some View {
        Button("历史记录", systemImage: "clock.arrow.circlepath") { showHistory = true }
        Button("下载", systemImage: "arrow.down.circle") { showDownloads = true }
        Button("在页面中查找", systemImage: "magnifyingglass") { showFindBar = true }
        Button("读取模式", systemImage: "doc.plaintext") { activateReaderMode() }
        Button("隐藏页面元素", systemImage: "eye.slash") {
            guard let tab = activeTab, tabManager.webView(for: tab.id) != nil else { return }
            env.webCoordinator.armElementPicker()
            // The picker script has to be in the page, and a configuration only
            // applies to the next navigation, so the page is reloaded.
            _ = tabManager.reload(tab: tab)
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
        _ = tabManager.reload(tab: tab)
    }

    private func toggleAdBlock() {
        let enabled = env.settings.adBlockSettings.preferences.enabled
        env.settings.setAdBlockEnabled(!enabled)
        Task {
            await env.refreshAdBlockRules()
            // Content rules only apply to a new document, so the page is
            // reloaded to make the change visible.
            guard let tab = tabManager.activeTab else { return }
            _ = tabManager.reload(tab: tab)
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
        _ = tabManager.reload(tab: tab)
    }

    /// Runs the failed navigation again.
    ///
    /// Deliberately not `reloadActiveTab`: a tab showing the error surface may
    /// have no committed document at all, in which case `reload()` is a no-op on
    /// its web view and the button would appear to do nothing. `TabManager.reload`
    /// decides between re-requesting and re-displaying; this only has to say
    /// which tab.
    private func retry(_ tab: BrowserTabState) {
        _ = tabManager.reload(tab: tab)
    }

    // MARK: - Navigation

    private func submitAddressBar(_ input: String) {
        guard let tab = activeTab else { return }
        let engine = env.settings.preferences.searchEngine.activeEngine

        switch BrowserUrlResolver.resolve(input: input, searchEngine: engine) {
        case let .navigate(url):
            omnibox.endEditing()
            navigate(to: url, in: tab)

        case let .handOff(url):
            // A scheme that belongs to another app. Handing it to the system
            // without touching the tab is what keeps the page the user is on
            // where it was — the same reason the web engine does not navigate to
            // one either.
            omnibox.endEditing()
            UIApplication.shared.open(url)

        case let .search(url):
            try? env.searchHistory.record(
                query: input,
                searchEngineId: engine.id,
                boundary: tab.dataBoundary
            )
            omnibox.endEditing()
            navigate(to: url, in: tab)

        case let .rejected(reason):
            // An input the browser will not act on is reported. Silently closing
            // the omnibox — which is what used to happen for every one of these —
            // makes a refused scheme look like a browser that lost the keystroke.
            omnibox.endEditing()
            addressNotice = Self.message(for: reason, input: input)
            rejectedInput = input
        }
    }

    private static func message(for reason: AddressBarRejection, input: String) -> String {
        switch reason {
        case .empty:
            return "请输入网址或搜索内容。"
        case let .unsupportedScheme(scheme):
            return "Vela 无法打开 \(scheme): 开头的地址。"
        case .noUsableSearchEngine:
            return "当前搜索引擎没有配置搜索地址模板，无法搜索。"
        }
    }

    /// Searches for an input that was refused, which is what the refusal alert
    /// offers as the way forward.
    private func searchRefusedInput(_ input: String) {
        guard let tab = activeTab else { return }
        let engine = env.settings.preferences.searchEngine.activeEngine
        guard let url = engine.searchUrl(for: input) else { return }
        try? env.searchHistory.record(
            query: input,
            searchEngineId: engine.id,
            boundary: tab.dataBoundary
        )
        navigate(to: url, in: tab)
    }

    private func navigate(to url: URL, in tab: BrowserTabState) {
        // An external scheme cannot be loaded, so it is handed to the system.
        if let scheme = url.scheme?.lowercased(),
           BrowserUrlResolver.externalSchemes.contains(scheme) {
            UIApplication.shared.open(url)
            return
        }

        // `TabManager` owns the load, so an address-bar navigation and a link
        // opened into a new tab go through the same path — including the one
        // that decides whether to create the tab's web view yet. It also clears
        // the home flag and writes the URL onto the tab.
        tabManager.load(url: url, in: tab)
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
        .foregroundStyle(palette.primaryText)
        .padding(.horizontal, BrowserSpacing.compact + 2)
        .padding(.vertical, BrowserSpacing.tight)
        // The same floating panel as the toolbar it sits above, so opening the
        // find bar reads as one more control arriving in the chrome rather than
        // as a second kind of surface.
        .browserFloatingChrome(
            radius: BrowserRadius.floating,
            material: .regularMaterial,
            tintStrength: 0.5,
            elevation: .card
        )
        .onAppear { isFocused = true }
    }
}

// MARK: - Permission prompt

struct PermissionPromptView: View {
    @Environment(\.browserPalette) private var palette

    var request: SitePermissionRequest
    var onDecision: (Bool, Bool) -> Void

    @State private var remember = false

    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: iconName)
                .font(.system(size: 30))
                .foregroundStyle(palette.accent)
                .frame(width: 62, height: 62)
                .background(palette.accent.opacity(0.12), in: Circle())
                .padding(.top, 28)

            VStack(spacing: 6) {
                Text("允许「\(request.origin)」使用\(request.kind.displayName)？")
                    .font(.headline)
                    .foregroundStyle(palette.primaryText)
                    .multilineTextAlignment(.center)
                Text("该网站请求访问你的\(request.kind.displayName)。")
                    .font(.subheadline)
                    .foregroundStyle(palette.secondaryText)
                    .multilineTextAlignment(.center)
            }
            .padding(.horizontal, 24)

            Toggle("以后对这个网站都这样", isOn: $remember)
                .tint(palette.accent)
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
        .background(palette.surface)
        .presentationDetents([.height(380)])
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
