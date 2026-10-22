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
    @Environment(AppEnvironment.self) var env
    @Environment(\.browserPalette) var palette
    @Environment(\.colorScheme) var colorScheme
    @Environment(\.scenePhase) var scenePhase
    @Environment(\.horizontalSizeClass) var horizontalSizeClass

    /// The omnibox session. Created here rather than inside the view body
    /// because it is long-lived: it survives every tab switch, and rebuilding it
    /// would throw away the user's collapsed-section choices on each one.
    @State var omnibox: OmniboxViewModel

    @State var showTabsOverview = false
    @State var showQRScanner = false
    @State var qrCopyNotice: String?
    @State var showBookmarks = false
    @State var showHistory = false
    @State var showDownloads = false
    @State var showSettings = false
    /// Whether the menu's 广告过滤 tile has its settings open over the panel.
    @State var showAdBlockSettings = false
    @State var showPasswords = false
    @State var showBookshelf = false
    /// The service the presented shelf belongs to. Captured when the sheet
    /// opens, so a tab switch behind it cannot swap the shelf's database.
    @State var bookshelfLibrary: NovelLibraryService?
    @State var bookshelfIsPrivate = false
    @State var bookshelfGeneration = 0
    /// The tab the shelf was opened from. A private shelf's reader uses it as
    /// the source for "open in browser"; it is never inferred from the active
    /// tab later.
    @State var bookshelfSourceTabId = ""
    @State var showMenu = false
    /// Whether the iPad layout's sidebar drawer is open.
    @State var showPadSidebar = false
    @State var showAddBookmarkChoice = false
    @State var showShareSheet = false
    @State var showFindBar = false
    /// Whether the user closed the translation bar for the page on screen.
    /// Reset on every tab switch and navigation.
    @State var translationBarDismissed = false
    /// The shelf of saved offline pages.
    @State var showOfflinePages = false
    /// A one-line result from saving a page: "已保存" or the reason it failed.
    @State var offlineNotice: String?
    @State var findQuery = ""
    /// The debounce behind the find field. Typing is what runs the search.
    @State var findDebounceTask: Task<Void, Never>?

    @State var isReaderActive = false
    @State var readerArticle: ReaderArticle?

    /// The novel reader's layer, when one is open.
    ///
    /// It is a value rather than two optionals so opening a different book or
    /// chapter is one assignment; the reader itself owns the loading that
    /// follows.
    @State var novelSession: NovelSession?
    /// Why 小说模式 could not open the page.
    @State var novelNotice: String?

    /// Set when an omnibox submission was refused, so the shell can say why
    /// instead of closing the field as if nothing had happened.
    @State var addressNotice: String?
    /// The input that was refused, kept so the alert can offer to search for it.
    @State var rejectedInput = ""

    /// Whether the command bar has slid out of the way under the status bar.
    @State var chromeHidden = false
    /// How far the user has dragged the bar downward, mid-gesture.
    ///
    /// The bar follows the finger while the drag is in progress and either
    /// commits to hiding or springs back when the finger lifts. Never read in
    /// `body` except through the two modifiers below, so the per-frame writes
    /// cost nothing beyond the offset itself.
    @State var chromeDragOffset: CGFloat = 0
    /// How far the user has dragged the bar upward, mid-gesture — the gesture
    /// that returns to the home surface. The bar lifts a little with the
    /// finger as the promise of what releasing will do.
    @State var chromeLiftOffset: CGFloat = 0

    /// Whether the drag-to-hide gesture may act.
    ///
    /// The one state that refuses it is the open omnibox session, where a
    /// downward drag means dismissing the keyboard. Every surface — the home
    /// one included — hides the bar the same way: the bar is the page's
    /// controls, and a page the user is pushing out of the way takes its
    /// controls with it.
    var canDragChromeAway: Bool {
        guard !omnibox.isEditing else { return false }
        return activeTab != nil
    }
    /// Per-frame scroll bookkeeping, kept out of `@State`.
    ///
    /// Writing `@State` on every scroll message invalidates the shell's body
    /// each frame — exactly the layout work that shows up as dropped frames
    /// while a page scrolls. The box changes without touching SwiftUI; only
    /// the `chromeHidden` threshold transition re-renders.
    @State var scrollTracker = ShellScrollTracker()

    /// The keyboard's height while visible, from the frame-change notifications.
    ///
    /// The suggestion card's height budget is measured down to the keyboard's
    /// top edge — a card that ignores the keyboard is a card whose last rows
    /// can never be reached.
    @State var keyboardHeight: CGFloat = 0
    /// The safe-area insets and the height of the safe-area rectangle, measured
    /// once the view is in the hierarchy and again on rotation.
    @State var safeTop: CGFloat = 0
    @State var safeBottom: CGFloat = 0
    @State var safeRectHeight: CGFloat = 0

    /// Whether the surface the chrome floats over reads light — a bright
    /// wallpaper, a pale page — and the bar should therefore draw black ink.
    /// Decided by `updateChromeForeground` from the strip behind the bar; the
    /// initial value matches the shipped palette's dark chrome until the first
    /// measurement lands.
    @State var chromeForegroundIsLight = false
    /// The ink for the iPad top bar, sampled from the top of a home picture.
    /// `nil` means the bar is over the ambient field or a page and the
    /// appearance decides.
    @State var topChromeForegroundIsLight: Bool?
    @State var chromeSampleTask: Task<Void, Never>?

    /// The one animation the chrome uses.
    ///
    /// A spring rather than an ease: the bar leaves and returns along a path
    /// the user's own scroll is also moving, and an ease-out over a fixed
    /// duration reads as a separate, laggier movement next to the page.
    static let chromeAnimation = Animation.spring(response: 0.32, dampingFraction: 0.86)

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

    var tabManager: TabManager { env.tabManager }

    /// The shared navigation decisions; one value so the toolbar, menu and
    /// hardware commands cannot drift apart.
    var navigationActions: BrowserNavigationActions {
        BrowserNavigationActions(
            tabManager: env.tabManager,
            webCoordinator: env.webCoordinator
        )
    }

    var activeTab: BrowserTabState? { tabManager.activeTab }

    static let padSidebarWidth: CGFloat = 286
    /// The top bar's laid-out height: 46 for the glass row plus its 8/6 gaps.
    static var padTopBarHeight: CGFloat { 8 + BrowserChrome.barHeight + 6 }

    /// Whether the shell draws the iPad layout.
    ///
    /// 自动 follows the device and the window: an iPad in a regular-width
    /// window gets the two-column chrome, a phone or a narrow iPad Split View
    /// window keeps the single column.
    var usesPadLayout: Bool {
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
    var bottomChromeClearance: CGFloat {
        // The iPad layout puts the navigation in a top bar, so the page can run
        // to the bottom edge of its column.
        usesPadLayout
            ? 0
            : safeBottom + BrowserChrome.barHeight + BrowserChrome.barGap
    }

    /// Whether the shell's own ambient field is worth drawing.
    ///
    /// A live page is opaque and covers it completely; keeping a full-screen
    /// mesh, material and specular layers under that page only costs
    /// compositing. The field appears on the surfaces that show something of
    /// the app itself — home, reader, error, empty — and in sheets, which draw
    /// their own.
    var showsAmbientRootBackground: Bool {
        if novelSession != nil { return false }
        if showsBackgroundPictureAtRoot { return false }
        guard let tab = activeTab else { return true }
        if tab.isHome || isReaderActive || tab.loadState.isFailure { return true }
        return tabManager.webView(for: tab.id) == nil
    }

    /// Whether the user's background picture is the shell's backdrop.
    ///
    /// The picture is the global background, not a layer inside the home:
    /// it belongs behind the top bar as well as the home, so the chrome and
    /// the home sit on the same picture. A page covers it completely, which
    /// is why there is no per-tab condition here.
    var showsBackgroundPictureAtRoot: Bool {
        env.settings.preferences.backgroundImageStamp != nil
    }

    var shellBase: some View {
        ZStack {
            if showsBackgroundPictureAtRoot, let stamp = env.settings.preferences.backgroundImageStamp {
                BackgroundPictureBackdrop(stamp: stamp)
            } else if showsAmbientRootBackground {
                AmbientBackgroundView()
            } else {
                palette.surface.ignoresSafeArea()
            }

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
        // The Translation framework hands sessions to a SwiftUI modifier, so
        // its host must live in the hierarchy even though it draws nothing.
        .overlay { appleTranslationHost }
    }

    /// The invisible host that gives the on-device translator a session.
    @ViewBuilder
    var appleTranslationHost: some View {
        if #available(iOS 18.0, *),
           let bridge = env.appleTranslationBridge as? AppleTranslationBridge {
            AppleTranslationHost(bridge: bridge)
        }
    }

    /// The full-screen layers that sit over the page: the phone command bar,
    /// the floating tools, the tab overview, the scanner and the novel reader.
    /// Kept apart from the base hierarchy so each expression the type checker
    /// sees stays moderate.
    var shellOverlays: some View {
        shellBase
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
        .overlay { novelReaderLayer }
        .animation(.snappy(duration: 0.24), value: novelSession?.id)
    }

    /// The shell's own alerts, split from the layers they cover.
    var shellNotices: some View {
        shellOverlays
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
    }

    /// The effects and observers that keep the chrome in step with the page.
    ///
    /// The chain is split every few modifiers on purpose: a single expression
    /// carrying the whole hierarchy, the layers, the notices and every observer
    /// outgrew the type checker's budget, and the failure surfaced at whichever
    /// modifier happened to be last. Each group below is a moderate expression.
    var shellInteractions: some View {
        shellNotices
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
            env.commands.register(owner: env.windowId) { command in
                handleBrowserCommand(command)
            }
            // The environment ends a private session from the app's background
            // hook as well as from this view. Taking the reader down here,
            // synchronously before the tabs close, is what makes the reader's
            // loader cancellation part of the shutdown order.
            env.onPrivateSessionWillEnd = {
                if novelSession?.isPrivateSession == true {
                    closeNovelSession()
                }
                if bookshelfIsPrivate {
                    showBookshelf = false
                    bookshelfLibrary = nil
                    bookshelfIsPrivate = false
                }
            }
        }
        .onDisappear {
            env.commands.unregister(owner: env.windowId)
            env.onPrivateSessionWillEnd = nil
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.keyboardWillChangeFrameNotification)) { note in
            handleKeyboardFrameChange(note)
        }
    }

    /// The observers that follow the active document, plus the translation
    /// offer that runs when a page settles.
    var shellTabObservers: some View {
        shellInteractions
        .onChange(of: tabManager.activeTabId) { _, _ in
            handleActiveTabChanged()
        }
        .onChange(of: env.privateNovelSessionGeneration) { _, generation in
            handlePrivateNovelGeneration(generation)
        }
        .onChange(of: activeTab?.url) { _, _ in
            handleActiveTabUrlChanged()
        }
        .onChange(of: activeTab?.pendingUrl) { _, _ in
            syncAddressText()
        }
        .onChange(of: activeTab?.loadState) { _, state in
            if let state {
                handleActiveTabLoadStateChanged(state)
            }
        }
        // Runs once the active page has finished loading (and again on a tab
        // or URL change): this is what recognises a foreign-language page and
        // offers to translate it, the way Chrome's translate bubble does.
        .task(id: translationDetectionKey) {
            await detectTranslationIfNeeded()
        }
    }

    /// The observers that follow appearance and scene state rather than the
    /// document.
    var shellAppearanceObservers: some View {
        shellTabObservers
        .onChange(of: env.settings.preferences.backgroundImageStamp) { _, _ in
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
                env.noteInteraction("地址栏")
                showPadSidebar = false
            }
        }
        .onChange(of: scenePhase) { _, phase in
            handleScenePhaseChanged(phase)
        }
    }

    var shellRoot: some View { shellAppearanceObservers.overlay { searchPageLayer } }

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
    // MARK: - Safe area

    /// Reads the safe-area geometry once the view is in a window.
    ///
    /// A `GeometryReader` in the background sees the safe-area rectangle the
    /// ZStack is laid out in, so the numbers here are the real insets on this
    /// device, re-read on rotation — which is what the keyboard-aware card
    /// budget and the full-bleed insets need.
    var safeAreaReader: some View {
        GeometryReader { geo in
            Color.clear
                .onAppear { recordSafeArea(geo) }
                .onChange(of: geo.size) { _, _ in recordSafeArea(geo) }
                .onChange(of: geo.safeAreaInsets) { _, _ in recordSafeArea(geo) }
        }
    }

    func recordSafeArea(_ geo: GeometryProxy) {
        safeTop = geo.safeAreaInsets.top
        safeBottom = geo.safeAreaInsets.bottom
        safeRectHeight = geo.size.height
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
    var edgeSwipeBackEnabled: Bool {
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

    func handleEdgeSwipeBack() {
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
    var canGoBack: Bool {
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
    var omniboxCardHeight: CGFloat {
        let screenHeight = safeRectHeight + safeTop + safeBottom
        let spaceAboveBar = screenHeight - keyboardHeight
            - safeBottom - BrowserChrome.barHeight - BrowserChrome.barGap - 6
        return min(max(200, spaceAboveBar), BrowserMetrics.omniboxCardMaxHeight)
    }

    var omniboxPlaceholder: String {
        let engine = env.settings.preferences.searchEngine.activeEngine.name
        return "用 \(engine) 搜索或输入网址"
    }

    var displayUrl: String {
        guard let tab = activeTab else { return "" }
        if tab.isHome { return "" }
        // A redirect updates `pendingUrl` before the new document commits.
        // Showing only `url` left the field on the address the user typed
        // while the browser was already somewhere else (R-23).
        return tab.pendingUrl.isEmpty ? tab.url : tab.pendingUrl
    }

    /// Pushes the active tab's address into the omnibox.
    ///
    /// The field shows the page's URL while the omnibox is closed — which the
    /// pre-refactor bar did not, leaving the placeholder on screen instead of
    /// the address of the page being read.
    func syncAddressText() {
        omnibox.currentPageUrl = displayUrl
        guard !omnibox.isEditing else { return }
        if omnibox.text != displayUrl {
            omnibox.text = displayUrl
        }
    }

    // MARK: - Omnibox wiring

    func wireOmnibox() {
        omnibox.onSelectSuggestion = { suggestion in
            commitSuggestion(suggestion)
        }
        omnibox.onCommitText = { input in
            submitAddressBar(input)
        }
    }

    /// The novel reader layer.
    ///
    /// Kept out of the root modifier chain: that chain is already at the type
    /// checker's budget, and the reader's closures are large.
    @ViewBuilder
    var novelReaderLayer: some View {
        if let session = novelSession {
            NovelReaderView(
                book: session.book,
                initialChapter: session.chapter,
                runtime: session.runtime,
                isPrivateSession: session.isPrivateSession,
                sessionGeneration: session.sessionGeneration,
                onClose: {
                    if session.isCurrent(in: novelSession) {
                        closeNovelSession()
                    }
                },
                onOpenInBrowser: { url in
                    guard session.isCurrent(in: novelSession) else { return }
                    closeNovelSession()
                    openInBrowser(url, for: session)
                }
            )
            .transition(.opacity)
            .zIndex(40)
        }
    }

    /// Closes a reader or shelf left behind by an earlier private generation.
    ///
    /// A regular reader always answers false, so a private session's begin/end
    /// never dismisses it.
    private func handlePrivateNovelGeneration(_ generation: Int) {
        if bookshelfIsPrivate, bookshelfGeneration != generation {
            showBookshelf = false
            bookshelfLibrary = nil
            bookshelfIsPrivate = false
        }
        guard let session = novelSession, session.shouldClose(for: generation) else { return }
        session.runtime.cancel()
        novelSession = nil
    }

    // MARK: - Shell observers

    /// The keyboard's rise and fall. The card tracks it; the chrome ignores it.
    private func handleKeyboardFrameChange(_ note: Notification) {
        let end = (note.userInfo?[UIApplication.keyboardFrameEndUserInfoKey] as? NSValue)?
            .cgRectValue ?? .zero
        let screenHeight = max(UIScreen.main.bounds.height, end.maxY)
        // Only a docked keyboard should resize the page. A floating iPad
        // keyboard is draggable: it sends a frame notification on every drag
        // frame, and treating each one as a new bottom inset made the search
        // page follow the keyboard and stutter. A floating panel covers only
        // itself; the page stays put underneath it.
        let occlusion: CGFloat
        if end.isEmpty {
            occlusion = 0
        } else if screenHeight - end.maxY < 40 {
            // Docked: the keyboard runs from its top edge to the bottom.
            occlusion = max(0, screenHeight - end.minY)
        } else {
            occlusion = 0
        }
        guard abs(occlusion - keyboardHeight) > 0.5 else { return }
        // No implicit animation here: this notification can arrive many times
        // while the keyboard is dragged, and animating every frame compounds
        // into the stall the report describes.
        keyboardHeight = occlusion
    }

    /// The shell state that belongs to the tab on screen, not to the window.
    private func handleActiveTabChanged() {
        isReaderActive = false
        readerArticle = nil
        translationBarDismissed = false
        syncTranslationState()
        showFindBar = false
        findQuery = ""
        chromeHidden = false
        scrollTracker.accumulation = 0
        env.webCoordinator.clearFindInPage()
        omnibox.endEditing()
        env.webCoordinator.refreshNavigationAvailability()
        syncAddressText()
    }

    private func handleActiveTabUrlChanged() {
        translationBarDismissed = false
        syncTranslationState()
        chromeHidden = false
        scrollTracker.accumulation = 0
        syncAddressText()
        updateChromeForeground()
    }

    private func handleActiveTabLoadStateChanged(_ state: TabLoadState) {
        if let tab = activeTab,
           state == .requested || state == .provisional {
            env.translation.pageWillNavigate(tabId: tab.id)
        }
        updateChromeForeground()
    }

    /// The translation offer for the page that just settled. A method rather
    /// than a closure in the root chain, for the type checker's benefit.
    @MainActor
    private func detectTranslationIfNeeded() async {
        guard !translationDetectionKey.isEmpty else { return }
        translationBarDismissed = false
        syncTranslationState()
        await offerTranslationIfNeeded()
    }

    /// Yields the iPad sidebar's page and dismisses the overview before a
    /// background transition ends the private session whose tabs it shows.
    @MainActor
    private func handleScenePhaseChanged(_ phase: ScenePhase) {
        guard phase == .background, showTabsOverview else { return }
        if !tabManager.privateTabs.isEmpty || tabManager.activeTab == nil {
            showTabsOverview = false
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
    func handleScroll(offset: Double) {
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

    func setChromeHidden(_ hidden: Bool) {
        guard chromeHidden != hidden else { return }
        withAnimation(Self.chromeAnimation) {
            chromeHidden = hidden
        }
    }

    // MARK: - Actions

    func goBack() {
        guard let tab = activeTab else { return }
        switch navigationActions.backStep(for: tab) {
        case .none, .webView:
            return
        case let .opener(openerId):
            tabManager.activateTab(id: openerId)
        case .returnToPage:
            // Coming back out of the home surface, which is not a page.
            returnToPage(tab)
        case .home:
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
    func openHomeTab() {
        _ = navigationActions.openHomeTab(from: activeTab)
    }

    /// Takes the reader (and its loaders) down before dropping the session.
    /// The runtime cancel is synchronous, so the database can be released even
    /// if SwiftUI has not removed the view yet.
    func closeNovelSession() {
        novelSession?.runtime.cancel()
        novelSession = nil
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
    func goHome(_ tab: BrowserTabState) {
        tabManager.webView(for: tab.id)?.stopLoading()
        isReaderActive = false
        readerArticle = nil
        showFindBar = false
        findQuery = ""
        env.webCoordinator.clearFindInPage()
        tabManager.showHome(tab)
        chromeHidden = false
        scrollTracker.lastOffset = 0
        scrollTracker.accumulation = 0
        syncAddressText()
    }

    /// Shows the page a tab is already holding, without navigating.
    ///
    /// The counterpart to `goHome`. The URL is taken from the web view when it
    /// has one, because an in-page history change updates the web view before
    /// anything else knows about it, and the tab's copy would otherwise restore
    /// the address of an earlier document.
    func returnToPage(_ tab: BrowserTabState) {
        let current = tabManager.webView(for: tab.id)?.url?.absoluteString
        guard tabManager.showPage(tab, currentURL: current) else { return }
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
    func handleScannedText(_ raw: String) {
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

    /// The live web view of the active tab, when it has one.
    var activeWebView: WKWebView? {
        guard let tab = activeTab else { return nil }
        return tabManager.webView(for: tab.id)
    }

    /// Saves the picked selector for this host and reloads so the cosmetic
    /// style that hides it is attached to a new document.
    func applyElementHide(_ pick: ElementPickResult) {
        env.settings.addManualElementHide(selector: pick.selector, host: pick.host)
        env.overlays.elementPick = nil
        if let tab = activeTab, !tab.isHome {
            _ = tabManager.reload(tab: tab)
        }
    }

    /// Whether the menu's page-bound actions have something to act on.
    var canActOnPage: Bool {
        guard let tab = activeTab, !tab.isHome else { return false }
        return tabManager.webView(for: tab.id) != nil
    }

    /// Commands the active page's scripts registered, for the menu panel.
    var activeUserScriptCommands: [UserScriptMenuCommand] {
        guard let tab = activeTab else { return [] }
        return env.overlays.userScriptMenuCommands.filter { $0.tabId == tab.id }
    }

    /// What the menu panel's header names as its subject.
    var menuPanelTitle: String {
        guard let tab = activeTab, !tab.isHome else { return "菜单" }
        if !tab.title.isEmpty { return tab.title }
        return tab.url.isEmpty ? "菜单" : tab.url
    }

    /// Runs one tile from the menu panel.
    func handleMenuAction(_ action: VelaMenuAction) {
        env.noteInteraction("菜单:\(action.rawValue)")
        // 广告过滤 opens its settings instead of toggling in place. The panel
        // is not where rule sources or custom rules can be managed, and a
        // toggle that dismissed the panel and changed nothing on screen is
        // exactly what read as a button that did nothing.
        if action == .adBlock {
            showAdBlockSettings = true
            return
        }
        showMenu = false
        guard let tab = activeTab else {
            switch action {
            case .bookmarks: showBookmarks = true
            case .history: showHistory = true
            case .downloads: showDownloads = true
            case .offlinePages: showOfflinePages = true
            case .settings: showSettings = true
            case .bookshelf: openBookshelf()
            case .passwords: showPasswords = true
            case .scanQRCode:
                showQRScanner = true
            case .privateTab:
                // No tab on screen does not make the switch a tab factory:
                // turning 无痕模式 on here materialises the private home it
                // routes to, which is exactly what an empty browser needs.
                env.togglePrivateBrowsingMode()
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
        case .translate:
            guard let webView = activeWebView else { break }
            // The menu item is the manual switch Chrome puts beside its
            // bubble: it translates, translates back when the bar is on
            // screen, and reopens the bar when a translated page's bar was
            // closed — so closing the bar never becomes a dead end.
            if env.translation.isTranslated && !translationBarDismissed {
                Task { await env.translation.restoreOriginal(webView: webView) }
            } else {
                translationBarDismissed = false
                if !env.translation.isTranslated {
                    startPageTranslation()
                }
            }
        case .saveOfflinePage:
            saveOfflinePage()
        case .offlinePages:
            showOfflinePages = true
        case .novel:
            activateNovelMode()
        case .bookshelf:
            openBookshelf()
        case .passwords:
            showPasswords = true
        case .hideElements:
            guard let webView = tabManager.webView(for: tab.id) else { return }
            // The script goes into the current document; no reload, so the
            // page and its scroll position stay put.
            env.webCoordinator.armElementPicker(in: webView)
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
            env.togglePrivateBrowsingMode()
        case .leavePrivate:
            let expectedGeneration = env.privateNovelSessionGeneration
            // Close the private reader (and shelf) before the session's data
            // is torn down. The generation guard also stops a late callback
            // from writing after the environment invalidates the session.
            if novelSession?.isPrivateSession == true {
                closeNovelSession()
            }
            if bookshelfIsPrivate {
                showBookshelf = false
                bookshelfLibrary = nil
                bookshelfIsPrivate = false
            }
            Task { await env.endPrivateSession(expectedGeneration: expectedGeneration) }
        case .adBlock:
            // Handled above, before the panel is dismissed.
            break
        case .reload:
            reloadActiveTab()
        case .settings:
            showSettings = true
        }
    }

    /// Searches the page as the find field is typed.
    ///
    /// A short pause keeps one document walk off every keystroke; an empty
    /// query clears the highlights instead. `reset` starts a changed query at
    /// its first match rather than carrying the previous query's position.
    func scheduleFind(for query: String) {
        findDebounceTask?.cancel()
        findDebounceTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 180_000_000)
            guard !Task.isCancelled else { return }
            if query.isEmpty {
                env.webCoordinator.clearFindInPage()
            } else {
                env.webCoordinator.findInPage(query, forward: true, reset: true)
            }
        }
    }

    /// Opens a user-defined URL shortcut from the menu panel.
    ///
    /// The shortcut's text is treated the way the omnibox treats a bare host:
    /// a missing scheme becomes https, and anything that is not http(s) is
    /// refused rather than handed to the system.
    func handleMenuShortcut(_ shortcut: MenuShortcut) {
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
    func handleBrowserCommand(_ command: BrowserCommand) {
        env.noteInteraction("快捷键:\(command.rawValue)")
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
            closeNovelSession()
            omnibox.beginEditing()
        case .reload:
            reloadActiveTab()
        case .back:
            goBack()
        case .findInPage:
            if canActOnPage { showFindBar = true }
        case .togglePrivate:
            env.togglePrivateBrowsingMode()
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

    func toggleDesktopSite(for tab: BrowserTabState) {
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

    func toggleAdBlock() {
        let enabled = env.settings.adBlockSettings.preferences.enabled
        env.settings.setAdBlockEnabled(!enabled)
        let identity = activeTab.map { TabDocumentIdentity(tab: $0) }
        Task { @MainActor in
            await env.refreshAdBlockRules()
            // Content rules only apply to a new document, so the page is
            // reloaded to make the change visible. Reload only the document
            // the toggle was made on; a tab switch during the compile means
            // the rules will apply on that tab's next load instead.
            guard let identity,
                  let tab = tabManager.tab(id: identity.tabId),
                  identity.matches(activeTab) else { return }
            _ = tabManager.reload(tab: tab)
        }
    }

    func activateReaderMode() {
        guard let tab = activeTab, !tab.isHome,
              let webView = tabManager.webView(for: tab.id) else { return }
        let identity = TabDocumentIdentity(tab: tab)
        Task {
            let article = await ReaderModeService.extract(from: webView, url: tab.url)
            // The extraction is asynchronous; a tab switch or a navigation
            // while it runs means the article belongs to a document the user
            // has left.
            guard identity.matches(activeTab) else { return }
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
                    contentHtml: "<p>这个页面看起来不是一篇文章，无法用文章阅读打开。如果是小说章节，请使用「小说模式」。</p>",
                    url: tab.url
                )
                isReaderActive = true
            }
        }
    }

    func reloadActiveTab() {
        _ = navigationActions.reload(activeTab)
    }

    // MARK: - Novel mode

    /// Extracts the page as a novel chapter and opens it on the shelf.
    ///
    /// A page that does not yield a chapter is reported rather than silently
    /// ignored: the user pressed a button and is owed an answer. Extraction
    /// runs on the live web view, so the chapter it opens is the page that is
    /// actually on screen.
    func activateNovelMode() {
        guard NovelModeService.isLikelyNovel(activeTab?.url ?? ""),
              let tab = activeTab, !tab.isHome,
              let webView = tabManager.webView(for: tab.id) else {
            novelNotice = "这个页面看起来不是小说章节。打开一本小说的正文页后再试。"
            return
        }

        // Bind the shelf to the tab's session before extraction starts: the
        // private service belongs to this private session, and the reader
        // must keep using it even if the environment later drops its reference.
        let isPrivate = tab.privacyMode == .private
        let generation = env.privateNovelSessionGeneration
        let identity = TabDocumentIdentity(tab: tab)

        Task { @MainActor in
            guard let library = await env.novelLibrary(privateMode: isPrivate) else {
                novelNotice = "私密模式下无法创建独立的小说存储。"
                return
            }
            guard !isPrivate || generation == env.privateNovelSessionGeneration else { return }
            var extraction = await NovelModeService.extract(from: webView, url: tab.url)
            if extraction == nil {
                // A hash-routed chapter may still be painting after the user
                // opens the menu; one delayed retry catches that.
                try? await Task.sleep(nanoseconds: 700_000_000)
                extraction = await NovelModeService.extract(from: webView, url: tab.url)
            }
            guard let extraction else {
                novelNotice = "没能从这一页提取出正文。它可能不是章节页，或正文由脚本动态加载。"
                return
            }
            // The extraction may finish after the tab has navigated or the
            // user switched tabs; the result then belongs to another document.
            guard identity.matches(activeTab) else { return }
            // A private session that ended during extraction must not open a
            // reader into the next session's shelf.
            guard !isPrivate || generation == env.privateNovelSessionGeneration else { return }
            guard let opened = library.open(extraction) else {
                novelNotice = "这一章无法加入书架，请稍后再试。"
                return
            }
            openNovel(
                opened.book,
                chapter: opened.chapter,
                sourceTabId: tab.id,
                library: library,
                isPrivateSession: isPrivate,
                sessionGeneration: generation
            )
        }
    }

    func openNovel(
        _ book: NovelBook,
        chapter: NovelChapter?,
        sourceTabId: String,
        library: NovelLibraryService,
        isPrivateSession: Bool,
        sessionGeneration: Int
    ) {
        // A late open from an ended private session must not resurrect a
        // reader into the session that replaced it.
        guard !isPrivateSession || sessionGeneration == env.privateNovelSessionGeneration else { return }
        novelSession = NovelSession(
            book: book,
            chapter: chapter,
            sourceTabId: sourceTabId,
            isPrivateSession: isPrivateSession,
            sessionGeneration: sessionGeneration,
            library: library
        )
    }

    /// Opens the shelf for the active tab's session.
    ///
    /// The library is captured now so a tab switch behind the sheet cannot
    /// swap the database under it, and a private shelf never falls back to the
    /// regular one when its in-memory database cannot be created.
    func openBookshelf() {
        let isPrivate = activeTab?.privacyMode == .private
        let generation = env.privateNovelSessionGeneration
        let sourceTabId = activeTab?.id ?? ""
        Task { @MainActor in
            guard let library = await env.novelLibrary(privateMode: isPrivate) else {
                novelNotice = "私密模式下无法创建独立的小说存储。"
                return
            }
            guard !isPrivate || generation == env.privateNovelSessionGeneration else { return }
            bookshelfIsPrivate = isPrivate
            bookshelfGeneration = generation
            bookshelfSourceTabId = sourceTabId
            bookshelfLibrary = library
            showBookshelf = true
        }
    }

    /// Opens a chapter in the browser on behalf of a novel session.
    ///
    /// The target is decided from the session, not from whatever tab happens
    /// to be active: a private reader may only use its own live private source
    /// tab or a new private tab. A stale private session is refused. The
    /// regular path keeps the previous behaviour exactly.
    func openInBrowser(_ url: URL, for session: NovelSession) {
        let target = NovelBrowserRouting.target(
            isPrivateSession: session.isPrivateSession,
            sessionGeneration: session.sessionGeneration,
            currentGeneration: env.privateNovelSessionGeneration,
            sourceTabId: session.sourceTabId,
            tabs: tabManager.tabs.map { (id: $0.id, privacyMode: $0.privacyMode) },
            activeTabId: activeTab?.id
        )
        switch target {
        case .refuse:
            return
        case let .existingTab(id):
            guard let tab = tabManager.tab(id: id) else { return }
            // Issue the request before activation: activating a cold tab would
            // otherwise fetch its old URL first, only for this load to replace it.
            navigate(to: url, in: tab)
            tabManager.activateTab(id: tab.id)
        case .newPrivateTab:
            tabManager.openTab(url: url, privacyMode: .private, openSource: .user)
        case let .activeTab(id):
            guard let tab = tabManager.tab(id: id) else { return }
            navigate(to: url, in: tab)
        case .newRegularTab:
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
    func retry(_ tab: BrowserTabState) {
        _ = tabManager.reload(tab: tab)
    }

    // MARK: - Navigation

    /// The tab an omnibox submission lands in.
    ///
    /// An empty tab strip is a state the user can reach — closing everything
    /// leaves none — and a query typed into an address bar with no tabs must
    /// not evaporate. The submission opens the tab it needs.
    var submissionTab: BrowserTabState {
        activeTab ?? tabManager.createTab(openSource: .user)
    }

        /// Writes a search query into the suggestion history unless the user has
    /// asked the browser not to keep history at all.
    func recordSearchQuery(
        _ query: String,
        engineId: SearchEngineId,
        boundary: BrowserDataBoundary
    ) {
        guard !(env.settings.preferences.historyNotRetained ?? false) else { return }
        try? env.searchHistory.record(
            query: query,
            searchEngineId: engineId,
            boundary: boundary
        )
    }

    func submitAddressBar(_ input: String) {
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
            recordSearchQuery(input, engineId: engine.id, boundary: tab.dataBoundary)
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

    static func message(for reason: AddressBarRejection, input: String) -> String {
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
    func searchRefusedInput(_ input: String) {
        let tab = submissionTab
        let engine = env.settings.preferences.searchEngine.activeEngine
        guard let url = engine.searchUrl(for: input) else { return }
        recordSearchQuery(input, engineId: engine.id, boundary: tab.dataBoundary)
        navigate(to: url, in: tab)
    }

    func navigate(to url: URL, in tab: BrowserTabState) {
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

    func commitSuggestion(_ suggestion: OmniboxSuggestion) {
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
            recordSearchQuery(
                suggestion.title,
                engineId: engine.id,
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
            recordSearchQuery(
                suggestion.completion,
                engineId: engine.id,
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
final class ShellScrollTracker {
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
struct NovelSession: Identifiable, Equatable {
    let id = UUID()
    var book: NovelBook
    var chapter: NovelChapter?
    /// The tab the reader was opened from. A private reader's "open in
    /// browser" uses it as the only allowed existing target.
    let sourceTabId: String
    /// Whether this reader was opened from a private tab. The shelf and the
    /// chapter/TOC loaders are chosen from this at presentation time.
    let isPrivateSession: Bool
    /// The environment's private-session generation when the reader opened.
    /// A later end bumps the environment; this reader is then stale.
    let sessionGeneration: Int
    /// The shelf this session owns. It stays here so a reader opened from this
    /// session keeps using this database, never the one a newer session makes;
    /// the reader itself only gets a weak reference through `runtime`.
    let library: NovelLibraryService
    /// The reader's cancellable work, owned by the session so the synchronous
    /// session-end hook can stop it before tabs and the store are torn down.
    let runtime: NovelReaderRuntime

    @MainActor
    init(
        book: NovelBook,
        chapter: NovelChapter?,
        sourceTabId: String,
        isPrivateSession: Bool,
        sessionGeneration: Int,
        library: NovelLibraryService
    ) {
        self.book = book
        self.chapter = chapter
        self.sourceTabId = sourceTabId
        self.isPrivateSession = isPrivateSession
        self.sessionGeneration = sessionGeneration
        self.library = library
        self.runtime = NovelReaderRuntime(library: library)
    }

    static func == (lhs: NovelSession, rhs: NovelSession) -> Bool {
        lhs.id == rhs.id
    }

    /// Whether a close request from this session still refers to the session
    /// on screen. A late close from an old reader must not dismiss a new one.
    func isCurrent(in current: NovelSession?) -> Bool {
        current?.id == id
    }

    /// Whether this session must close because its private generation changed.
    /// A regular reader always answers false.
    func shouldClose(for generation: Int) -> Bool {
        isPrivateSession && sessionGeneration != generation
    }
}

// MARK: - Background picture

/// The custom global background picture, drawn behind the whole shell.
///
/// The picture is the shell's backdrop rather than a layer inside any one
/// surface: the home, the top bar and the surfaces around a page all sit on
/// it, so the chrome samples the picture the user chose.
///
/// Its frame is set explicitly from the container's size, and the overflow is
/// clipped. A `scaledToFill` image on its own answers a layout query with the
/// aspect-fill size, which can be wider or taller than the window — and inside
/// the shell's ZStack that answer inflated the whole layout: the top bar was
/// proposed a width larger than the screen, its controls were centred on that
/// wider canvas, and the leading cluster and the menu fell outside the window.
/// That is why the bar broke only once a picture was set. The GeometryReader
/// gives the picture the container's exact size, so it can never grow the
/// shell to fit itself.
struct BackgroundPictureBackdrop: View {
    var stamp: Double
    @State private var image: UIImage?

    var body: some View {
        GeometryReader { geo in
            ZStack {
                Color(uiColor: .systemBackground)
                if let image {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                        .frame(width: geo.size.width, height: geo.size.height)
                        .clipped()
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
        .ignoresSafeArea()
        .task(id: stamp) {
            image = BackgroundImageStore.load(stamp: stamp)
        }
        .accessibilityHidden(true)
    }
}
