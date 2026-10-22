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

    /// The iPad chrome, after Safari's arrangement: one top bar spanning the
    /// window, a bookmarks strip beneath it, and the page filling the rest.
    /// The tab sidebar is a drawer over the page rather than a permanent
    /// column, so the page keeps the whole width while reading.
    var padRoot: some View {
        VStack(spacing: 0) {
            // The search page carries its own field; leaving the top bar in
            // place would put two address fields on screen.
            if !omnibox.isEditing, novelSession == nil {
                padTopBar
                    .frame(height: chromeHidden ? 0 : Self.padTopBarHeight, alignment: .top)
                    .clipped()
                    .opacity(chromeHidden ? 0 : 1)
                    .allowsHitTesting(!chromeHidden)
                    .zIndex(2)
            }

            ZStack(alignment: .topLeading) {
                VStack(spacing: 0) {
                    if !omnibox.isEditing, novelSession == nil {
                        BookmarksBarView(
                            onNavigate: { url in
                                navigate(to: url, in: submissionTab)
                            },
                            onOpenManager: { showBookmarks = true },
                            isHidden: chromeHidden
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

    var padInk: Color {
        if let topChromeForegroundIsLight {
            return topChromeForegroundIsLight ? .black : .white
        }
        return colorScheme == .dark ? .white : .black
    }

    /// The unified Safari-style top bar: sidebar, back, address, share, tabs,
    /// menu — one glass surface instead of the phone layout's three clusters.
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

    /// Three glass pieces rather than one continuous strip: the fixed sidebar
    /// surface plus the user's leading controls, the address field, and the
    /// user's trailing controls plus the menu. The gaps are what divide the
    /// bar that used to read as one long slab.
    ///
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
                        withAnimation(.snappy(duration: 0.26)) {
                            showPadSidebar.toggle()
                        }
                    }

                    ForEach(padToolbarLayout.leading) { control in
                        padToolbarControl(control)
                    }
                }
                .padding(.horizontal, 4)
                .frame(minWidth: BrowserChrome.barHeight)
                .frame(height: BrowserChrome.barHeight)
                .browserFloatingChrome(radius: BrowserRadius.omnibox, tintStrength: 0.5, elevation: .card)

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
                .browserFloatingChrome(radius: BrowserRadius.omnibox, tintStrength: 0.5, elevation: .card)
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

    /// The tab drawer. It sits over the content only (below the top bar), with
    /// a scrim that closes it on a tap outside.
    var padSidebarLayer: some View {
        ZStack(alignment: .topLeading) {
            Color.black
                .opacity(colorScheme == .dark ? 0.30 : 0.14)
                .ignoresSafeArea()
                .contentShape(Rectangle())
                .onTapGesture { showPadSidebar = false }

            BrowserSidebarView(
                onClose: { showPadSidebar = false }
            )
            .frame(width: Self.padSidebarWidth)
            .frame(maxHeight: .infinity)
            .shadow(color: .black.opacity(colorScheme == .dark ? 0.45 : 0.16), radius: 28, x: 10, y: 0)
        }
        .transition(.opacity.combined(with: .move(edge: .leading)))
    }

    /// The page, and whatever floats over it.
    var contentSurface: some View {
        ZStack(alignment: .bottom) {
            mainSurface

            if omnibox.isEditing {
                OmniboxSearchPageView(
                    viewModel: omnibox,
                    keyboardHeight: keyboardHeight,
                    cardMaxHeight: searchPageCardHeight,
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
    var searchPageTopGap: CGFloat {
        let screenHeight = safeRectHeight + safeTop + safeBottom
        let available = screenHeight - keyboardHeight
        return min(max(56, available * 0.3), 320)
    }

    /// The search page's list budget, separate from the phone card's.
    ///
    /// The phone budget ends just above the command bar. The search page owns
    /// the whole screen and has already spent `searchPageTopGap` and the field
    /// height above the list; using the phone budget there made the list taller
    /// than the space it had, which is what pushed the field off the top.
    var searchPageCardHeight: CGFloat {
        let screenHeight = safeRectHeight + safeTop + safeBottom
        let available = screenHeight - keyboardHeight
            - searchPageTopGap - BrowserChrome.barHeight - 14
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

}
