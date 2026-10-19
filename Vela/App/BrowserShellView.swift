//
//  BrowserShellView.swift
//  Vela
//
//  The browser screen: the web surface, the top command bar, and every overlay
//  the shell can present.
//
//  One view holds all of it because SwiftUI can express it that way. What the
//  shell owns is *which surface is visible*; the chrome and the overlays are
//  pure functions of that, so a layering of intermediate objects would have
//  nothing to arbitrate.
//
//  The chrome is one command bar at the bottom of the screen — back and
//  forward, the omnibox, tabs and the menu — floating on Liquid Glass above
//  the page. There is no other bar: every secondary action (bookmarks,
//  history, find, reader, desktop site, share) lives in the menu, which is
//  what keeps the bar down to five controls. The page runs full-bleed, the
//  way Safari's does, so the glass has content to refract; the web view's
//  top content inset holds the page's own start point below the status bar,
//  the bottom inset keeps its tail clear of the bar, and the whole bar
//  slides away when the user scrolls down and returns on any upward
//  movement. The keyboard never moves it: a site's own input field raising
//  the keyboard is no reason for the browser's controls to leave the edge
//  they live on.
//
//  The omnibox session — the debounced suggestion list, the highlighted row,
//  the disclosure state — lives in `OmniboxViewModel` rather than here, which
//  is what keeps the suggestion list, the field text and the editing flag from
//  being three pieces of state that have to be kept in step by hand.
//

import SwiftUI
import UIKit
import WebKit
import UniformTypeIdentifiers

