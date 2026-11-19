import SwiftUI
import UIKit
import WebKit

extension BrowserShellView {
    /// Whether the shell's own ambient field is worth drawing.
    ///
    /// A live page is opaque and covers it completely; keeping a full-screen
    /// mesh, material and specular layers under that page only costs
    /// compositing. The field appears on the surfaces that show something of
    /// the app itself — home, reader, error, empty — and in sheets, which draw
    /// their own.
    var showsAmbientRootBackground: Bool {
        // An edge swipe pulls the page to the right and reveals the surface
        // underneath. Forcing the ambient field for the length of the gesture
        // gives it a lit stage instead of the flat palette colour a page
        // normally covers.
        if swipeBackTranslation > 0.5 { return true }
        if novelSession != nil { return false }
        if showsBackgroundPictureAtRoot { return false }
        guard let tab = activeTab else { return true }
        if tab.isHome || tab.loadState.isFailure { return true }
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

    /// The app's own backdrop, below everything.
    ///
    /// Kept apart from the content column so the cross-fade below is scoped to
    /// the backdrop: an `.animation(value:)` on the outer stack would animate
    /// every layout change in the browser whenever the backdrop switched.
    /// Choosing a picture in 外观 is a visual decision made with the settings
    /// sheet still open, and a background that cut from one surface to another
    /// behind it read as a rendering glitch rather than as the choice taking
    /// effect.
    @ViewBuilder
    var shellBackdrop: some View {
        Group {
            if showsBackgroundPictureAtRoot, let stamp = env.settings.preferences.backgroundImageStamp {
                BackgroundPictureBackdrop(stamp: stamp)
                    .transition(.opacity)
            } else if showsAmbientRootBackground {
                AmbientBackgroundView()
                    .transition(.opacity)
            } else {
                palette.surface
                    .ignoresSafeArea()
                    .transition(.opacity)
            }
        }
        .animation(BrowserMotion.backdrop(reduceMotion), value: showsBackgroundPictureAtRoot)
        .animation(BrowserMotion.backdrop(reduceMotion), value: showsAmbientRootBackground)
        .animation(BrowserMotion.backdrop(reduceMotion), value: env.settings.backgroundStyle)
    }

    var shellBase: some View {
        ZStack {
            shellBackdrop

            if usesPadLayout {
                padRoot
            } else {
                swipeBackTransformed(contentSurface)
            }
        }
        .overlay(alignment: .leading) { swipeBackIndicator }
        .background { safeAreaReader }
        // The shell is laid out inside the safe area, so `safeTop` and
        // `safeBottom` read from its geometry are zero — the clock and the
        // home indicator are outside the rectangle SwiftUI hands the ZStack.
        // The web view, though, deliberately paints edge to edge, and every
        // offset derived from those numbers (the top protection strip, the
        // command bar's clearance, the iPad content inset) needs the window's
        // real insets. This probe sits in the window and reports them.
        .background {
            WindowSafeAreaReader { metrics in
                applyWindowMetrics(metrics)
            }
        }
        .background {
            EdgeSwipeBackBridge(
                isEnabled: edgeSwipeBackEnabled,
                onChanged: { handleSwipeBackChanged($0) },
                onEnded: { handleSwipeBackEnded($0, velocity: $1) },
                onCancelled: { handleSwipeBackCancelled() }
            )
        }
    }

    /// The Android-style back arrow: the edge gesture's only visual.
    ///
    /// It follows the finger, grows toward the release threshold and fills in
    /// once the swipe will commit; holding keeps it exactly where the finger
    /// is. The page itself never moves.
    @ViewBuilder var swipeBackIndicator: some View {
        if isSwipeBackTracking || swipeBackTranslation > 0.5 {
            EdgeSwipeBackIndicator(
                intensity: min(1, swipeBackProgress / 0.22),
                armed: swipeBackArmed,
                isCompleting: isSwipeBackCompleting
            )
            .padding(.leading, BrowserChrome.sideInset + 2)
            .allowsHitTesting(false)
        }
    }

    /// The command bar yielding to the reader: it leaves downward, off the
    /// edge it lives on, while the reader rises to cover the page.
    var commandBarYieldTransition: AnyTransition {
        guard !reduceMotion else { return .opacity }
        return .opacity.combined(with: .offset(y: BrowserChrome.barHeight + BrowserChrome.barGap))
    }

    /// The floating tools (find, notices) leave upward when the reader takes
    /// the screen, and come back from the bar they belong to.
    var floatingToolsYieldTransition: AnyTransition {
        guard !reduceMotion else { return .opacity }
        return .asymmetric(
            insertion: .opacity.combined(with: .move(edge: .bottom)),
            removal: .opacity.combined(with: .move(edge: .top))
        )
    }

    /// The tab overview rising from the bottom edge.
    var overviewEntranceTransition: AnyTransition {
        guard !reduceMotion else { return .opacity }
        return .opacity
            .combined(with: .scale(scale: 0.96, anchor: .bottom))
            .combined(with: .offset(y: 24))
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
                    // The bar leaves on the reader's own curve, a beat behind
                    // its arrival, so the two read as one movement.
                    .transition(commandBarYieldTransition)
            }
        }
        .overlay(alignment: .bottom) {
            // Only when a tool is actually in it. The container is a
            // `GlassEffectContainer` on iOS 26, and an empty one still owns a
            // hit-testing surface over the bottom of the page: a tap there —
            // a page's own last row, a site's last menu item — never reached
            // the page, on every site. With nothing to show, nothing is
            // inserted.
            if novelSession == nil, hasFloatingTools {
                floatingToolsInGlassContainer
                    // The tools enter from the bar they belong to and leave
                    // upward when the reader takes the screen.
                    .transition(floatingToolsYieldTransition)
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
                    homePreview: homePreview,
                    homePreviewTabId: homePreviewTabId,
                    onClose: {
                        showTabsOverview = false
                        homePreview = nil
                        homePreviewTabId = nil
                    }
                )
                .transition(overviewEntranceTransition)
                .zIndex(20)
            }
        }
        .animation(BrowserMotion.overview(reduceMotion), value: shell.isPresented(.tabsOverview))
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
        .animation(BrowserMotion.notice(reduceMotion), value: shell.isPresented(.qrScanner))
        .overlay { novelReaderLayer }
        .animation(BrowserMotion.novelEnter(reduceMotion), value: shell.surface)
    }

    private var shellPersistenceNotice: some View {
        shellOverlays.alert("无法保存浏览数据", isPresented: Binding(
            get: { env.persistenceNotice != nil },
            set: { if !$0 { env.persistenceNotice = nil } }
        )) {
            Button("好", role: .cancel) { env.persistenceNotice = nil }
        } message: { Text(env.persistenceNotice ?? "") }
    }

    /// The shell's own alerts, split from the layers they cover.
    var shellNotices: some View {
        shellPersistenceNotice

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
            "无法进入无痕模式",
            isPresented: Binding(
                get: { env.privateAccessNotice != nil },
                set: { if !$0 { env.privateAccessNotice = nil } }
            ),
            presenting: env.privateAccessNotice
        ) { _ in
            Button("好", role: .cancel) { env.privateAccessNotice = nil }
        } message: { message in
            Text(message)
        }
        .alert(
            "下载文件？",
            isPresented: Binding(
                get: { env.downloads.pendingPrompt(windowId: env.windowId) != nil },
                set: { if !$0 { env.downloads.dismissPendingPrompt(windowId: env.windowId) } }
            ),
            presenting: env.downloads.pendingPrompt(windowId: env.windowId)
        ) { _ in
            Button("下载") { env.downloads.confirmPendingPrompt(windowId: env.windowId) }
            Button("取消", role: .cancel) { env.downloads.dismissPendingPrompt(windowId: env.windowId) }
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
}
