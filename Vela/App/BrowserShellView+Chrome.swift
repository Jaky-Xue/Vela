//
//  BrowserShellView+Chrome.swift
//  Vela
//
//  The command bar, floating tools, tab controls and stable palette foreground.
//  The state they read lives in `ShellState`; these are the views that
//  draw it.
//
import SwiftUI
import UIKit
import WebKit

extension BrowserShellView {
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

    /// Foreground paired with the stable palette surface under the glass.
    var barForeground: Color {
        palette.primaryText
    }

    /// The bar's three glass pieces, each with its own glass.
    ///
    /// A `GlassEffectContainer` around them was tried and removed: on iOS 26
    /// the container paints its own full-width backdrop across the bar,
    /// which reads as a grey strip between the page and the bar and does not
    /// belong to either. The pieces carry their own glass, so the page shows
    /// between and around them the way the layout promises.
    @ViewBuilder var commandBar: some View {
        commandBarContent
        .padding(.horizontal, BrowserChrome.sideInset)
        // The bottom-aligned overlay already lays the bar out above the
        // home-indicator inset; adding the inset again here lifted the bar a
        // whole safe area off the edge. The gap is all this padding owes.
        .padding(.bottom, BrowserChrome.barGap)
        // Mid-drag the bar follows the finger downward and fades with
        // distance; dragged upward it lifts a little, promising the home
        // surface on release. A *hidden* bar is not offset — it is removed
        // from the hierarchy by the shell, because the glass interaction
        // layers would otherwise keep taking touches in that strip.
        .offset(y: chromeDragOffset > 0 ? chromeDragOffset : chromeLiftOffset)
        .opacity(max(0, 1 - chromeDragOffset / 140))
        // The bar's transparent gaps and its margins are part of the drag
        // surface. Without a content shape the gesture began only on the
        // rendered pieces — the omnibox and the two button clusters — so a
        // finger that landed between them started a drag the bar never heard.
        .contentShape(Rectangle())
        .animation(BrowserMotion.chrome(reduceMotion), value: chromeHidden)
        .animation(BrowserMotion.chrome(reduceMotion), value: omnibox.isEditing)
        // Dragging the bar downward dismisses it, off the bottom edge the way
        // a sheet leaves; dragging it upward returns to the home surface, the
        // same promise the home button makes. The gesture is *simultaneous*
        // rather than exclusive so it does not delay or defeat a tap on the
        // omnibox — an exclusive drag on the bar is what made the address field
        // read as intermittently dead in landscape, where the same finger that
        // landed on the field had to wait for the drag recogniser to give up
        // before the tap registered. The 10 pt minimum keeps a tap from reading
        // as a drag on a bar this shallow; the bar is also non-hit-testable
        // while the omnibox session is open, so the gesture cannot fire then.
        .simultaneousGesture(
            DragGesture(minimumDistance: 10)
                .updating($chromeDragInFlight) { _, inFlight, _ in
                    inFlight = true
                }
                .onChanged { value in
                    guard canDragChromeAway, !chromeHidden else { return }
                    let vertical = value.translation.height
                    // The axis is decided once, on the first movement past the
                    // slop, and kept for the rest of the gesture. Re-testing
                    // the *cumulative* translation is what made a downward
                    // drag that drifted sideways — every thumb does — report
                    // itself as a sideways drag at release and spring back.
                    // A gesture that has already moved vertically is a
                    // vertical drag, however the finger wobbles after that.
                    if !chromeDragIsVertical {
                        guard abs(vertical) > abs(value.translation.width) else { return }
                        chromeDragIsVertical = true
                    }
                    if vertical > 0 {
                        chromeDragOffset = vertical
                        chromeLiftOffset = 0
                        chromeHomeArmed = false
                    } else {
                        chromeLiftOffset = max(-36, vertical * 0.35)
                        chromeDragOffset = 0
                        let armed = vertical < -44
                        if armed != chromeHomeArmed {
                            chromeHomeArmed = armed
                            if armed {
                                UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                            }
                        }
                    }
                }
                .onEnded { value in
                    let vertical = value.translation.height
                    // A gesture that never cleared the axis test still counts
                    // when it ends mostly vertical; only a genuinely sideways
                    // one is the page's.
                    let wasVertical = chromeDragIsVertical
                        || abs(vertical) > abs(value.translation.width)
                    chromeDragIsVertical = false
                    if canDragChromeAway, !chromeHidden, wasVertical {
                        // The throw counts as well as the distance: a short,
                        // fast flick is the gesture people actually make, and
                        // requiring the finger itself to travel the threshold
                        // is what made the bar feel like it sometimes ignored
                        // the swipe. The distances are deliberately modest —
                        // the bar follows the finger while it moves, so a
                        // release anywhere near where the hint fills has to
                        // commit, or the drag reads as having been refused.
                        let projected = value.predictedEndTranslation.height
                        let downward = max(vertical, projected)
                        let upward = min(vertical, projected)
                        if downward > 36 {
                            setChromeHidden(true)
                        } else if upward < -48 {
                            openHomeTab()
                        }
                    }
                    chromeHomeArmed = false
                    withAnimation(BrowserMotion.chrome(reduceMotion)) {
                        chromeDragOffset = 0
                        chromeLiftOffset = 0
                    }
                }
        )
        // A cancelled drag — a tab switch, a call banner, another recogniser
        // taking the finger — never reaches `onEnded`. See
        // `handleChromeDragFlight`.
        .onChange(of: chromeDragInFlight) { _, inFlight in
            handleChromeDragFlight(inFlight)
        }
        .overlay(alignment: .top) { chromeDragHint }
        .accessibilityHidden(chromeHidden)
    }

