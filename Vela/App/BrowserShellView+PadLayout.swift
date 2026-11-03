//
//  BrowserShellView+PadLayout.swift
//  Vela
//
//  The iPad layout: the top bar, the sidebar drawer and the content column.
//
import SwiftUI
import UIKit
import WebKit

extension BrowserShellView {
    // MARK: - Surfaces

    /// The iPad chrome, after Safari's arrangement: a floating glass top bar
    /// and a bookmarks strip over a page that runs the full height beneath
    /// them. The tab sidebar is a drawer over the page rather than a permanent
    /// column, so the page keeps the whole width while reading.
    var padRoot: some View {
        // The chrome floats over the page, the way Safari's does. The page
        // runs to the top edge and scrolls beneath the glass; the web view's
        // top content inset is what keeps its first line clear of the bar
        // rather than a layout row pushing the whole document down.
        ZStack(alignment: .top) {
            swipeBackTransformed(contentSurface)

            if !omnibox.isEditing, novelSession == nil {
                VStack(spacing: 0) {
                    padTopBar
                        .frame(height: chromeHidden ? 0 : Self.padTopBarHeight, alignment: .top)
                        .clipped()
                        .opacity(chromeHidden ? 0 : 1)
                        .allowsHitTesting(!chromeHidden)

                    BookmarksBarView(
                        onNavigate: { url in
                            navigate(to: url, in: submissionTab)
                        },
                        onOpenManager: { showBookmarks = true },
                        isHidden: chromeHidden
                    )
                }
                .zIndex(2)
            }

            if showPadSidebar {
                padSidebarLayer
                    .padding(.top, chromeHidden ? 0 : padBarsHeight)
                    .zIndex(1)
            }
        }
        .animation(Self.chromeAnimation, value: chromeHidden)
        .animation(Self.sidebarAnimation, value: showPadSidebar)
    }

    /// How much of the window the floating iPad chrome covers, measured from
    /// the top of the safe area.
    ///
    /// The web view's content inset uses this so the page starts below the
    /// glass while still painting underneath it. The bookmarks strip is only
    /// there when the toolbar bookmark root has something in it, which is why
    /// the number is computed rather than a constant.
    var padBarsHeight: CGFloat {
        let bookmarks: CGFloat = BookmarksBarView.hasVisibleBookmarks(in: env) ? 36 : 0
        return Self.padTopBarHeight + bookmarks
    }

    /// The same distance measured from the window's top edge. The web view
    /// ignores the top safe area so the page paints under the status bar the
    /// way Safari's does; its scroll inset therefore has to include that strip
    /// as well as the bars.
    var padTopChromeHeight: CGFloat {
        safeTop + padBarsHeight
    }

    /// Clearance for a surface that is not a web view — the home, the reader,
    /// the error page. Those scroll views have no content inset of their own,
    /// so they ask for the top space as a safe-area inset instead.
    @ViewBuilder
    var padTopClearance: some View {
        if usesPadLayout {
            Color.clear.frame(height: chromeHidden ? 0 : padBarsHeight)
        }
    }

    var padInk: Color {
        if let topChromeForegroundIsLight {
            return topChromeForegroundIsLight ? .black : .white
        }
        return colorScheme == .dark ? .white : .black
    }

