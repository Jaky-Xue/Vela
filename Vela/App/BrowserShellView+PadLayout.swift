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
        // The hint lives outside the bar's clipped column: placed inside it,
        // the strip's own height cut the pill away.
        .overlay(alignment: .top) {
            padChromeDragHint
                .padding(.top, chromeHidden ? 0 : padBarsHeight + 4)
        }
        .animation(BrowserMotion.chrome(reduceMotion), value: chromeHidden)
        .animation(BrowserMotion.sidebar(reduceMotion), value: showPadSidebar)
        // The reader takes the top bar with it on the same curve as the phone
        // layout's command bar, so entering 小说模式 reads as one movement on
        // either layout.
        .animation(BrowserMotion.novelEnter(reduceMotion), value: shell.surface)
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
        palette.primaryText
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
        Group {
            if #available(iOS 26.0, *) {
                GlassEffectContainer(spacing: BrowserChrome.barGap) {
                    padTopBarContent
                }
            } else {
                padTopBarContent
            }
        }
        // Safari-like gestures on the bar itself: an upward flick tucks the
        // top bar (and the bookmarks strip) away; a downward flick returns to
        // the home surface. The recognizer lives outside the glass container:
        // attaching it to the content inside put a layer between the drag and
        // the bar, and the swipe stopped arriving.
        .simultaneousGesture(
            DragGesture(minimumDistance: 16)
                .onChanged { value in
                    guard !omnibox.isEditing, !chromeHidden else { return }
                    let vertical = value.translation.height
                    guard abs(vertical) > abs(value.translation.width) else { return }
                    padChromeDragTranslation = vertical
                    let home = vertical > 48
                    let hide = vertical < -48
                    if home != padChromeHomeArmed {
                        padChromeHomeArmed = home
                        if home {
                            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                        }
                    }
                    padChromeHideArmed = hide
                }
                .onEnded { value in
                    let vertical = value.translation.height
                    padChromeDragTranslation = 0
                    padChromeHomeArmed = false
                    padChromeHideArmed = false
                    guard !omnibox.isEditing, !chromeHidden else { return }
                    guard abs(vertical) > abs(value.translation.width) else { return }
                    // The throw counts as well as the distance, so a short
                    // flick lands the same way a long drag does.
                    let projected = value.predictedEndTranslation.height
                    if min(vertical, projected) < -48 {
                        setChromeHidden(true)
                    } else if max(vertical, projected) > 48 {
                        openHomeTab()
                    }
                }
        )
    }

    /// The iPad bar's drag readout: the release the finger is heading for.
    @ViewBuilder
    var padChromeDragHint: some View {
        if abs(padChromeDragTranslation) > 10, !chromeHidden, !omnibox.isEditing {
            let returnsHome = padChromeDragTranslation > 0
            let armed = returnsHome ? padChromeHomeArmed : padChromeHideArmed
            Text(returnsHome ? "释放后返回首页" : "释放后收起工具栏")
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
                .allowsHitTesting(false)
                .animation(BrowserMotion.hint(reduceMotion), value: armed)
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
                    foregroundOverride: padInk,
                onSiteInfo: { showSiteCapabilities = true }
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
        withAnimation(BrowserMotion.sidebar(reduceMotion)) {
            showPadSidebar.toggle()
        }
    }

    func closePadSidebar() {
        UIImpactFeedbackGenerator(style: .soft).impactOccurred()
        withAnimation(BrowserMotion.sidebar(reduceMotion)) {
            showPadSidebar = false
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