    /// The promise shown while the command bar is dragged: 释放后收起工具栏 for
    /// a downward drag, 释放后返回首页 for an upward one, the same readout the
    /// iPad top bar shows. It fills once releasing will commit, so the gesture
    /// never fires without warning — and, just as important, the phone layout
    /// announces that the bar can be dragged at all.
    @ViewBuilder var chromeDragHint: some View {
        let isHiding = chromeDragOffset > 6
        let isReturningHome = chromeLiftOffset < -6
        if (isHiding || isReturningHome), !chromeHidden, !omnibox.isEditing {
            let armed = isHiding ? chromeDragOffset > 34 : chromeHomeArmed
            // The upward travel is deliberately damped (the bar lifts a third
            // of the finger's distance), so its hint is scaled back up to
            // reach full opacity at the same distance the gesture arms.
            let travel = isHiding ? chromeDragOffset : abs(chromeLiftOffset) * 2
            Text(isHiding ? "释放后收起工具栏" : "释放后返回首页")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(armed ? palette.onAccent : palette.primaryText)
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background {
                    Capsule().fill(armed ? palette.accent : palette.controlFill)
                }
                .overlay {
                    Capsule().strokeBorder(palette.cardStroke, lineWidth: 0.5)
                }
                .shadow(color: .black.opacity(0.16), radius: 12, y: 4)
                .offset(y: -46)
                .opacity(min(1, travel / 20))
                .allowsHitTesting(false)
                .animation(BrowserMotion.hint(reduceMotion), value: armed)
                .transition(.opacity.combined(with: .scale(scale: 0.94)))
        }
    }

    /// The floating tools, each carrying its own glass.
    ///
    /// No `GlassEffectContainer` here either: the container's own backdrop
    /// would paint a strip across the page under the tools (see `commandBar`).
    @ViewBuilder var floatingToolsInGlassContainer: some View {
        floatingTools
    }

    var toolbarLayout: ToolbarLayout { env.settings.toolbarLayout }

    /// The bar stops growing well before the window's edge. On a phone the
    /// screen is narrower than this and nothing changes; on an iPad — where
    /// the phone layout can still be chosen — an unbounded field stretched
    /// edge to edge read as a slab, while a 720-point cap left the bar
    /// floating as a narrow island in landscape. The overlay centres the
    /// capped bar, so the field keeps a useful length and still keeps an
    /// inset on both sides.
    static let commandBarMaxWidth: CGFloat = 960

    var commandBarContent: some View {
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
                foregroundOverride: barForeground,
                onSiteInfo: { showSiteCapabilities = true }
            )
            .frame(maxWidth: .infinity)