    /// The unified Safari-style top bar: sidebar, back, address, share, tabs,
    /// menu — three floating glass pieces over the page.
    ///
    /// The pieces are deliberate. A single strip spanning the window was tried
    /// and read as a slab pasted over the document; separated pills let the
    /// page show through the gaps and keep the address field the subject of
    /// the bar. They now sit over the page rather than pushing it down, so the
    /// glass has something to refract.
    @ViewBuilder
    var padTopBar: some View {
        if #available(iOS 26.0, *) {
            GlassEffectContainer(spacing: BrowserChrome.barGap) {
                padTopBarContent
            }
        } else {
            padTopBarContent
        }
    }

    var padToolbarLayout: ToolbarLayout { env.settings.padToolbarLayout }

    /// The field's width is stated here rather than left to an `HStack`. The
    /// field is a bridged `UITextField`, and a text field answers a size query
    /// with a width of its own — after the home picture loads, the ink update
    /// re-measures the bar, and the answer was a width close to the whole
    /// bar. Taken at face value, the row grew wider than the screen: the
    /// sidebar and back buttons were pushed off the leading edge and the menu
    /// off the trailing one, with the field filling everything between, and in
    /// portrait the whole row was clipped down to a band of empty glass. A
    /// width this layout computes cannot drift.
    var padTopBarContent: some View {
        GeometryReader { geo in
            let leadingWidth = Self.padClusterWidth(controlCount: padToolbarLayout.leading.count + 1)
            let trailingWidth = Self.padClusterWidth(controlCount: padToolbarLayout.trailing.count + 1)
            // The bar's own 12-point margins and the two 6-point gaps between
            // its pieces come out first; whatever is left is the field's.
            let fieldWidth = max(
                64,
                geo.size.width - 24 - leadingWidth - trailingWidth - 12
            )

            HStack(spacing: 6) {
                HStack(spacing: 2) {
                    chromeButton(
                        symbol: "sidebar.left",
                        isEnabled: true,
                        label: showPadSidebar ? "收起标签页侧边栏" : "显示标签页侧边栏",
                        foreground: padInk
                    ) {
                        togglePadSidebar()
                    }

                    ForEach(padToolbarLayout.leading) { control in
                        padToolbarControl(control)
                    }
                }
                .padding(.horizontal, 4)
                .frame(minWidth: BrowserChrome.barHeight)
                .frame(height: BrowserChrome.barHeight)
                .browserFloatingChrome(
                    radius: BrowserRadius.omnibox,
                    material: .thinMaterial,
                    tintStrength: 0.32,
                    elevation: .card
                )

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
                .frame(width: fieldWidth)

                HStack(spacing: 2) {
                    ForEach(padToolbarLayout.trailing) { control in
                        padToolbarControl(control)
                    }

                    hamburgerButton(foreground: padInk) {
                        showMenu = true
                    }
                }
                .padding(.horizontal, 4)
                .frame(minWidth: BrowserChrome.barHeight)
                .frame(height: BrowserChrome.barHeight)
                .browserFloatingChrome(
                    radius: BrowserRadius.omnibox,
                    material: .thinMaterial,
                    tintStrength: 0.32,
                    elevation: .card
                )
            }
            .padding(.horizontal, 12)
            .padding(.top, 8)
            .padding(.bottom, 6)
            .frame(width: geo.size.width, height: Self.padTopBarHeight, alignment: .top)
        }
        .frame(height: Self.padTopBarHeight)
        // Safari-like gestures on the bar itself: an upward flick tucks the
        // top bar (and the bookmarks strip) away; a downward flick returns to
        // the home surface.
        .simultaneousGesture(
            DragGesture(minimumDistance: 16)
                .onEnded { value in
                    let vertical = value.translation.height
                    guard abs(vertical) > abs(value.translation.width) else { return }
                    if vertical < -48 {
                        setChromeHidden(true)
                    } else if vertical > 48 {
                        openHomeTab()
                    }
                }
        )
    }

    /// The width one of the iPad bar's fixed clusters takes: four points of
    /// padding either side, a 34-point button per control, and two points
    /// between them. Every control in both clusters is drawn at 34 points, so
    /// the number is exact rather than an estimate.
    static func padClusterWidth(controlCount: Int) -> CGFloat {
        let count = max(controlCount, 1)
        // A lone control is drawn in a circle as wide as the bar, so the
        // cluster's measured width has that floor too — otherwise the field's
        // share is overstated and the row runs past the window's edge.
        return max(8 + CGFloat(count) * 34 + CGFloat(count - 1) * 2, BrowserChrome.barHeight)
    }

    @ViewBuilder
    func padToolbarControl(_ control: ToolbarControl) -> some View {
        if control == .tabs {
            tabsButton(ink: padInk)
        } else if control == .back {
            chromeButton(
                symbol: control.symbolName,
                isEnabled: toolbarControlEnabled(control),
                label: control.title,
                foreground: padInk
            ) {
                performToolbarControl(control)
            }
            .contextMenu { backHistoryMenu }
        } else {
            chromeButton(
                symbol: control.symbolName,
                isEnabled: toolbarControlEnabled(control),
                label: control.title,
                foreground: padInk
            ) {
                performToolbarControl(control)
            }
        }
    }

    /// The tab drawer: a rounded glass sheet floating over the page.
    ///
    /// The old drawer was a full-height column with square corners, flush to
    /// the screen edge — a second window, not Safari's panel. This one is
    /// inset on every side, clipped to a large radius, and carries the glass
    /// itself, so the page shows through it and the row of rounded corners
    /// reads as a sheet lifted off the document.
    var padSidebarLayer: some View {
        GeometryReader { geo in
            let width = min(Self.padSidebarWidth, max(220, geo.size.width - 32))

            ZStack(alignment: .topLeading) {
                Color.black
                    .opacity(colorScheme == .dark ? 0.30 : 0.14)
                    .ignoresSafeArea()
                    .contentShape(Rectangle())
                    .onTapGesture { closePadSidebar() }
                    .transition(.opacity)

                BrowserSidebarView(onClose: closePadSidebar)
                    .frame(width: width)
                    .frame(maxHeight: .infinity)
                    .clipShape(
                        RoundedRectangle(cornerRadius: BrowserRadius.floating, style: .continuous)
                    )
                    .browserFloatingChrome(
                        radius: BrowserRadius.floating,
                        material: .thinMaterial,
                        tintStrength: 0.22,
                        elevation: .floating,
                        interactive: false
                    )
                    .padding(.top, 8)
                    .padding(.bottom, 8)
                    .padding(.leading, 8)
                    .transition(
                        .modifier(
                            active: SidebarEntrance(isPresented: false),
                            identity: SidebarEntrance(isPresented: true)
                        )
                    )
            }
        }
    }

    /// Opens or closes the drawer with the shared spring and a soft tap of
    /// feedback. The haptic is what makes the panel feel attached to the
    /// button rather than to the animation clock.
    func togglePadSidebar() {
        UIImpactFeedbackGenerator(style: .soft).impactOccurred()
        withAnimation(Self.sidebarAnimation) {
            showPadSidebar.toggle()
        }
    }

    func closePadSidebar() {
        UIImpactFeedbackGenerator(style: .soft).impactOccurred()
        withAnimation(Self.sidebarAnimation) {
            showPadSidebar = false
        }
    }

    /// The page, and whatever floats over it.
    var contentSurface: some View {
        ZStack(alignment: .bottom) {
            mainSurface
        }
        // The keyboard overlays the page — a browser never shrinks its document
        // for a keyboard.
        .ignoresSafeArea(.keyboard)
        // Switching tabs cross-fades the outgoing document into the incoming
        // one. Without it the web view is torn down and replaced in a single
        // frame, which reads as a flash of the shell's blank surface between
        // two pages.
        .animation(.easeInOut(duration: 0.18), value: activeTab?.id)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// The search page lives at the shell root, not inside the content column.
    ///
    /// Inside `contentSurface` it was a child of the keyboard-avoiding layout;
    /// when a floating keyboard was dragged or docked, an ancestor could shift
    /// the whole column, taking the field with it. At the root, with the
    /// keyboard explicitly ignored, the page's geometry is independent of every
    /// keyboard frame.
    @ViewBuilder
    var searchPageLayer: some View {
        if omnibox.isEditing {
            OmniboxSearchPageView(
                viewModel: omnibox,
                keyboardHeight: keyboardHeight,
                cardMaxHeight: searchPageCardHeight,
                topGap: searchPageTopGap,
                bottomGap: safeRectHeight > 0
                    ? max(0, windowHeight - (shellOriginY + safeRectHeight))
                    : safeBottom
            )
            .ignoresSafeArea(.keyboard)
            .transition(.opacity)
            .zIndex(100)
        }
    }

    /// How far down the screen the search page puts its field.
    ///
    /// The field belongs at the top, directly under the status bar: it is the
    /// subject of the page, and every pixel below it is suggestion-list space.
    /// It used to sit about a fifth of the way down, which read as a centred
    /// field and left the list too short to show more than a few rows.
    ///
    /// Independent of the keyboard on purpose: a floating keyboard sends frame
    /// updates while it is dragged, and deriving the field's position from that
    /// made the whole page follow the keyboard. The keyboard is only an overlay
    /// on the list.
    var searchPageTopGap: CGFloat {
        // The overlay inherits the shell's origin, which SwiftUI usually places
        // at the bottom of the status bar. Only the part of the status bar the
        // shell does not already clear needs adding, so the field sits 8 pt
        // below the clock in either arrangement.
        max(0, safeTop - shellOriginY) + 8
    }

    /// The search page's list budget, separate from the phone card's.
    ///
    /// The phone budget ends just above the command bar. The search page owns
    /// the whole screen and has already spent `searchPageTopGap` and the field
    /// height above the list; using the phone budget there made the list taller
    /// than the space it had, which is what pushed the field off the top.
    var searchPageCardHeight: CGFloat {
        // Absolute positions rather than subtractions against the shell's own
        // height: the field starts at the shell's window origin plus the top
        // gap, and the list starts one bar below it. The keyboard's top is
        // measured from the window's bottom.
        let fullHeight = windowHeight > 0
            ? windowHeight
            : safeRectHeight + safeTop + safeBottom
        let fieldTop = shellOriginY + searchPageTopGap
        let listTop = fieldTop + BrowserChrome.barHeight + 14
        let available = fullHeight - keyboardHeight - listTop - 6
        return min(max(120, available), BrowserMetrics.omniboxCardMaxHeight)
    }

    @ViewBuilder
    var mainSurface: some View {
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
            .safeAreaInset(edge: .top) { padTopClearance }
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
                    .safeAreaInset(edge: .top) { padTopClearance }
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
                    .safeAreaInset(edge: .top) { padTopClearance }
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
                        // Where the page's content should start, measured from
                        // the window's top edge. The host subtracts its own
                        // position and reserves the uncovered status-bar strip
                        // when protection is on, so this value is absolute
                        // rather than a scroll inset.
                        //
                        // On the iPad layout the page normally runs under the
                        // floating top bar; 顶部保护 adds the status-bar strip
                        // on top of that. The bar itself still floats over the
                        // page, so the content offset always includes its
                        // height.
                        topContentOffset: usesPadLayout
                            ? padTopChromeHeight
                            : safeTop,
                        protectsStatusBar: protectsTop,
                        // The page's layout viewport ends where the command
                        // bar begins, not merely scrolls clear of it: fixed
                        // footers, `100vh` layouts and pages that scroll
                        // inside their own container all position themselves
                        // against the web view's frame. The home-indicator
                        // inset is the host's to add. Hiding the bar gives
                        // the document the whole screen back.
                        bottomChromeHeight: (usesPadLayout || chromeHidden)
                            ? 0
                            : BrowserChrome.barHeight + BrowserChrome.barGap,
                        // The strip the bar sits in belongs to the shell now,
                        // so it is painted in the page's own background. The
                        // palette is the honest fallback for a document that
                        // has not reported yet.
                        pageBackdrop: Color(cssColor: tab.pageBackground) ?? palette.surface,
                        // Applied when the view is actually attached: an
                        // off-screen web view has no zoomable geometry.
                        allowsGestureZoom: env.settings.preferences.forcedZoomEnabled ?? false,
                        onScroll: { offset in
                            handleScroll(offset: offset)
                        },
                        onProgress: { progress in
                            env.tabManager.updateProgress(progress, id: tab.id)
                        }
                    )
                    .id("web-\(tab.id)")
                    // The page runs under the status bar, and under the home
                    // indicator when the bar is hidden; while the bar is up
                    // its frame stops at the bar's top edge. The container
                    // still fills the window either way, which is what lets
                    // the chrome sample a surface that reaches every edge.
                    .ignoresSafeArea(.all)
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
            .id("content-\(tab.id)")
            .transition(.opacity)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            EmptyState(
                systemImage: "square.on.square",
                title: "没有标签页",
                actionTitle: "新建标签页",
                action: { tabManager.createTab(openSource: .user) }
            )
            .safeAreaInset(edge: .top) { padTopClearance }
        }
    }

}


// MARK: - Sidebar entrance

/// How the drawer arrives: a touch smaller and a touch to the leading side,
/// settling into place under the spring. The scale is what gives the panel its
/// jelly weight; the offset keeps it from appearing out of thin air.
private struct SidebarEntrance: ViewModifier {
    var isPresented: Bool

    func body(content: Content) -> some View {
        content
            .opacity(isPresented ? 1 : 0)
            .scaleEffect(isPresented ? 1 : 0.94, anchor: .leading)
            .offset(x: isPresented ? 0 : -22)
    }
}