struct BrowserShellView: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.browserPalette) private var palette
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    /// The omnibox session. Created here rather than inside the view body
    /// because it is long-lived: it survives every tab switch, and rebuilding it
    /// would throw away the user's collapsed-section choices on each one.
    @State private var omnibox: OmniboxViewModel

    @State private var showTabsOverview = false
    @State private var showQRScanner = false
    @State private var qrCopyNotice: String?
    @State private var showBookmarks = false
    @State private var showHistory = false
    @State private var showDownloads = false
    @State private var showSettings = false
    @State private var showPasswords = false
    @State private var showBookshelf = false
    @State private var showMenu = false
    /// Whether the iPad layout's sidebar drawer is open.
    @State private var showPadSidebar = false
    @State private var showAddBookmarkChoice = false
    @State private var showShareSheet = false
    @State private var showFindBar = false
    @State private var findQuery = ""

    @State private var isReaderActive = false
    @State private var readerArticle: ReaderArticle?

    /// The novel reader's layer, when one is open.
    ///
    /// It is a value rather than two optionals so opening a different book or
    /// chapter is one assignment; the reader itself owns the loading that
    /// follows.
    @State private var novelSession: NovelSession?
    /// Why 小说模式 could not open the page.
    @State private var novelNotice: String?

    /// Set when an omnibox submission was refused, so the shell can say why
    /// instead of closing the field as if nothing had happened.
    @State private var addressNotice: String?
    /// The input that was refused, kept so the alert can offer to search for it.
    @State private var rejectedInput = ""

    /// Whether the command bar has slid out of the way under the status bar.
    @State private var chromeHidden = false
    /// How far the user has dragged the bar downward, mid-gesture.
    ///
    /// The bar follows the finger while the drag is in progress and either
    /// commits to hiding or springs back when the finger lifts. Never read in
    /// `body` except through the two modifiers below, so the per-frame writes
    /// cost nothing beyond the offset itself.
    @State private var chromeDragOffset: CGFloat = 0
    /// How far the user has dragged the bar upward, mid-gesture — the gesture
    /// that returns to the home surface. The bar lifts a little with the
    /// finger as the promise of what releasing will do.
    @State private var chromeLiftOffset: CGFloat = 0

    /// Whether the drag-to-hide gesture may act.
    ///
    /// The one state that refuses it is the open omnibox session, where a
    /// downward drag means dismissing the keyboard. Every surface — the home
    /// one included — hides the bar the same way: the bar is the page's
    /// controls, and a page the user is pushing out of the way takes its
    /// controls with it.
    private var canDragChromeAway: Bool {
        guard !omnibox.isEditing else { return false }
        return activeTab != nil
    }
    /// Per-frame scroll bookkeeping, kept out of `@State`.
    ///
    /// Writing `@State` on every scroll message invalidates the shell's body
    /// each frame — exactly the layout work that shows up as dropped frames
    /// while a page scrolls. The box changes without touching SwiftUI; only
    /// the `chromeHidden` threshold transition re-renders.
    @State private var scrollTracker = ShellScrollTracker()

    /// The keyboard's height while visible, from the frame-change notifications.
    ///
    /// The suggestion card's height budget is measured down to the keyboard's
    /// top edge — a card that ignores the keyboard is a card whose last rows
    /// can never be reached.
    @State private var keyboardHeight: CGFloat = 0
    /// The safe-area insets and the height of the safe-area rectangle, measured
    /// once the view is in the hierarchy and again on rotation.
    @State private var safeTop: CGFloat = 0
    @State private var safeBottom: CGFloat = 0
    @State private var safeRectHeight: CGFloat = 0

    /// Whether the surface the chrome floats over reads light — a bright
    /// wallpaper, a pale page — and the bar should therefore draw black ink.
    /// Decided by `updateChromeForeground` from the strip behind the bar; the
    /// initial value matches the shipped palette's dark chrome until the first
    /// measurement lands.
    @State private var chromeForegroundIsLight = false
    @State private var chromeSampleTask: Task<Void, Never>?

    /// The one animation the chrome uses.
    ///
    /// A spring rather than an ease: the bar leaves and returns along a path
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

    private static let padSidebarWidth: CGFloat = 286

    /// Whether the shell draws the iPad layout.
    ///
    /// 自动 follows the device and the window: an iPad in a regular-width
    /// window gets the two-column chrome, a phone or a narrow iPad Split View
    /// window keeps the single column.
    private var usesPadLayout: Bool {
        switch env.settings.interfaceLayout {
        case .phone:
            return false
        case .pad:
            return true
        case .automatic:
            return UIDevice.current.userInterfaceIdiom == .pad && horizontalSizeClass == .regular
        }
    }

    /// What the bottom chrome takes from a surface's tail.
    ///
    /// In the phone layout the web view runs edge to edge, so the home
    /// indicator's inset is part of the clearance. In the iPad layout the
    /// content column already ends at the safe area, and only the floating bar
    /// overlaps it.
    private var bottomChromeClearance: CGFloat {
        // The iPad layout puts the navigation in a top bar, so the page can run
        // to the bottom edge of its column.
        usesPadLayout
            ? 0
            : safeBottom + BrowserChrome.barHeight + BrowserChrome.barGap
    }

    private var shellRoot: some View {
        ZStack {
            AmbientBackgroundView()

            if usesPadLayout {
                padRoot
            } else {
                contentSurface
            }
        }
        .background { safeAreaReader }
        .background {
            EdgeSwipeBackBridge(isEnabled: edgeSwipeBackEnabled) {
                handleEdgeSwipeBack()
            }
        }
        .overlay(alignment: .bottom) {
            // The novel reader owns the screen while it is open: its own
            // header and chapter controls are the chrome. The iPad layout has
            // its navigation in the top bar, so the phone command bar is not
            // drawn there at all.
            if novelSession == nil && !usesPadLayout {
                commandBar
            }
        }
        .overlay(alignment: .bottom) {
            if novelSession == nil {
                floatingToolsInGlassContainer
            }
        }
        .overlay {
            // The overview is a layer of this hierarchy, not a presented
            // controller. A full-screen cover's geometry can survive a
            // rotation wedged at the size it was presented at — the overview
            // once laid itself out for a portrait window inside a landscape
            // one: four narrow columns, the header pushed off-screen, touch
            // mapping gone with it. Nothing presented here; a layer rotates
            // with the window, because everything in this hierarchy already
            // provably does.
            if showTabsOverview {
                TabsOverviewView(
                    onClose: { showTabsOverview = false }
                )
                .transition(.opacity.combined(with: .move(edge: .bottom)))
                .zIndex(20)
            }
        }
        .animation(.snappy(duration: 0.3), value: showTabsOverview)
        .overlay {
            // The scanner rides the same in-hierarchy rule the overview does:
            // a presented controller's geometry is the thing that wedges on
            // rotation, and a layer does not.
            if showQRScanner {
                QRScannerView(
                    onRecognize: { handleScannedText($0) },
                    onClose: { showQRScanner = false }
                )
                .transition(.opacity)
                .zIndex(30)
            }
        }
        .animation(.snappy(duration: 0.2), value: showQRScanner)
        .overlay {
            // The novel reader is a layer for the same rotation reason the
            // overview is: the chapter must keep its own geometry when the
            // window turns.
            if let session = novelSession {
                NovelReaderView(
                    book: session.book,
                    initialChapter: session.chapter,
                    onClose: { novelSession = nil },
                    onOpenInBrowser: { url in
                        novelSession = nil
                        openInBrowser(url)
                    }
                )
                .transition(.opacity)
                .zIndex(40)
            }
        }
        .animation(.snappy(duration: 0.24), value: novelSession?.id)
        .alert(
            "无法进入小说模式",
            isPresented: Binding(
                get: { novelNotice != nil },
                set: { if !$0 { novelNotice = nil } }
            ),
            presenting: novelNotice
        ) { _ in
            Button("好", role: .cancel) { novelNotice = nil }
        } message: { message in
            Text(message)
        }
        .alert(
            "下载文件？",
            isPresented: Binding(
                get: { env.downloads.pendingPrompt != nil },
                set: { if !$0 { env.downloads.dismissPendingPrompt() } }
            ),
            presenting: env.downloads.pendingPrompt
        ) { _ in
            Button("下载") { env.downloads.confirmPendingPrompt() }
            Button("取消", role: .cancel) { env.downloads.dismissPendingPrompt() }
        } message: { task in
            Text("\(task.displayName)\n\(task.displaySize)")
        }
        .alert(
            "无法识别为网址",
            isPresented: Binding(
                get: { qrCopyNotice != nil },
                set: { if !$0 { qrCopyNotice = nil } }
            ),
            presenting: qrCopyNotice
        ) { _ in
            Button("好", role: .cancel) { qrCopyNotice = nil }
        } message: { text in
            Text(
                """
                内容已复制到剪贴板：
                \(text)
                """
            )
        }
        // The keyboard never rearranges the shell. Keyboard avoidance applied
        // to the bar itself does not hold: the bottom-aligned overlay resolves
        // its position against the container's safe area, which still contains
        // the keyboard, so a site's own search field lifted the bar to sit
        // above the keyboard — the browser's controls parked mid-screen over
        // the page. Ignoring the keyboard here, at the root the inset enters
        // through, takes it out of the equation for the whole subtree: the bar
        // stays on its edge and is simply covered while the keyboard is up.
        // The two surfaces that do track the keyboard measure it themselves —
        // the search page ends at its top edge, and the find bar lifts above
        // it by the same measurement.
        .ignoresSafeArea(.keyboard)
        .animation(Self.chromeAnimation, value: omnibox.isEditing)
        .onAppear {
            wireOmnibox()
            syncAddressText()
            updateChromeForeground()
            // The hardware-keyboard menu is built by the app; this is the one
            // handler it can call into.
            env.commands.register { command in
                handleBrowserCommand(command)
            }
        }
        .onDisappear {
            env.commands.unregister()
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.keyboardWillChangeFrameNotification)) { note in
            let end = (note.userInfo?[UIApplication.keyboardFrameEndUserInfoKey] as? NSValue)?
                .cgRectValue ?? .zero
            let screenHeight = max(UIScreen.main.bounds.height, end.maxY)
            // A docked keyboard runs from its top edge to the bottom of the
            // screen, so the occlusion is that whole span. A floating keyboard
            // — an iPad panel — does not: it covers only its own frame, and
            // measuring to the screen bottom would credit it with occluding
            // half the page and shrink the suggestion card for nothing.
            let occlusion: CGFloat
            if end.isEmpty {
                occlusion = 0
            } else if screenHeight - end.maxY < 40 {
                occlusion = max(0, screenHeight - end.minY)
            } else {
                occlusion = end.height
            }
            // The keyboard's rise and fall are animated by the system with the
            // same duration, so the card tracks it with a spring of its own
            // rather than snapping between the two states.
            withAnimation(Self.chromeAnimation) {
                keyboardHeight = occlusion
            }
        }
        .onChange(of: tabManager.activeTabId) { _, _ in
            isReaderActive = false            readerArticle = nil
            showFindBar = false
            findQuery = ""
            chromeHidden = false
            scrollTracker.accumulation = 0
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
        .onChange(of: activeTab?.url) { _, _ in
            // A new document is a fresh read: the chrome comes back for it.
            chromeHidden = false
            scrollTracker.accumulation = 0
            syncAddressText()
            updateChromeForeground()
        }
        .onChange(of: activeTab?.loadState) { _, _ in
            updateChromeForeground()
        }
        .onChange(of: env.settings.preferences.homeBackgroundStamp) { _, _ in
            updateChromeForeground()
        }
        .onChange(of: env.settings.preferences.themePaletteId) { _, _ in
            updateChromeForeground()
        }
        .onChange(of: colorScheme) { _, _ in
            updateChromeForeground()
        }
        .onChange(of: omnibox.isEditing) { _, editing in
            // The iPad top bar yields to the search page, and an open tab
            // drawer must not sit over that page.
            if editing {
                showPadSidebar = false
            }
        }
        .onChange(of: scenePhase) { _, phase in
            // Ending a private session is VelaApp's rule for backgrounding, and
            // it destroys every private tab and web view. The overview must not
            // still be presenting them when that runs: dismissing the cover
            // here, synchronously in the same update the cleanup task is
            // scheduled in, is what keeps a full-screen cover from showing a
            // tab strip and an active tab that are deleted from underneath it
            // before the app is even back on screen.
            guard phase == .background, showTabsOverview else { return }
            if !tabManager.privateTabs.isEmpty || tabManager.activeTab == nil {
                showTabsOverview = false
            }
        }
    }

    var body: some View {
        presentations()
    }

    /// Every presentation the shell raises, held in one function off the root
    /// chain.
    ///
    /// The root chain grew large enough that adding to it pushed the type
    /// checker past its budget — the failure surfaced at the file importer at
    /// the chain's far end, but the weight was the whole chain. Splitting the
    /// presentations off hands the checker two moderate expressions instead
    /// of one enormous one.
    private func presentations() -> some View {
        shellRoot
        .sheet(isPresented: $showBookmarks) {
            NavigationStack { BookmarksView() }
                .environment(env)
                .browserAmbientSheet()
        }
        .sheet(isPresented: $showHistory) {
            NavigationStack { HistoryView() }
                .environment(env)
                // Applied to the stack rather than to the list so every pushed
                // screenshot — the day groups, an entry's detail sheet — shares
                // the palette without each one restating it.
                .browserListSurface()
                .browserAmbientSheet()
        }
        .sheet(isPresented: $showDownloads) {
            NavigationStack { DownloadsView() }
                .environment(env)
                .browserListSurface()
                .browserAmbientSheet()
        }
        .sheet(isPresented: $showSettings) {
            NavigationStack { SettingsView() }
                .environment(env)
                .browserListSurface()
                .browserAmbientSheet()
        }
        .sheet(isPresented: $showPasswords) {
            NavigationStack {
                PasswordVaultView()
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button("完成") { showPasswords = false }
                        }
                    }
            }
            .environment(env)
            .browserAmbientSheet()
        }
        .sheet(isPresented: $showBookshelf) {
            NovelBookshelfView { book in
                showBookshelf = false
                // A resumed book that still has its chapter cached opens
                // instantly; otherwise the reader loads it itself.
                openNovel(book, chapter: env.novels.cachedChapter(book: book))
            }
            .environment(env)
        }
        .sheet(isPresented: $showShareSheet) {
            if let tab = activeTab, let url = URL(string: tab.url) {
                ShareSheet(items: [url])
            }
        }
        .sheet(isPresented: $showMenu) {
            MenuPanelView(
                tiles: env.settings.menuLayout.visibleTiles,
                canActOnPage: canActOnPage,
                isPrivateMode: activeTab?.privacyMode == .private,
                isPrivateBrowsingOn: env.settings.preferences.privateBrowsingMode ?? false,
                adBlockEnabled: env.settings.adBlockSettings.preferences.enabled,
                pageTitle: menuPanelTitle,
                onPerform: handleMenuAction,
                onOpenShortcut: handleMenuShortcut
            )
            .environment(env)
            .browserAmbientSheet()
        }
        .sheet(isPresented: $showAddBookmarkChoice) {
            AddBookmarkChoiceSheet(
                url: activeTab?.url ?? "",
                title: activeTab?.title ?? ""
            )
            .environment(env)
            .browserAmbientSheet()
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
                // Dismissing the sheet by any route other than the two buttons
                // is a refusal. Leaving the request set would make the sheet
                // re-present forever, and never calling WebKit's handler would
                // block the page on a question nobody can answer.
                set: { if !$0 { env.webCoordinator.resolvePermissionRequest(allow: false, remember: false) } }
            )
        ) {
            if let request = env.overlays.permissionRequest {
                PermissionPromptView(request: request) { allow, remember in
                    env.webCoordinator.resolvePermissionRequest(allow: allow, remember: remember)
                }
                .browserAmbientSheet()
            }
        }
        .fileImporter(
            isPresented: Binding(
                get: { env.overlays.fileUpload != nil },
                set: { if !$0 { env.webCoordinator.resolveFileUpload(nil) } }
            ),
            allowedContentTypes: [.item],
            allowsMultipleSelection: env.overlays.fileUpload?.allowsMultipleSelection ?? false
        ) { result in
            switch result {
            case .success(let urls):
                // A picked file is readable only inside its security scope, and
                // WebKit copies the contents when the handler runs, so access
                // is opened here and left open for WebKit to read through.
                for url in urls {
                    _ = url.startAccessingSecurityScopedResource()
                }
                env.webCoordinator.resolveFileUpload(urls)
            case .failure:
                env.webCoordinator.resolveFileUpload(nil)
            }
        }
    }

    // MARK: - Safe area

    /// Reads the safe-area geometry once the view is in a window.
    ///
    /// A `GeometryReader` in the background sees the safe-area rectangle the
    /// ZStack is laid out in, so the numbers here are the real insets on this
    /// device, re-read on rotation — which is what the keyboard-aware card
    /// budget and the full-bleed insets need.
    private var safeAreaReader: some View {
        GeometryReader { geo in
            Color.clear
                .onAppear { recordSafeArea(geo) }
                .onChange(of: geo.size) { _, _ in recordSafeArea(geo) }
                .onChange(of: geo.safeAreaInsets) { _, _ in recordSafeArea(geo) }
        }
    }

    private func recordSafeArea(_ geo: GeometryProxy) {
        safeTop = geo.safeAreaInsets.top
        safeBottom = geo.safeAreaInsets.bottom
        safeRectHeight = geo.size.height
    }

    // MARK: - Surfaces

    /// The iPad chrome, after Safari's arrangement: one top bar spanning the
    /// window, a bookmarks strip beneath it, and the page filling the rest.
    /// The tab sidebar is a drawer over the page rather than a permanent
    /// column, so the page keeps the whole width while reading.
    private var padRoot: some View {
        VStack(spacing: 0) {
            // The search page carries its own field; leaving the top bar in
            // place would put two address fields on screen.
            if !omnibox.isEditing {
                padTopBar
                    .zIndex(2)
            }

            ZStack(alignment: .topLeading) {
                VStack(spacing: 0) {
                    if !omnibox.isEditing {
                        BookmarksBarView(
                            onNavigate: { url in
                                navigate(to: url, in: submissionTab)
                            },
                            onOpenManager: { showBookmarks = true }
                        )
                    }
                    contentSurface
                }

                if showPadSidebar {
                    padSidebarLayer
                        .zIndex(3)
                }
            }
        }
        .animation(.snappy(duration: 0.26), value: showPadSidebar)
    }

    private var padInk: Color {
        colorScheme == .dark ? .white : .black
    }

    /// The unified Safari-style top bar: sidebar, back, address, share, tabs,
    /// menu — one glass surface instead of the phone layout's three clusters.
    @ViewBuilder
    private var padTopBar: some View {
        if #available(iOS 26.0, *) {
            GlassEffectContainer(spacing: BrowserChrome.barGap) {
                padTopBarContent
            }
        } else {
            padTopBarContent
        }
    }

    private var padTopBarContent: some View {
        HStack(spacing: 4) {
            chromeButton(
                symbol: "sidebar.left",
                isEnabled: true,
                label: showPadSidebar ? "收起标签页侧边栏" : "显示标签页侧边栏",
                foreground: padInk
            ) {
                withAnimation(.snappy(duration: 0.26)) {
                    showPadSidebar.toggle()
                }
            }

            chromeButton(
                symbol: "chevron.left",
                isEnabled: canGoBack,
                label: "后退",
                foreground: padInk
            ) {
                goBack()
            }
            .contextMenu { backHistoryMenu }

            OmniboxView(
                viewModel: omnibox,
                isLoading: activeTab?.isLoading ?? false,
                progress: activeTab?.estimatedProgress ?? 0,
                placeholder: omniboxPlaceholder,
                onReload: reloadActiveTab,
                onStop: {
                    guard let tab = activeTab else { return }
                    tabManager.stopLoading(tab: tab)
                },
                foregroundOverride: padInk
            )
            .frame(maxWidth: .infinity)

            if canActOnPage {
                chromeButton(
                    symbol: "square.and.arrow.up",
                    isEnabled: true,
                    label: "分享",
                    foreground: padInk
                ) {
                    showShareSheet = true
                }
            }

            tabsButton(ink: padInk)

            chromeButton(
                symbol: "ellipsis",
                isEnabled: true,
                label: "菜单",
                foreground: padInk
            ) {
                showMenu = true
            }
        }
        .padding(.horizontal, 8)
        .frame(height: 50)
        .browserFloatingChrome(
            radius: 25,
            material: .regularMaterial,
            tintStrength: 0.35,
            elevation: .card
        )
        .padding(.horizontal, 12)
        .padding(.top, 8)
        .padding(.bottom, 6)
    }

    /// The tab drawer. It sits over the content only (below the top bar), with
    /// a scrim that closes it on a tap outside.
    private var padSidebarLayer: some View {
        ZStack(alignment: .topLeading) {
            Color.black
                .opacity(colorScheme == .dark ? 0.30 : 0.14)
                .ignoresSafeArea()
                .contentShape(Rectangle())
                .onTapGesture { showPadSidebar = false }

            BrowserSidebarView(
                onClose: { showPadSidebar = false },
                onOpenBookmarks: {
                    showPadSidebar = false
                    showBookmarks = true
                },
                onOpenHistory: {
                    showPadSidebar = false
                    showHistory = true
                },
                onOpenDownloads: {
                    showPadSidebar = false
                    showDownloads = true
                },
                onOpenSettings: {
                    showPadSidebar = false
                    showSettings = true
                }
            )
            .frame(width: Self.padSidebarWidth)
            .frame(maxHeight: .infinity)
            .shadow(color: .black.opacity(colorScheme == .dark ? 0.45 : 0.16), radius: 28, x: 10, y: 0)
        }
        .transition(.opacity.combined(with: .move(edge: .leading)))
    }

    /// The page, and whatever floats over it.
    private var contentSurface: some View {
        ZStack(alignment: .bottom) {
            mainSurface

            if omnibox.isEditing {
                OmniboxSearchPageView(
                    viewModel: omnibox,
                    keyboardHeight: keyboardHeight,
                    cardMaxHeight: omniboxCardHeight,
                    topGap: searchPageTopGap
                )
                .transition(.opacity)
            }
        }
        // The keyboard overlays the page — a browser never shrinks its document
        // for a keyboard — and the search page measures down to the keyboard's
        // top edge itself.
        .ignoresSafeArea(.keyboard)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// How far down the screen the search page puts its field: about a third
    /// of the space the keyboard leaves, which is where the reference search
    /// pages place it and where a thumb can still reach the cancel button.
    private var searchPageTopGap: CGFloat {
        let screenHeight = safeRectHeight + safeTop + safeBottom
        let available = screenHeight - keyboardHeight
        return min(max(56, available * 0.3), 320)
    }

    @ViewBuilder
    private var mainSurface: some View {
        if isReaderActive, let article = readerArticle {
            // Reading mode replaces the page rather than covering it. Its own
            // header sits below the chrome, and the article still scrolls
            // under the glass.
            ReaderView(
                article: article,
                onClose: {
                    isReaderActive = false
                    readerArticle = nil
                }
            )
            .id("reader")
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .safeAreaInset(edge: .bottom) {
                // The command bar floats over the surface's tail; the spacer
                // keeps the article's last lines scrollable above it.
                Color.clear.frame(height: bottomChromeClearance)
            }
        } else if let tab = activeTab {
            // A stable identity per tab keeps SwiftUI from rebuilding the
            // representable when the tab strip changes.
            Group {
                if tab.isHome {
                    NewTabHomeView(
                        isPrivate: tab.privacyMode == .private,
                        onNavigate: { url in navigate(to: url, in: tab) },
                        onChromeSwipe: { translation in
                            guard canDragChromeAway else { return }
                            if translation < -48 {
                                setChromeHidden(true)
                            } else if translation > 48 {
                                setChromeHidden(false)
                            }
                        }
                    )
                    .id("home-\(tab.id)")
                    .safeAreaInset(edge: .bottom) {
                        // The command bar floats over the surface's tail; the
                        // spacer keeps the last tiles scrollable above it.
                        Color.clear.frame(height: bottomChromeClearance)
                    }
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
                    .safeAreaInset(edge: .bottom) {
                        Color.clear.frame(height: bottomChromeClearance)
                    }
                } else if let webView = tabManager.webView(for: tab.id) {
                    // 全局顶部保护 decides how the status bar strip is kept.
                    // Off, the page scrolls under the clock with an inset
                    // holding its first line clear — Safari's arrangement. On,
                    // the web view's frame is held below the strip and the
                    // strip shows the surface colour, so the page never paints
                    // there at all.
                    let protectsTop = env.settings.preferences.topProtectionEnabled
                    WebViewHost(
                        webView: webView,
                        // The status bar's height, so the page's own first
                        // line starts below it instead of running under the
                        // clock — while still scrolling underneath, the way
                        // Safari's does. A reserved strip makes the page start
                        // at its own top, so the inset drops to zero there.
                        topContentInset: usesPadLayout ? 0 : (protectsTop ? 0 : safeTop),
                        topReservedInset: usesPadLayout ? 0 : (protectsTop ? safeTop : 0),
                        bottomContentInset: bottomChromeClearance,
                        onScroll: { offset in
                            handleScroll(offset: offset)
                        },
                        onProgress: { progress in
                            tab.estimatedProgress = progress
                        }
                    )
                    .id("web-\(tab.id)")
                    // The phone layout runs the page edge to edge, so the
                    // floating bar has safe-area content to refract. The iPad
                    // layout keeps the page inside its column and below the top
                    // bar, but still lets it run under the home indicator so no
                    // strip of background shows beneath the document.
                    .ignoresSafeArea(edges: usesPadLayout ? .bottom : .all)
                } else {
                    // A cold tab with no web view at all. Materialising happens
                    // in `onAppear` rather than here: creating a web view during
                    // view evaluation would mutate published state mid-update.
                    Color.clear
                        .onAppear {
                            tabManager.activateTab(id: tab.id)
                        }
                        .ignoresSafeArea(edges: .top)
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

    // MARK: - Chrome

    /// The single command bar: back and forward, the omnibox, tabs and menu.
    ///
    /// Three glass surfaces in one row — a pair of history buttons, the
    /// omnibox, and a pair of view controls — because the omnibox is the centre
    /// of the chrome and the four buttons around it are its context. Everything
    /// else in the browser hangs off the menu button.
    ///
    /// The bar sits at the bottom of the screen, above the home indicator,
    /// where a thumb reaches it and where the system's own toolbars live.
    // MARK: - Chrome ink

    /// The ink the bottom chrome draws in: white over a dark backdrop, black
    /// over a light one. The palette decides the chrome's fill, but only the
    /// backdrop behind the glass can decide whether its ink is legible, so the
    /// foreground follows the backdrop and not the palette.
    private var barForeground: Color {
        chromeForegroundIsLight ? .black : .white
    }

    /// How far the bar travels when it hides: its own height, the gap under
    /// it, and the safe-area inset. The overlay already holds the bar above
    /// the inset, so this is the whole distance from its resting edge to the
    /// bottom of the screen, plus a little slack.
    private var hiddenChromeOffset: CGFloat {
        BrowserChrome.barHeight + BrowserChrome.barGap + safeBottom + 16
    }

    /// The bar's glass shapes riding one coordinated layer, with the movement
    /// applied to the layer as a whole.
    ///
    /// `glassEffect` without a container gives every shape its own system
    /// layer, and a rotation can leave a layer parked at its pre-rotation
    /// frame — the ghost second bottom bar a portrait rotation used to show.
    /// The container samples the page once for the whole bar and moves it as
    /// one piece. The offset and the fade live OUTSIDE the container for the
    /// same reason: a transform on a shape inside the container is advice the
    /// system layer may take loosely, while a transform on the container
    /// itself is the layer's own geometry — which is what makes a hide take
    /// the glass with it instead of leaving it behind.
    @ViewBuilder private var commandBar: some View {
        Group {
            if #available(iOS 26.0, *) {
                GlassEffectContainer(spacing: BrowserChrome.barGap) {
                    commandBarContent
                }
            } else {
                commandBarContent
            }
        }
        .padding(.horizontal, BrowserChrome.sideInset)
        // The bottom-aligned overlay already lays the bar out above the
        // home-indicator inset; adding the inset again here lifted the bar a
        // whole safe area off the edge. The gap is all this padding owes.
        .padding(.bottom, BrowserChrome.barGap)
        // Sliding fully out — past the bottom edge — with a fade reads as the
        // bar dissolving into the page rather than parking behind the home
        // indicator. Mid-drag the bar follows the finger downward and fades
        // with distance; dragged upward it lifts a little, promising the home
        // surface on release.
        .offset(y: chromeHidden
            ? hiddenChromeOffset
            : (chromeDragOffset > 0 ? chromeDragOffset : chromeLiftOffset))
        // The search page covers the screen completely, so the bar yields to it
        // while the omnibox session is open — a bottom bar under a search page
        // is chrome the user did not ask for.
        .opacity(omnibox.isEditing ? 0 : chromeHidden ? 0 : max(0, 1 - chromeDragOffset / 140))
        .allowsHitTesting(!chromeHidden && !omnibox.isEditing)
        .animation(Self.chromeAnimation, value: chromeHidden)
        .animation(Self.chromeAnimation, value: omnibox.isEditing)
        // Dragging the bar downward dismisses it, off the bottom edge the way
        // a sheet leaves; dragging it upward returns to the home surface, the
        // same promise the home button makes. The minimum distance keeps a tap
        // on the omnibox or a button from reading as a drag, and the gesture
        // stands down while the omnibox session is open, where a downward drag
        // means dismissing the keyboard.
        .gesture(
            DragGesture(minimumDistance: 12)
                .onChanged { value in
                    guard canDragChromeAway, !chromeHidden else { return }
                    if value.translation.height > 0 {
                        chromeDragOffset = value.translation.height
                        chromeLiftOffset = 0
                    } else {
                        chromeLiftOffset = max(-36, value.translation.height * 0.35)
                        chromeDragOffset = 0
                    }
                }
                .onEnded { value in
                    if canDragChromeAway, !chromeHidden {
                        if value.translation.height > 56 {
                            setChromeHidden(true)
                        } else if value.translation.height < -64 {
                            openHomeTab()
                        }
                    }
                    withAnimation(Self.chromeAnimation) {
                        chromeDragOffset = 0
                        chromeLiftOffset = 0
                    }
                },
            isEnabled: !omnibox.isEditing
        )
        .accessibilityHidden(chromeHidden)
    }

    @ViewBuilder private var floatingToolsInGlassContainer: some View {
        if #available(iOS 26.0, *) {
            GlassEffectContainer(spacing: BrowserChrome.barGap) {
                floatingTools
            }
        } else {
            floatingTools
        }
    }

    private var toolbarLayout: ToolbarLayout { env.settings.toolbarLayout }

    private var commandBarContent: some View {
        // Six points between the pieces rather than eight, and four of padding
        // inside each cluster: the field is the bar's subject, and every point
        // the clusters give back is a point of address.
        HStack(spacing: 6) {
            if !toolbarLayout.leading.isEmpty {
                toolbarCluster(toolbarLayout.leading)
            }

            OmniboxView(
                viewModel: omnibox,
                isLoading: activeTab?.isLoading ?? false,
                progress: activeTab?.estimatedProgress ?? 0,
                placeholder: omniboxPlaceholder,
                onReload: reloadActiveTab,
                onStop: {
                    guard let tab = activeTab else { return }
                    tabManager.stopLoading(tab: tab)
                },
                foregroundOverride: barForeground
            )
            .frame(maxWidth: .infinity)

            if !toolbarLayout.trailing.isEmpty {
                toolbarCluster(toolbarLayout.trailing)
            }
        }
    }

    /// One side of the omnibox, as the user arranged it.
    private func toolbarCluster(_ controls: [ToolbarControl]) -> some View {
        HStack(spacing: 2) {
            ForEach(controls) { control in
                toolbarButton(control)
            }
        }
        .padding(.horizontal, 4)
        .frame(height: BrowserChrome.barHeight)
        .browserFloatingChrome(radius: BrowserRadius.omnibox, tintStrength: 0.5, elevation: .card)
    }

    /// One control in the bar. Back keeps its long-press history, and the tab
    /// control keeps its count badge wherever the user puts it.
    @ViewBuilder
    private func toolbarButton(_ control: ToolbarControl) -> some View {
        if control == .tabs {
            tabsButton
        } else if control == .back {
            chromeButton(
                symbol: control.symbolName,
                isEnabled: toolbarControlEnabled(control),
                label: control.title
            ) {
                performToolbarControl(control)
            }
            .contextMenu { backHistoryMenu }
        } else {
            chromeButton(
                symbol: control.symbolName,
                isEnabled: toolbarControlEnabled(control),
                label: control.title
            ) {
                performToolbarControl(control)
            }
        }
    }

    private func toolbarControlEnabled(_ control: ToolbarControl) -> Bool {
        switch control {
        case .back:
            return canGoBack
        case .home:
            return activeTab != nil
        case .reader:
            return canActOnPage && env.settings.preferences.readerModeAvailable
        case .share, .novel, .find, .reload:
            return canActOnPage
        default:
            return true
        }
    }

    private func performToolbarControl(_ control: ToolbarControl) {
        switch control {
        case .back:
            goBack()
        case .home:
            openHomeTab()
        case .tabs:
            withAnimation(.snappy(duration: 0.3)) {
                showTabsOverview = true
            }
        case .menu:
            showMenu = true
        case .bookmarks:
            showBookmarks = true
        case .history:
            showHistory = true
        case .downloads:
            showDownloads = true
        case .reader:
            guard env.settings.preferences.readerModeAvailable else { return }
            activateReaderMode()
        case .novel:
            activateNovelMode()
        case .bookshelf:
            showBookshelf = true
        case .passwords:
            showPasswords = true
        case .share:
            showShareSheet = true
        case .reload:
            reloadActiveTab()
        case .find:
            if showFindBar {
                showFindBar = false
                findQuery = ""
                env.webCoordinator.clearFindInPage()
            } else {
                showFindBar = true
            }
        case .settings:
            showSettings = true
        case .adBlock:
            toggleAdBlock()
        case .privateMode:
            env.setPrivateBrowsingMode(!(env.settings.preferences.privateBrowsingMode ?? false))
        }
    }

    /// One glyph button inside the chrome.
    private func chromeButton(
        symbol: String,
        isEnabled: Bool,
        label: String? = nil,
        foreground: Color? = nil,
        action: @escaping () -> Void
    ) -> some View {
        let ink = foreground ?? barForeground
        return Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 16, weight: .semibold))
                .frame(width: 34, height: 34)
                .contentShape(Rectangle())
        }
        .buttonStyle(ChromeButtonStyle())
        .foregroundStyle(
            isEnabled ? ink : ink.opacity(0.35)
        )
        .disabled(!isEnabled)
        .accessibilityLabel(label ?? (symbol == "chevron.left" ? "后退" : "菜单"))
    }

    // MARK: - Chrome backdrop sampling

    /// Re-decides the ink the chrome draws in, from what sits behind the bar.
    ///
    /// Three possible backs: the home surface's own picture, the palette
    /// surface, or the live page. The first two are measured from what they
    /// are — the picture's bottom strip, the surface token in the current
    /// scheme. The page is measured from a small print of its own bottom
    /// strip, taken a beat after the load state settles so the sample reads
    /// this document and not the one before it.
    private func updateChromeForeground() {
        guard let tab = activeTab else { return }
        chromeSampleTask?.cancel()

        if tab.isHome {
            if let stamp = env.settings.preferences.homeBackgroundStamp {
                let scheme = colorScheme
                let surface = palette.surface
                chromeSampleTask = Task {
                    let image = await Task.detached(priority: .utility) {
                        HomeBackgroundStore.load(stamp: stamp)
                    }.value
                    guard !Task.isCancelled else { return }
                    if let image, let backdropIsLight = ChromeBackdrop.bottomStripIsLight(image) {
                        chromeForegroundIsLight = backdropIsLight
                    } else if let backdropIsLight = ChromeBackdrop.surfaceIsLight(surface, scheme: scheme) {
                        chromeForegroundIsLight = backdropIsLight
                    }
                }
            } else if let backdropIsLight = ChromeBackdrop.surfaceIsLight(palette.surface, scheme: colorScheme) {
                chromeForegroundIsLight = backdropIsLight
            }
            return
        }

        if isReaderActive,
           let backdropIsLight = ChromeBackdrop.surfaceIsLight(palette.surface, scheme: colorScheme) {
            // The reader redraws the article on the palette surface; there is
            // no page behind the bar to sample.
            chromeForegroundIsLight = backdropIsLight
            return
        }

        if tab.loadState.isFailure,
           let backdropIsLight = ChromeBackdrop.surfaceIsLight(palette.surface, scheme: colorScheme) {
            // The error surface is the shell's own, drawn on the palette
            // surface — there is no page to sample.
            chromeForegroundIsLight = backdropIsLight
            return
        }

        guard let webView = tabManager.webView(for: tab.id) else { return }
        let tabId = tab.id
        let scheme = colorScheme
        let surface = palette.surface
        chromeSampleTask = Task {
            try? await Task.sleep(nanoseconds: 450_000_000)
            guard !Task.isCancelled, tabManager.activeTabId == tabId else { return }

            if let image = await takeBottomStripSnapshot(webView: webView),
               let backdropIsLight = ChromeBackdrop.bottomStripIsLight(image) {
                chromeForegroundIsLight = backdropIsLight
                return
            }
            if let backdropIsLight = ChromeBackdrop.surfaceIsLight(surface, scheme: scheme) {
                chromeForegroundIsLight = backdropIsLight
            }
        }
    }

    /// A small print of the web view's bottom strip — the region the command
    /// bar covers. The web view runs edge to edge, so this is the backdrop the
    /// ink has to live on.
    private func takeBottomStripSnapshot(webView: WKWebView) async -> UIImage? {
        let stripHeight = min(140, webView.bounds.height)
        guard stripHeight > 0, webView.bounds.width > 0 else { return nil }
        let config = WKSnapshotConfiguration()
        config.rect = CGRect(
            x: 0,
            y: webView.bounds.height - stripHeight,
            width: webView.bounds.width,
            height: stripHeight
        )
        config.snapshotWidth = 32
        return await withCheckedContinuation { continuation in
            webView.takeSnapshot(with: config) { image, _ in
                continuation.resume(returning: image)
            }
        }
    }

    /// The pages behind the current one, newest first, for the back button's
    /// long-press menu — the way to skip several entries at once.
    @ViewBuilder
    private var backHistoryMenu: some View {
        if let tab = activeTab, let webView = tabManager.webView(for: tab.id) {
            let items = Array(webView.backForwardList.backList.suffix(6).reversed())
            if items.isEmpty {
                Text("没有更早的页面")
            } else {
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    Button {
                        _ = webView.go(to: item)
                    } label: {
                        Label(
                            item.title?.isEmpty == false
                                ? item.title!
                                : (item.url.host ?? item.url.absoluteString),
                            systemImage: "clock.arrow.circlepath"
                        )
                    }
                }
            }
        }
    }

    /// The tab count the bar button carries: the active mode's own strip.
    ///
    /// The regular and private strips are two collections, each with its own
    /// home, and the overview presents one of them at a time. A badge summing
    /// both would show a number the overview it opens cannot match — 普通 16
    /// beside 无痕 3 is never 19.
    private var tabCountForActiveMode: Int {
        let mode = activeTab?.privacyMode
            ?? ((env.settings.preferences.privateBrowsingMode ?? false) ? .private : .regular)
        return tabManager.displayedTabCount(privacyMode: mode)
    }

    /// The tab switcher button: a page outline carrying the count inside it —
    /// the number is what the user reads, so it is the drawing's subject, not
    /// a footnote under a glyph.
    private var tabsButton: some View {
        tabsButton(ink: barForeground)
    }

    private func tabsButton(ink: Color) -> some View {
        Button {
            withAnimation(.snappy(duration: 0.3)) {
                showTabsOverview = true
            }
        } label: {
            ZStack {
                RoundedRectangle(cornerRadius: 6.5, style: .continuous)
                    .strokeBorder(ink, lineWidth: 1.6)
                    .frame(width: 21, height: 21)

                Text("\(min(tabCountForActiveMode, 99))")
                    .font(.system(size: 11, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(ink)
                    .offset(y: 0.5)
            }
            .frame(width: 34, height: 34)
            .contentShape(Rectangle())
        }
        .buttonStyle(ChromeButtonStyle())
        .accessibilityLabel("标签页，\(tabCountForActiveMode) 个")
    }

    /// The find bar and the server-status notice, pinned under the chrome.
    ///
    /// They are tools for the page in view, so they do not take part in the
    /// scroll-hide: a find bar that vanished mid-search would be a bar the user
    /// has to chase.
    private var floatingTools: some View {
        VStack(spacing: 8) {
            // An HTTP error status is reported here, over the page the server
            // sent, rather than replacing it.
            if let tab = activeTab, tab.serverStatus >= 400, !tab.isHome {
                ServerStatusNotice(status: tab.serverStatus) {
                    tab.serverStatus = 0
                }
                .transition(.move(edge: .top).combined(with: .opacity))
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
                .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .padding(.horizontal, BrowserChrome.sideInset)
        // The shell ignores the keyboard at its root, so the bar it floats
        // above no longer rises — and the find bar lifts by the keyboard's own
        // measured height instead. The lift tracks the find bar rather than
        // the keyboard: a keyboard raised by the page's own fields moves
        // nothing the user is not reading, while one raised by the find field
        // carries the find bar with it.
        // The overlay holds these above the home-indicator inset already, so
        // they clear the bar by the bar's own height and gap, not by the
        // inset as well.
        .padding(
            .bottom,
            BrowserChrome.barHeight + BrowserChrome.barGap + 6
                + (showFindBar ? keyboardHeight : 0)
        )
        .animation(Self.chromeAnimation, value: showFindBar)
    }

    // MARK: - Screen-edge swipe back

    /// Whether the screen-edge swipe may act.
    ///
    /// Where the web view has history, WebKit's own interactive edge-swipe is
    /// the gesture — animated and cancellable — and this one stands down so
    /// the two never fight over the same finger. It earns its keep exactly
    /// where that gesture cannot act: a page whose history is empty (the
    /// swipe falls through to the tab that opened it, then the home surface),
    /// an error surface covering the web view, and the home surface with a
    /// page behind it.
    private var edgeSwipeBackEnabled: Bool {
        // The novel reader is its own layer with its own gestures; an edge
        // swipe there would pop reader mode or navigate the page underneath it.
        guard novelSession == nil else { return false }
        guard !omnibox.isEditing, !showFindBar else { return false }
        guard let tab = activeTab else { return false }
        if isReaderActive { return true }
        if tab.isHome { return !tab.url.isEmpty }
        if tab.loadState.isFailure { return true }
        guard tabManager.webView(for: tab.id) != nil else { return false }
        return !tab.canGoBack
    }

    private func handleEdgeSwipeBack() {
        guard novelSession == nil else { return }
        guard !omnibox.isEditing, !showFindBar else { return }
        if isReaderActive {
            isReaderActive = false
            readerArticle = nil
            return
        }
        guard activeTab != nil else { return }
        goBack()
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

    /// The tallest the suggestion card may grow.
    ///
    /// Measured from the card's bottom edge (just above the command bar) up to
    /// the keyboard: a card that ignored the keyboard would put its last rows
    /// where they can never be tapped, which is the "list cut off" failure this
    /// budget exists to prevent. The card still sizes to its content — this is
    /// only the ceiling.
    private var omniboxCardHeight: CGFloat {
        let screenHeight = safeRectHeight + safeTop + safeBottom
        let spaceAboveBar = screenHeight - keyboardHeight
            - safeBottom - BrowserChrome.barHeight - BrowserChrome.barGap - 6
        return min(max(200, spaceAboveBar), BrowserMetrics.omniboxCardMaxHeight)
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
    /// The restore is nearly unconditional on direction rather than
    /// proportional to distance: a user who scrolls up even slightly is looking
    /// for the controls, and making them scroll a threshold's worth first is
    /// the behaviour that makes a collapsing toolbar feel broken. The hide,
    /// conversely, waits for a deliberate distance of downward travel, so a
    /// page that jiggles under a refresh does not bounce the bar.
    private func handleScroll(offset: Double) {
        // An open omnibox or an active find pins the chrome: the user is
        // working in it, and sliding it away mid-sentence would be hostile.
        guard !omnibox.isEditing, !showFindBar else { return }

        let previous = scrollTracker.lastOffset
        scrollTracker.lastOffset = offset
        let delta = offset - previous

        // At the top of the document the bar is always back; there is nothing
        // above the page start to hide it for.
        if offset <= 2 {
            scrollTracker.accumulation = 0
            setChromeHidden(false)
            return
        }

        guard abs(delta) > 0.25 else { return }

        if delta > 0 {
            scrollTracker.accumulation = max(0, scrollTracker.accumulation + delta)
            if scrollTracker.accumulation > 48 {
                scrollTracker.accumulation = 0
                setChromeHidden(true)
            }
        } else {
            scrollTracker.accumulation = min(0, scrollTracker.accumulation + delta)
            if scrollTracker.accumulation < -8 {
                scrollTracker.accumulation = 0
                setChromeHidden(false)
            }
        }
    }

    private func setChromeHidden(_ hidden: Bool) {
        guard chromeHidden != hidden else { return }
        withAnimation(Self.chromeAnimation) {
            chromeHidden = hidden
        }
    }

    // MARK: - Actions

    private func goBack() {
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
        // behind the page, the fallback is the tab that opened this one — a
        // link opened into a new tab has an empty back list, and "back" from
        // it means where the user came from — and the home surface last of
        // all.
        if !env.webCoordinator.goBack() {
            let openerId = tab.openerTabId
            if !openerId.isEmpty,
               tabManager.tabs.contains(where: { $0.id == openerId }) {
                tabManager.activateTab(id: openerId)
                return
            }
            goHome(tab)
        }
    }

    /// Opens the start page as its own tab.
    ///
    /// The counterpart to dragging the bar upward and the menu's 主页 tile:
    /// going to the start page is a *destination*, not a mode the current tab
    /// is switched into. Overwriting the tab in place is what it used to do —
    /// the page the user was reading stayed alive underneath but the tab
    /// became a start page, its address bar empty and its identity swapped —
    /// and returning to browsing from there loaded the next page into that
    /// same tab. Now the reading tab keeps its place in the strip, and the
    /// start page opens beside it under the name 主页.
    private func openHomeTab() {
        guard activeTab?.isHome != true else { return }
        tabManager.createTab(openSource: .user)
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
        chromeHidden = false
        scrollTracker.lastOffset = 0
        scrollTracker.accumulation = 0
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

    /// Acts on a scanned QR payload. A web address opens in a new tab —
    /// routed through 无痕模式 like every other new page; anything else is
    /// copied, with the payload named in the notice so the copy is
    /// confirmed rather than assumed.
    private func handleScannedText(_ raw: String) {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }

        let looksLikeAddress: Bool = {
            if text.contains("://") {
                return URL(string: text)?.host?.isEmpty == false
            }
            // A bare domain: ASCII, dotted, no whitespace, and it parses
            // once the scheme is supplied.
            return !text.contains(" ")
                && text.contains(".")
                && text.allSatisfy(\.isASCII)
                && URL(string: "https://\(text)")?.host?.isEmpty == false
        }()

        showQRScanner = false
        if looksLikeAddress, let url = BrowserUrlResolver.storedUrl(text) {
            tabManager.openTab(url: url, openSource: .user)
        } else {
            UIPasteboard.general.string = text
            qrCopyNotice = text
        }
    }

    /// Whether the menu's page-bound actions have something to act on.
    private var canActOnPage: Bool {
        guard let tab = activeTab, !tab.isHome else { return false }
        return tabManager.webView(for: tab.id) != nil
    }

    /// What the menu panel's header names as its subject.
    private var menuPanelTitle: String {
        guard let tab = activeTab, !tab.isHome else { return "菜单" }
        if !tab.title.isEmpty { return tab.title }
        return tab.url.isEmpty ? "菜单" : tab.url
    }

    /// Runs one tile from the menu panel.
    private func handleMenuAction(_ action: VelaMenuAction) {
        showMenu = false
        guard let tab = activeTab else {
            switch action {
            case .bookmarks: showBookmarks = true
            case .history: showHistory = true
            case .downloads: showDownloads = true
            case .settings: showSettings = true
            case .bookshelf: showBookshelf = true
            case .passwords: showPasswords = true
            case .scanQRCode:
                showQRScanner = true
            case .privateTab:
                // No tab on screen does not make the switch a tab factory:
                // turning 无痕模式 on here materialises the private home it
                // routes to, which is exactly what an empty browser needs.
                env.setPrivateBrowsingMode(!(env.settings.preferences.privateBrowsingMode ?? false))
            case .leavePrivate: break
            default: break
            }
            return
        }

        switch action {
        case .addBookmark:
            showAddBookmarkChoice = true
        case .share:
            showShareSheet = true
        case .findInPage:
            showFindBar = true
        case .reader:
            // The general setting gates the entry: with reader mode switched
            // off, the menu item does nothing rather than opening a mode the
            // user asked the browser not to offer.
            guard env.settings.preferences.readerModeAvailable else { break }
            activateReaderMode()
        case .novel:
            activateNovelMode()
        case .bookshelf:
            showBookshelf = true
        case .passwords:
            showPasswords = true
        case .hideElements:
            guard tabManager.webView(for: tab.id) != nil else { return }
            env.webCoordinator.armElementPicker()
            // The picker script has to be in the page, and a configuration only
            // applies to the next navigation, so the page is reloaded.
            _ = tabManager.reload(tab: tab)
        case .desktopSite:
            toggleDesktopSite(for: tab)
        case .home:
            openHomeTab()
        case .bookmarks:
            showBookmarks = true
        case .history:
            showHistory = true
        case .downloads:
            showDownloads = true
        case .scanQRCode:
            showQRScanner = true
        case .privateTab:
            // The tile is 无痕模式's switch: on, everything new routes private
            // and the browser lands on the private home; off, routing returns
            // to regular and a private page yields the screen to the regular
            // home. The private tabs themselves stay either way — ending the
            // session is the 离开无痕模式 action, not this one.
            env.setPrivateBrowsingMode(!(env.settings.preferences.privateBrowsingMode ?? false))
        case .leavePrivate:
            Task { await env.endPrivateSession() }
        case .adBlock:
            toggleAdBlock()
        case .reload:
            reloadActiveTab()
        case .settings:
            showSettings = true
        }
    }

    /// Opens a user-defined URL shortcut from the menu panel.
    ///
    /// The shortcut's text is treated the way the omnibox treats a bare host:
    /// a missing scheme becomes https, and anything that is not http(s) is
    /// refused rather than handed to the system.
    private func handleMenuShortcut(_ shortcut: MenuShortcut) {
        showMenu = false
        let raw = shortcut.url.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { return }
        let candidate = raw.contains("://") ? raw : "https://" + raw
        guard let url = URL(string: candidate),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              url.host != nil else {
            return
        }
        navigate(to: url, in: submissionTab)
    }

    /// Runs one hardware-keyboard command from the app's menu bar.
    private func handleBrowserCommand(_ command: BrowserCommand) {
        switch command {
        case .newTab:
            tabManager.createTab(openSource: .user)
        case .closeTab:
            if let tab = activeTab {
                tabManager.closeTab(id: tab.id)
            }
        case .reopenClosedTab:
            let mode = activeTab?.privacyMode ?? .regular
            _ = tabManager.reopenLastClosedTab(privacyMode: mode)
        case .focusAddressBar:
            novelSession = nil
            omnibox.beginEditing()
        case .reload:
            reloadActiveTab()
        case .back:
            goBack()
        case .findInPage:
            if canActOnPage { showFindBar = true }
        case .togglePrivate:
            env.setPrivateBrowsingMode(!(env.settings.preferences.privateBrowsingMode ?? false))
        case .nextTab:
            tabManager.switchTab(by: 1)
        case .previousTab:
            tabManager.switchTab(by: -1)
        case .bookmarks:
            showBookmarks = true
        case .history:
            showHistory = true
        case .downloads:
            showDownloads = true
        case .settings:
            showSettings = true
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

    // MARK: - Novel mode

    /// Extracts the page as a novel chapter and opens it on the shelf.
    ///
    /// A page that does not yield a chapter is reported rather than silently
    /// ignored: the user pressed a button and is owed an answer. Extraction
    /// runs on the live web view, so the chapter it opens is the page that is
    /// actually on screen.
    private func activateNovelMode() {
        guard NovelModeService.isLikelyNovel(activeTab?.url ?? ""),
              let tab = activeTab, !tab.isHome,
              let webView = tabManager.webView(for: tab.id) else {
            novelNotice = "这个页面看起来不是小说章节。打开一本小说的正文页后再试。"
            return
        }

        Task { @MainActor in
            guard let extraction = await NovelModeService.extract(from: webView, url: tab.url) else {
                novelNotice = "没能从这一页提取出正文。它可能不是章节页，或正文由脚本动态加载。"
                return
            }
            guard let opened = env.novels.open(extraction) else {
                novelNotice = "这一章无法加入书架，请稍后再试。"
                return
            }
            openNovel(opened.book, chapter: opened.chapter)
        }
    }

    private func openNovel(_ book: NovelBook, chapter: NovelChapter?) {
        novelSession = NovelSession(book: book, chapter: chapter)
    }

    /// Opens a chapter in the active tab and leaves the reader. Used from the
    /// reader's own "在浏览器中打开" action, where the chapter is a page the
    /// user may need the original site to render.
    private func openInBrowser(_ url: URL) {
        if let tab = activeTab {
            navigate(to: url, in: tab)
        } else {
            let tab = tabManager.createTab(openSource: .user)
            navigate(to: url, in: tab)
        }
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

    /// The tab an omnibox submission lands in.
    ///
    /// An empty tab strip is a state the user can reach — closing everything
    /// leaves none — and a query typed into an address bar with no tabs must
    /// not evaporate. The submission opens the tab it needs.
    private var submissionTab: BrowserTabState {
        activeTab ?? tabManager.createTab(openSource: .user)
    }

    private func submitAddressBar(_ input: String) {
        let tab = submissionTab
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
        let tab = submissionTab
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
        chromeHidden = false
        scrollTracker.accumulation = 0
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
            navigate(to: url, in: submissionTab)

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
            navigate(to: url, in: submissionTab)

        default:
            guard let url = URL(string: suggestion.completion) else {
                omnibox.endEditing()
                return
            }
            omnibox.endEditing()
            navigate(to: url, in: submissionTab)
        }
    }
}

/// Mutable scroll bookkeeping for the shell. A reference box so per-frame
/// writes do not invalidate the view tree.
private final class ShellScrollTracker {
    var lastOffset: Double = 0
    var accumulation: CGFloat = 0
}

// MARK: - Novel session

/// What the shell's novel layer is showing.
///
/// The chapter is optional because a book opened from the shelf may have had
/// its cached chapter pruned; the reader then loads `book.currentChapterUrl`
/// itself. The identity is the session's, not the book's, so opening the same
/// book again after a position change still rebuilds the layer.
private struct NovelSession: Identifiable, Equatable {
    let id = UUID()
    var book: NovelBook
    var chapter: NovelChapter?
}
