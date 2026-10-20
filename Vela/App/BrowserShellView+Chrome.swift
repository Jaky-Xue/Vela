//
//  BrowserShellView+Chrome.swift
//  Vela
//
//  The command bar, the floating tools, the tab controls and the chrome ink
//  sampling. The shell’s state stays in `BrowserShellView`; these are the views
//  that read it.
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

    /// The ink the bottom chrome draws in: white over a dark backdrop, black
    /// over a light one. The palette decides the chrome's fill, but only the
    /// backdrop behind the glass can decide whether its ink is legible, so the
    /// foreground follows the backdrop and not the palette.
    var barForeground: Color {
        chromeForegroundIsLight ? .black : .white
    }

    /// How far the bar travels when it hides: its own height, the gap under
    /// it, and the safe-area inset. The overlay already holds the bar above
    /// the inset, so this is the whole distance from its resting edge to the
    /// bottom of the screen, plus a little slack.
    var hiddenChromeOffset: CGFloat {
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
    @ViewBuilder var commandBar: some View {
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
        // same promise the home button makes. The gesture is *simultaneous*
        // rather than exclusive so it does not delay or defeat a tap on the
        // omnibox — an exclusive drag on the bar is what made the address field
        // read as intermittently dead in landscape, where the same finger that
        // landed on the field had to wait for the drag recogniser to give up
        // before the tap registered. The 16 pt minimum matches the iPad top bar
        // and keeps a tap from reading as a drag; the bar is also non-hit-testable
        // while the omnibox session is open, so the gesture cannot fire then.
        .simultaneousGesture(
            DragGesture(minimumDistance: 16)
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
                }
        )
        .accessibilityHidden(chromeHidden)
    }

    @ViewBuilder var floatingToolsInGlassContainer: some View {
        if #available(iOS 26.0, *) {
            GlassEffectContainer(spacing: BrowserChrome.barGap) {
                floatingTools
            }
        } else {
            floatingTools
        }
    }

    var toolbarLayout: ToolbarLayout { env.settings.toolbarLayout }

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
                foregroundOverride: barForeground
            )
            .frame(maxWidth: .infinity)

            if !toolbarLayout.trailing.isEmpty {
                toolbarCluster(toolbarLayout.trailing)
            }
        }
    }

    /// One side of the omnibox, as the user arranged it.
    func toolbarCluster(_ controls: [ToolbarControl]) -> some View {
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
        case .reader:
            return canActOnPage && env.settings.preferences.readerModeAvailable
        case .share, .novel, .find, .reload:
            return canActOnPage
        default:
            return true
        }
    }

    func performToolbarControl(_ control: ToolbarControl) {
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

    // MARK: - Chrome backdrop sampling

    /// Re-decides the ink the chrome draws in, from what sits behind the bar.
    ///
    /// Three possible backs: the home surface's own picture, the palette
    /// surface, or the live page. The first two are measured from what they
    /// are — the picture's bottom strip, the surface token in the current
    /// scheme. The page is measured from a small print of its own bottom
    /// strip, taken a beat after the load state settles so the sample reads
    /// this document and not the one before it.
    func updateChromeForeground() {
        guard let tab = activeTab else { return }
        chromeSampleTask?.cancel()
        topChromeForegroundIsLight = nil

        if tab.isHome {
            if let stamp = env.settings.preferences.backgroundImageStamp {
                let scheme = colorScheme
                let surface = palette.surface
                chromeSampleTask = Task {
                    let image = await Task.detached(priority: .utility) {
                        BackgroundImageStore.load(stamp: stamp)
                    }.value
                    guard !Task.isCancelled else { return }
                    if let image {
                        if let backdropIsLight = ChromeBackdrop.bottomStripIsLight(image) {
                            chromeForegroundIsLight = backdropIsLight
                        } else if let backdropIsLight = ChromeBackdrop.surfaceIsLight(surface, scheme: scheme) {
                            chromeForegroundIsLight = backdropIsLight
                        }

                        // The top bar sits on the picture's sky, not its tail.
                        if let topIsLight = ChromeBackdrop.topStripIsLight(image) {
                            topChromeForegroundIsLight = topIsLight
                        } else if let backdropIsLight = ChromeBackdrop.surfaceIsLight(surface, scheme: scheme) {
                            topChromeForegroundIsLight = backdropIsLight
                        }
                    } else if let backdropIsLight = ChromeBackdrop.surfaceIsLight(surface, scheme: scheme) {
                        chromeForegroundIsLight = backdropIsLight
                        topChromeForegroundIsLight = backdropIsLight
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
    func takeBottomStripSnapshot(webView: WKWebView) async -> UIImage? {
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
        let mode = activeTab?.privacyMode
            ?? ((env.settings.preferences.privateBrowsingMode ?? false) ? .private : .regular)
        return tabManager.displayedTabCount(privacyMode: mode)
    }

    /// The tab switcher button: a page outline carrying the count inside it —
    /// the number is what the user reads, so it is the drawing's subject, not
    /// a footnote under a glyph.
    var tabsButton: some View {
        tabsButton(ink: barForeground)
    }

    func tabsButton(ink: Color) -> some View {
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
            BrowserChrome.barHeight + BrowserChrome.barGap + 6
                + (showFindBar ? keyboardHeight : 0)
        )
        .animation(Self.chromeAnimation, value: showFindBar)
    }

}
