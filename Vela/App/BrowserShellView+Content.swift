import SwiftUI
import UIKit
import WebKit

extension BrowserShellView {
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
        if let tab = activeTab {
            // A stable identity per tab keeps SwiftUI from rebuilding the
            // representable when the tab strip changes.
            Group {
                if tab.isHome {
                    NewTabHomeView(
                        settings: env.settings,
                        favoritesService: env.homeFavorites,
                        tabManager: tabManager,
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
                        statusBarStrip: safeTop,
                        // The page stays full bleed and keeps painting under
                        // the glass. The host adds the home-indicator inset
                        // and tells WebKit which part the bar covers, so fixed
                        // footers, sticky bars and `100vh` layouts end above
                        // it; the scroll inset keeps the document's own last
                        // lines reachable.
                        //
                        // The inset deliberately does *not* follow
                        // `chromeHidden`. Reserving it only while the bar is up
                        // made hiding the bar change the document's scrollable
                        // range, and a scroll view resting at the end of a
                        // document clamps to the new range the instant the
                        // inset shrinks: the page jumped up, that jump arrived
                        // as an upward scroll, the shell read it as "the user
                        // wants the controls" and put the bar straight back.
                        // On a long page scrolled to its end — exactly where
                        // people hide the bar — the two fed each other and the
                        // bar flickered. A constant inset keeps the page still
                        // when the bar leaves, at the cost of a little extra
                        // scroll range past the last line.
                        bottomChromeHeight: usesPadLayout
                            ? 0
                            : BrowserChrome.barHeight + BrowserChrome.barGap,
                        // Behind the page while it bounces. Chrome keeps its
                        // own palette surface rather than sampling this color.
                        pageColor: Color(cssColor: tab.pageBackground) ?? palette.surface,
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
                    // 顶部保护 on: let SwiftUI end the host at the top safe
                    // area, so the page cannot paint under the clock
                    // regardless of what the window's inset reports say. Off:
                    // the page runs edge to edge under the status bar too, and
                    // the scroll inset keeps its first line clear. The bottom
                    // is always full bleed; the bar's obstruction is told to
                    // WebKit rather than carved out of the frame, so the
                    // document still reaches the screen's bottom edge.
                    .ignoresSafeArea(edges: protectsTop ? [.bottom, .horizontal] : .all)
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
