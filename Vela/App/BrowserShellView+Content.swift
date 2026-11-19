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
        .animation(BrowserMotion.tabSwitch(reduceMotion), value: activeTab?.id)
        // The main surface changing — home to page, page to error, the page
        // yielding to the reader — is the largest movement in the shell. The
        // transition is asymmetric: the incoming surface fades up from just
        // below its resting size, the outgoing one simply fades, so the eye
        // follows what is arriving rather than watching both at once.
        .animation(BrowserMotion.surface(reduceMotion), value: displayedSurface)
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
        let available = fullHeight - max(keyboardHeight, safeBottom) - listTop - 6
        return min(max(0, available), BrowserMetrics.omniboxCardMaxHeight)
    }

    /// How one main surface replaces another.
    ///
    /// Asymmetric on purpose: the incoming surface fades up from just below its
    /// resting size, while the outgoing one only fades. Two surfaces growing at
    /// once is what makes a swap read as a cross-dissolve; one arriving and one
    /// leaving reads as a change of place. Reduce Motion keeps the fade and
    /// drops the movement.
    var surfaceTransition: AnyTransition {
        guard !reduceMotion else { return .opacity }
        return .asymmetric(
            insertion: .opacity
                .combined(with: .scale(scale: 0.986, anchor: .bottom))
                .combined(with: .offset(y: 10)),
            removal: .opacity
                .combined(with: .scale(scale: 1.008, anchor: .bottom))
        )
    }

    @ViewBuilder
    var mainSurface: some View {
        if let tab = activeTab {
            // A stable identity per tab keeps SwiftUI from rebuilding the
            // representable when the tab strip changes.
            Group {
                switch baseSurface {
                case .home:
                    NewTabHomeView(
                        settings: env.settings,
                        favoritesService: tab.privacyMode == .private
                            ? env.services.privateHomeFavorites : env.homeFavorites,
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
                    .transition(surfaceTransition)
                case .error:
                    // A failed navigation shows the error surface *instead of*
                    // the web view, but the web view is kept: it is what the
                    // retry re-uses, and it holds whatever the process still has.
                    if let failure = tab.lastFailure {
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
                        .transition(surfaceTransition)
                    }
                case .page, .novel:
                    // `.novel` keeps rendering the page underneath: the reader
                    // is a layer over it, and closing the reader reveals this
                    // exact page rather than a rebuilt one.
                    if let webView = tabManager.webView(for: tab.id) {
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
                            // the glass — to the screen's bottom edge, not to
                            // the bar's. The host adds the home-indicator inset
                            // and keeps a scroll inset for the bar's strip while
                            // the bar is up, which is what lets the document's
                            // last lines be scrolled clear of it. The page's
                            // frame and layout are untouched, so a site's own
                            // bottom sheet still reaches the edge.
                            //
                            // The reserve goes with the bar: while it is away the
                            // page holds nothing back for it, so that strip stays
                            // live — the row a bottom sheet keeps there is
                            // tappable. (Shrinking it changes the scrollable
                            // range, and a document resting at its end clamps to
                            // the new range the instant it shrinks; `handleScroll`
                            // ignores those samples for a moment so the clamp
                            // cannot put the bar straight back.)
                            bottomChromeHeight: usesPadLayout
                                ? 0
                                : BrowserChrome.barHeight + BrowserChrome.barGap,
                            isChromeHidden: chromeHidden,
                            // Behind the page while it bounces. Chrome keeps its
                            // own palette surface rather than sampling this color.
                            pageColor: Color(cssColor: tab.pageBackground) ?? palette.surface,
                            // Applied when the view is actually attached: an
                            // off-screen web view has no zoomable geometry.
                            allowsGestureZoom: env.settings.preferences.allowsPinchZoom,
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
                        .transition(surfaceTransition)
                    } else {
                        // A cold tab with no web view at all. Materialising happens
                        // in `onAppear` rather than here: creating a web view during
                        // view evaluation would mutate published state mid-update.
                        Color.clear
                            .onAppear {
                                tabManager.activateTab(id: tab.id)
                            }
                            .ignoresSafeArea(edges: .top)
                            .transition(surfaceTransition)
                        }
                }
            }
            .id("content-\(tab.id)")
            .transition(surfaceTransition)
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