            if !toolbarLayout.trailing.isEmpty {
                toolbarCluster(toolbarLayout.trailing)
            }
        }
        .frame(maxWidth: Self.commandBarMaxWidth)
    }

    /// One side of the omnibox, as the user arranged it.
    func toolbarCluster(_ controls: [ToolbarControl]) -> some View {
        HStack(spacing: 2) {
            ForEach(controls) { control in
                toolbarButton(control)
            }
        }
        .padding(.horizontal, 4)
        // A cluster holding one 34-point control would otherwise be 42 points
        // wide against a 52-point bar: a capsule taller than it is wide, which
        // reads as a squashed circle. Holding the cluster to at least the bar's
        // height makes a lone control a circle, and changes nothing once a
        // second control widens the cluster past that.
        .frame(minWidth: BrowserChrome.barHeight)
        .frame(height: BrowserChrome.barHeight)
        .browserFloatingChrome(
            radius: BrowserRadius.omnibox,
            material: .regularMaterial,
            tintStrength: 0.32,
            elevation: .card
        )
    }

    /// One control in the bar. Back keeps its long-press history, and the tab
    /// control keeps its count badge wherever the user puts it.
    @ViewBuilder
    func toolbarButton(_ control: ToolbarControl) -> some View {
        if control == .tabs {
            tabsButton
        } else if control == .menu {
            hamburgerButton { showMenu = true }
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

    func toolbarControlEnabled(_ control: ToolbarControl) -> Bool {
        switch control {
        case .back:
            return canGoBack
        case .home:
            return activeTab != nil
        case .share, .novel, .find, .reload:
            return canActOnPage
        default:
            return true
        }
    }

    /// Opens the tab overview, printing the home first when the home is the
    /// surface being left behind.
    ///
    /// The print is taken before the overview is inserted: once the overlay is
    /// on screen a window snapshot would photograph the overview instead of
    /// the page behind it. A private home is deliberately not printed; its
    /// card keeps the honest identity placeholder.
    func performToolbarControl(_ control: ToolbarControl) {
        switch control {
        case .back:
            goBack()
        case .home:
            openHomeTab()
        case .tabs:
            presentTabsOverview()
        case .menu:
            showMenu = true
        case .bookmarks:
            showBookmarks = true
        case .history:
            showHistory = true
        case .downloads:
            showDownloads = true
        case .novel:
            activateNovelMode()
        case .bookshelf:
            openBookshelf()
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
            openSettings()
        case .privateMode:
            Task { await env.requestPrivateBrowsingToggle() }
        }
    }

    /// The menu control, drawn rather than taken from the symbol set so its
    /// three bars are the same optical weight as the glyphs beside it.
    func hamburgerButton(
        foreground: Color? = nil,
        label: String = "菜单",
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HamburgerGlyph()
        }
        .buttonStyle(ChromeButtonStyle())
        .foregroundStyle(foreground ?? barForeground)
        .accessibilityLabel(label)
    }

    /// One glyph button inside the chrome.
    func chromeButton(
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

    @ViewBuilder
    var backHistoryMenu: some View {
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
    var tabCountForActiveMode: Int {
        tabManager.displayedTabCount(privacyMode: env.currentPrivacyMode)
    }

    /// The tab switcher button: a page outline carrying the count inside it —
    /// the number is what the user reads, so it is the drawing's subject, not
    /// a footnote under a glyph.
    var tabsButton: some View {
        tabsButton(ink: barForeground)
    }

    func tabsButton(ink: Color) -> some View {
        Button {
            presentTabsOverview()
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

    /// Whether the floating tools have anything to show.
    ///
    /// An empty one is not inserted at all: there is nothing to draw, and an
    /// overlay with no tool in it would only sit over the page.
    var hasFloatingTools: Bool {
        if env.overlays.isElementPickerArmed { return true }
        if showFindBar { return true }
        if let tab = activeTab, !tab.isHome, tab.serverStatus >= 400 { return true }
        return false
    }

    /// The find bar and the server-status notice, pinned under the chrome.
    ///
    /// They are tools for the page in view, so they do not take part in the
    /// scroll-hide: a find bar that vanished mid-search would be a bar the user
    /// has to chase.
    var floatingTools: some View {
        VStack(spacing: 8) {
            if env.overlays.isElementPickerArmed {
                ElementPickerBanner {
                    env.webCoordinator.disarmElementPicker(in: activeWebView)
                }
                .transition(.move(edge: .top).combined(with: .opacity))
            }

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
                    // The query lives on the shell state machine, which is a
                    // reference type, so the field binds through a closure
                    // rather than a projected value.
                    query: Binding(
                        get: { findQuery },
                        set: { findQuery = $0 }
                    ),
                    result: env.overlays.findResult,
                    onNext: { env.webCoordinator.findInPage(findQuery, forward: true) },
                    onPrevious: { env.webCoordinator.findInPage(findQuery, forward: false) },
                    onClose: {
                        showFindBar = false
                        findQuery = ""
                        env.webCoordinator.clearFindInPage()
                    }
                )
                // Typing drives the search. The field used to bind the query
                // and nothing ran until the next/previous button was pressed,
                // so a search looked like it did nothing at all. The watcher
                // sits on the bar rather than on the shell's root chain, which
                // is already at the type checker's budget.
                .onChange(of: findQuery) { _, query in
                    scheduleFind(for: query)
                }
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
            max(
                BrowserChrome.barHeight + BrowserChrome.barGap,
                showFindBar ? keyboardHeight - safeBottom : 0
            ) + 6
        )
        .animation(BrowserMotion.chrome(reduceMotion), value: showFindBar)
    }

}
