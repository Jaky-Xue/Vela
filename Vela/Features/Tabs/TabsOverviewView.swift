//
//  TabsOverviewView.swift
//  Vela
//
//  Stable page-card identities, an appearance-aware background and restrained motion.
//  The privacy split is applied before the first body render, including locked sessions.
//

import SwiftUI
import UIKit
import WebKit

struct TabsOverviewView: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.browserPalette) private var palette

    /// A print of the real home surface, taken when the overview was opened
    /// from it. A native SwiftUI home has no `WKWebView` to photograph, and a
    /// drawn-in miniature would be content the user never saved. The print is
    /// the actual surface; `nil` means it could not be taken, in which case
    /// the card shows an honest identity placeholder.
    var homePreview: UIImage? = nil
    /// The home tab the print belongs to. A print from one mode or tab is
    /// never shown on another card.
    var homePreviewTabId: String? = nil
    /// Closes the overview. The overview is a layer in the shell's own
    /// hierarchy rather than a presented controller, so there is no
    /// presentation to dismiss — the shell owns the flag, and hands the way
    /// out down here.
    var onClose: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var showPrivateTabs = false
    @State private var didSyncMode = false
    @State private var pendingPrivateUnlock = false
    @State private var isSearching = false
    @State private var searchQuery = ""
    @Namespace private var modeAnimation
    @FocusState private var searchFieldFocused: Bool
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    private var tabManager: TabManager { env.tabManager }

    private var displaysPrivateTabs: Bool { didSyncMode ? showPrivateTabs : tabManager.activeTab?.privacyMode == .private }

    private var currentMode: BrowserSessionPrivacyMode {
        displaysPrivateTabs ? .private : .regular
    }

    /// The tabs of the mode on screen, narrowed by the search field when it
    /// has text. The pinned rail and the grid are two views of this one list,
    /// so a search reaches into both.
    ///
    /// The home tab is not one of the cards: it is what the browser shows once
    /// every page is gone. While any page tab exists it stays out of the grid
    /// — including when the user is looking at it — so 主页 appears in the
    /// strip only after the last page has been closed, which is also the
    /// moment it is the one card left behind.
    private var visibleTabs: [BrowserTabState] {
        let tabs = displaysPrivateTabs ? tabManager.privateTabs : tabManager.regularTabs
        let realTabs = tabs.filter { !$0.isHome }
        let listed: [BrowserTabState] = realTabs.isEmpty ? tabs : realTabs
        guard !searchQuery.isEmpty else { return listed }
        return listed.filter {
            $0.displayTitle.localizedCaseInsensitiveContains(searchQuery)
                || $0.displayHost.localizedCaseInsensitiveContains(searchQuery)
        }
    }

    /// The count shown beside a mode's name.
    ///
    /// It matches the cards this screen draws: the pages, or the single 主页
    /// card when no page is left. The toolbar badge keeps counting pages only;
    /// that badge is about the strip, not this screen.
    private func overviewTabCount(_ mode: BrowserSessionPrivacyMode) -> Int {
        let tabs = mode == .private ? tabManager.privateTabs : tabManager.regularTabs
        let realTabs = tabs.filter { !$0.isHome }
        return realTabs.isEmpty ? (tabs.isEmpty ? 0 : 1) : realTabs.count
    }

    private var pinnedTabs: [BrowserTabState] { visibleTabs.filter(\.pinned) }
    private var unpinnedTabs: [BrowserTabState] { visibleTabs.filter { !$0.pinned } }

    var body: some View {
        // The backdrop is a background, never a ZStack sibling. A
        // `scaledToFill` picture reports its own oversized layout size back
        // up the tree — a portrait print in a landscape window asks for the
        // window's width at a portrait's height — and as a sibling it sized
        // this whole surface: the stack then laid out against that inflated
        // height, its header pushed off-screen above and the grid drawn at
        // the print's aspect instead of the screen's. A background is
        // proposed the content's size and cannot grow it.
        Group {
            if displaysPrivateTabs && isLocked {
                lockedState
            } else {
                contentStack
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background { backgroundLayer }
        .task { await prepare() }
        .sheet(isPresented: $pendingPrivateUnlock) {
            PrivateUnlockSheet(
                onUnlock: { pendingPrivateUnlock = false },
                onCancel: {
                    showPrivateTabs = false
                    pendingPrivateUnlock = false
                }
            )
        }
    }

    /// The lock setting, asked of the environment so it shares one verified
    /// state with the sidebar: verifying here also unlocks the iPad column,
    /// and a backgrounded app re-locks both at once.
    private var isLocked: Bool {
        env.requiresPrivateAuthentication
    }

    // MARK: - Background

    /// The page you came from, blurred hard under a scrim. Safari's overview
    /// does this rather than a flat fill, and the result is what makes the
    /// take-over read as "the same place, pulled back" instead of a new screen.
    private var backgroundLayer: some View {
        // The reader pins the picture to the window's size and swallows the
        // overflow: `scaledToFill` answers with the size it would like to be,
        // and a background that told its container how big to be is exactly
        // the bug this layer used to be.
        ZStack {
            AmbientBackgroundView()
            AmbientSurfaceFill(opacity: palette.visualStyle.menuVeil)
        }.ignoresSafeArea()
    }

    // MARK: - Content

    private var contentStack: some View {
        VStack(spacing: 0) {
            header
            if isSearching {
                searchField
            }
            if !pinnedTabs.isEmpty {
                pinnedRail
            }
            if unpinnedTabs.isEmpty && pinnedTabs.isEmpty {
                emptyState
            } else {
                grid
            }
        }
    }

    private var header: some View {
        VStack(spacing: 14) {
            HStack {
                Text("标签页").font(.title2.bold()).foregroundStyle(palette.primaryText)
                Spacer(minLength: 8)
                trailingButtons
            }
            HStack(spacing: 12) { modePill; Spacer(minLength: 0); overflowMenu }
        }
        .padding(.horizontal, 20).padding(.top, 12).padding(.bottom, 16)
    }

    /// The round translucent button the header's actions live in — the shape
    /// Safari's overview buttons use against the blurred page behind them.
    private func headerCircle(_ systemName: String) -> some View {
        Image(systemName: systemName)
            .font(.system(size: 14, weight: .semibold))
            .foregroundStyle(palette.primaryText)
            .frame(width: 44, height: 44)
            .overviewGlass(Circle())
    }

    /// The actions the old bottom bar carried, parked where Safari parks its
    /// own overflow: the round ellipsis at the header's leading edge.
    private var overflowMenu: some View {
        Menu {
            Button {
                // Reopen is scoped to the mode being viewed, so a private tab
                // can never be restored into the regular list.
                if tabManager.reopenLastClosedTab(privacyMode: currentMode) != nil {
                    onClose()
                }
            } label: {
                Label("重新打开关闭的标签页", systemImage: "arrow.uturn.backward")
            }
            .disabled(tabManager.recentlyClosed.allSatisfy { $0.privacyMode != currentMode })

            Button(role: .destructive) {
                withAnimation(BrowserMotion.layout(reduceMotion)) {
                    tabManager.closeAllTabs(privacyMode: currentMode)
                }
            } label: {
                Label("关闭全部标签页", systemImage: "trash")
            }
            .disabled(visibleTabs.isEmpty)
        } label: {
            HamburgerGlyph(width: 15, thickness: 1.8, spacing: 3.6)
                .foregroundStyle(palette.primaryText)
                .frame(width: 44, height: 44)
                .overviewGlass(Circle())
        }
        .accessibilityLabel("标签页操作")
    }

    private var trailingButtons: some View {
        HStack(spacing: BrowserSpacing.compact) {
            Button(action: addTab) {
                Image(systemName: "plus")
                    .font(.system(size: 17, weight: .medium))
                    .foregroundStyle(palette.primaryText)
                    .frame(width: 44, height: 44)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("新建标签页")

            Button {
                if isSearching {
                    withAnimation(BrowserMotion.layout(reduceMotion)) {
                        isSearching = false
                    }
                    searchQuery = ""
                } else {
                    withAnimation(BrowserMotion.layout(reduceMotion)) {
                        isSearching = true
                    }
                    // The field has to exist before it can take focus, so the
                    // request waits one runloop turn for the insertion.
                    DispatchQueue.main.async { searchFieldFocused = true }
                }
            } label: {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(isSearching ? palette.accent : palette.primaryText)
                    .frame(width: 44, height: 44)
                    .background(palette.accent.opacity(isSearching ? 0.2 : 0), in: Circle())
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("搜索标签页")

            Button {
                onClose()
            } label: {
                Image(systemName: "checkmark")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(palette.onAccent)
                    .frame(width: 44, height: 44)
                    .background(palette.accent, in: Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("完成")
        }
    }

    /// Mode and count in one capsule, as Safari's private indicator is. It is
    /// a menu: tapping it is how the mode switches, with the current mode
    /// check-marked in the list.
    /// Mode and count in one segmented capsule, Safari's private indicator
    /// turned into the switch itself: both modes sit visible with their own
    /// counts, and tapping the other side is the switch — no menu in between.
    private var modePill: some View {
        HStack(spacing: 4) {
            modeSegment(
                title: "普通",
                count: overviewTabCount(.regular),
                isActive: !displaysPrivateTabs
            ) {
                switchMode(to: false)
            }
            modeSegment(
                title: "无痕",
                count: overviewTabCount(.private),
                isActive: displaysPrivateTabs
            ) {
                switchMode(to: true)
            }
        }
        .padding(3)
        .overviewGlass(Capsule())
    }

    private func modeSegment(
        title: String,
        count: Int,
        isActive: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Text(title)
                Text("\(count)")
                    .monospacedDigit()
                    .opacity(0.6)
            }
            .font(.footnote)
            .fontWeight(isActive ? .semibold : .regular)
            .foregroundStyle(isActive ? palette.primaryText : palette.secondaryText)
            .padding(.horizontal, 13)
            .padding(.vertical, 7)
            .background {
                if isActive {
                    // The active side is the brighter capsule, the way
                    // Safari's own indicator reads.
                    if reduceMotion { Capsule().fill(palette.card) }
                    else { Capsule().fill(palette.card).matchedGeometryEffect(id: "mode", in: modeAnimation) }
                }
            }
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(title)标签页，\(count) 个")
    }

    private func switchMode(to isPrivate: Bool) {
        guard isPrivate != displaysPrivateTabs else { return }
        withAnimation(BrowserMotion.layout(reduceMotion)) {
            showPrivateTabs = isPrivate
            // The search was over one mode's tabs; the other mode starts
            // unfiltered and with the field closed.
            searchQuery = ""
            isSearching = false
        }
        // The system prompt is the answer to "open the private grid", so it
        // appears as the mode changes rather than waiting for a second tap on
        // the lock screen.
        if isPrivate && isLocked {
            pendingPrivateUnlock = true
        }
    }

    private var searchField: some View {
        HStack(spacing: BrowserSpacing.compact) {
            HStack(spacing: BrowserSpacing.tight) {
                Image(systemName: "magnifyingglass")
                    .font(.footnote)
                    .foregroundStyle(palette.secondaryText)
                TextField("搜索标签页", text: $searchQuery)
                    .textFieldStyle(.plain)
                    .focused($searchFieldFocused)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .submitLabel(.search)
                if !searchQuery.isEmpty {
                    Button {
                        searchQuery = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.footnote)
                            .foregroundStyle(palette.secondaryText)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("清除搜索")
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .overviewGlass(Capsule())

            Button {
                withAnimation(BrowserMotion.layout(reduceMotion)) {
                    isSearching = false
                    searchQuery = ""
                }
            } label: {
                Text("取消")
                    .font(.subheadline)
                    .foregroundStyle(palette.accent)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, BrowserSpacing.regular + 4)
        .padding(.top, BrowserSpacing.tight)
    }

    /// Pinned tabs live above the grid as compact chips, the way Safari's
    /// overview separates them from the page cards.
    private var pinnedRail: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: BrowserSpacing.tight) {
                ForEach(pinnedTabs) { tab in
                    Button {
                        activate(tab)
                    } label: {
                        HStack(spacing: BrowserSpacing.tight) {
                            if tab.privacyMode == .private { Image(systemName: "eyeglasses") }
                            else if !tab.isHome {
                                SiteIconView(
                                    host: tab.displayHost,
                                    size: 16,
                                    faviconUrl: tab.faviconUrl.isEmpty ? nil : tab.faviconUrl,
                                    allowsThirdPartyLookup: tab.privacyMode != .private
                                )
                            }
                            Text(tab.privacyMode == .private ? "无痕标签" : (tab.displayHost.isEmpty ? tab.displayTitle : tab.displayHost))
                                .font(.footnote)
                                .lineLimit(1)
                            Image(systemName: "pin.fill")
                                .font(.system(size: 9))
                                .foregroundStyle(palette.secondaryText)
                        }
                        .padding(.leading, 12)
                        .padding(.trailing, 14)
                        .padding(.vertical, 9)
                        .overviewGlass(Capsule())
                    }
                    .buttonStyle(.plain)
                    .contextMenu {
                        Button("取消固定", systemImage: "pin.slash") {
                            tabManager.setPinned(false, id: tab.id)
                        }
                        Button("关闭标签页", systemImage: "xmark", role: .destructive) {
                            withAnimation(BrowserMotion.layout(reduceMotion)) {
                                tabManager.closeTab(id: tab.id)
                            }
                        }
                    }
                }
            }
            .padding(.horizontal, BrowserSpacing.regular + 4)
        }
        .padding(.top, BrowserSpacing.tight)
    }

    private var grid: some View {
        GeometryReader { geo in
            // The reader is only consulted for two things: how many columns
            // the width can carry, and the card aspect. The width of each
            // card is NOT taken from it — cards are flexible and share the
            // HStack's width out equally, so even a measurement that is one
            // rotation behind can only change the column COUNT, never push a
            // card past the screen edge. Fixed-width cells computed from a
            // stale number were the last layout failure left.
            let minimum: CGFloat = horizontalSizeClass == .regular ? 240 : 170
            let count = max(1, Int((geo.size.width + BrowserSpacing.loose) / (minimum + BrowserSpacing.loose)))
            // Wide cards in landscape, upright ones in portrait, clamped
            // where a wide card stops reading as a page and starts reading
            // as a letterbox.
            let aspect = min(1.5, max(0.72, geo.size.width / max(geo.size.height, 1)))
            let bucket = Int((aspect * 100).rounded())

            ScrollView {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: BrowserSpacing.regular), count: count), spacing: 24) {
                    ForEach(unpinnedTabs) { tab in
                                TabCard(
                                    tab: tab,
                                    aspect: aspect,
                                    aspectBucket: bucket,
                                    isActive: tab.id == tabManager.activeTabId,
                                    blurPreview: tab.privacyMode == .private && env.settings.preferences.blurPrivateTabPreviews,
                                    homePreview: tab.id == homePreviewTabId ? homePreview : nil,
                                    onSelect: { activate(tab) },
                                    onClose: {
                                        withAnimation(BrowserMotion.layout(reduceMotion)) {
                                            tabManager.closeTab(id: tab.id)
                                        }
                                    },
                                    onPin: {
                                        tabManager.setPinned(!tab.pinned, id: tab.id)
                                    }
                                )
                        .transition(reduceMotion ? .opacity : .opacity.combined(with: .scale(scale: 0.92)))
                    }
                }
                .animation(BrowserMotion.layout(reduceMotion), value: unpinnedTabs.map(\.id))
                .padding(.horizontal, BrowserSpacing.regular + 4)
                .padding(.top, BrowserSpacing.regular - 6)
                .padding(.bottom, BrowserSpacing.loose)
            }
            // A grid shorter than the screen has nothing to scroll, and this
            // pins it to its top: no bounce, no offset, nothing for a
            // rotation to leave parked above the header.
            .scrollBounceBehavior(.basedOnSize)
        }
    }

    private var emptyState: some View {
        VStack(spacing: BrowserSpacing.compact) {
            Spacer()
            if searchQuery.isEmpty {
                Image(systemName: "square.on.square")
                    .font(.system(size: 30, weight: .light))
                    .foregroundStyle(palette.secondaryText)
                Text("没有打开的标签页")
                    .font(.subheadline)
                    .foregroundStyle(palette.secondaryText)
                Button("新建标签页") {
                    addTab()
                }
                .font(.subheadline)
                .foregroundStyle(palette.accent)
                .padding(.top, 4)
            } else {
                Text("没有匹配“\(searchQuery)”的标签页")
                    .font(.subheadline)
                    .foregroundStyle(palette.secondaryText)
                    .multilineTextAlignment(.center)
            }
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    private var lockedState: some View {
        VStack(spacing: BrowserSpacing.regular) {
            AccentGlyphBadge(systemImage: "lock.fill", size: 64, iconSize: 28)
            Text("无痕标签页已锁定")
                .font(.headline)
                .foregroundStyle(palette.primaryText)
            Text("需要验证身份才能查看无痕标签页。")
                .font(.subheadline)
                .foregroundStyle(palette.secondaryText)
                .multilineTextAlignment(.center)
            Button("解锁") { pendingPrivateUnlock = true }
                .buttonStyle(.borderedProminent)
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Actions

    private func activate(_ tab: BrowserTabState) {
        tabManager.activateTab(id: tab.id)
        onClose()
    }

    private func addTab() {
        let tab = tabManager.createTab(
            privacyMode: currentMode,
            openSource: .user
        )
        tabManager.activateTab(id: tab.id)
        onClose()
    }

    private func prepare() async {
        if !didSyncMode {
            didSyncMode = true
            // The overview opens onto the mode of the tab you came from, the
            // way Safari's does, rather than always landing on regular.
            showPrivateTabs = tabManager.activeTab?.privacyMode == .private
        }
    }

}

/// One tab card: the page's own screenshot with its title printed underneath
/// and the close button riding the card's top-right corner, half off the edge
/// — the shape Safari's overview uses, which is what this one is modelled on.
private struct TabCard: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.browserPalette) private var palette

    var tab: BrowserTabState
    var aspect: CGFloat
    /// The shape bucket the print is taken for, in hundredths. When it moves —
    /// the device rotated — the task re-runs and the print is taken again: a
    /// portrait print cover-cropped into a landscape card is a picture of the
    /// wrong slice of the page, which reads as the card being cut apart even
    /// when its frame is exactly right.
    var aspectBucket: Int
    var isActive: Bool
    var blurPreview: Bool
    var homePreview: UIImage?
    var onSelect: () -> Void
    var onClose: () -> Void
    var onPin: () -> Void

    /// The page's picture, taken from the live web view. A cold tab has no
    /// web view to ask and keeps its placeholder until it has been opened
    /// once.
    @State private var snapshot: UIImage?

    var body: some View {
        VStack(spacing: BrowserSpacing.tight) {
            ZStack(alignment: .topTrailing) {
                Button(action: onSelect) { cardFace }
                    .buttonStyle(JellyPressButtonStyle(pressedScale: 0.97, pressedOpacity: 0.92))

                closeButton
            }
            .shadow(color: palette.visualStyle.resolvedElevation(.card).shadowColor(for: colorScheme),
                    radius: palette.visualStyle.resolvedElevation(.card).radius,
                    y: palette.visualStyle.resolvedElevation(.card).y)

            // A private card carries no caption. Its title and host are the
            // one part of the card a blur cannot cover — the picture is
            // smeared, but the line underneath would still print the page's
            // name for anyone glancing at the screen. The card keeps its
            // silhouette and its close button; the label stays on the
            // accessibility element for VoiceOver.
            if tab.privacyMode != .private {
                HStack(spacing: 5) {
                    // The start page has no site to identify, so its title stands
                    // alone — a letter swatch in front of 主页 is noise.
                    if !tab.isHome {
                        SiteIconView(
                            host: tab.displayHost,
                            size: 15,
                            faviconUrl: tab.faviconUrl.isEmpty ? nil : tab.faviconUrl,
                            allowsThirdPartyLookup: true
                        )
                    }
                    Text(tab.displayTitle)
                        .font(.caption)
                        .lineLimit(1)
                        .foregroundStyle(palette.primaryText)
                }
                .frame(maxWidth: .infinity)
                .onTapGesture(perform: onSelect)
            }
        }
        .contentShape(Rectangle())
        .contextMenu {
            Button(tab.pinned ? "取消固定" : "固定标签页", systemImage: tab.pinned ? "pin.slash" : "pin", action: onPin)
            Button("关闭标签页", systemImage: "xmark", role: .destructive, action: onClose)
        }
        .task(id: aspectBucket) {
            guard !tab.isHome else { return }
            // The last kept picture paints first, so a live tab does not
            // flash its icon while the fresh print is being taken.
            if snapshot == nil {
                snapshot = await env.tabManager.previewImage(for: tab.id)
            }
            // Let the overview finish its entrance before requesting a fresh WebKit print.
            try? await Task.sleep(nanoseconds: 450_000_000)
            guard !Task.isCancelled else { return }
            if let fresh = await takeSnapshot(), !Task.isCancelled { snapshot = fresh }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(tab.displayTitle)
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { onSelect() }
        .accessibilityAction(named: Text("关闭标签页")) { onClose() }
    }

    /// The card's picture in a frame that owns its aspect outright.
    ///
    /// `Color.clear` takes the ratio-fitted size the grid proposes and the
    /// print overflows inside an overlay, where the clip cuts it off. Placing
    /// a `scaledToFill` image directly in the chain instead lets it report its
    /// own oversized height back up: landscape prints then bled sideways past
    /// the card and portrait ones grew taller than the home placeholder beside
    /// them, and no card matched its neighbours.
    @ViewBuilder
    private var cardFace: some View {
        Color.clear
            .aspectRatio(aspect, contentMode: .fit)
            .overlay {
                GeometryReader { geo in
                    thumbnail.frame(width: geo.size.width, height: geo.size.height, alignment: .top).clipped()
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: palette.visualStyle.cardRadius, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: palette.visualStyle.cardRadius, style: .continuous)
                    .strokeBorder(
                        isActive ? palette.accent : palette.cardStroke,
                        lineWidth: isActive ? 2 : 0.5
                    )
                    .allowsHitTesting(false)
            }
    }

    /// The card's picture: the page itself where one exists, and a quiet
    /// placeholder where none does yet — the start page's house on the home
    /// surface, the site's icon on a tab that has never been opened here.
    ///
    /// The private blur lives on the picture itself, *inside* the card's clip:
    /// the smeared content is cut off at the rounded rectangle, so the card
    /// keeps a crisp silhouette and border while what is inside it stops being
    /// a picture of anything.
    @ViewBuilder
    private var thumbnail: some View {
        if !tab.isHome, let snapshot {
            Image(uiImage: snapshot)
                .resizable()
                .scaledToFill()
                .blur(radius: blurPreview ? Self.previewBlurRadius : 0)
        } else if tab.isHome, let homePreview {
            // The real home surface, printed before the overview covered it.
            // Nothing here is invented: the user sees their own favourites,
            // their own recently-closed list and their own background.
            Image(uiImage: homePreview)
                .resizable()
                .scaledToFill()
                .blur(radius: blurPreview ? Self.previewBlurRadius : 0)
        } else {
            ZStack {
                palette.surface
                if tab.isHome {
                    HomeTabPlaceholder(isPrivate: tab.privacyMode == .private)
                } else {
                    SiteIconView(
                        host: tab.displayHost,
                        size: 32,
                        allowsThirdPartyLookup: tab.privacyMode != .private
                    )
                }
            }
        }
    }

    /// How far a private preview is smeared. The bar the setting has to meet
    /// is "cannot tell what the page is": five points softened the shapes but
    /// left the layout legible, which is a blur the page survives. Thirty
    /// points destroys the picture outright and leaves only the page's palette
    /// — the same information a colour swatch would carry.
    static let previewBlurRadius: CGFloat = 30

    /// The live page's own picture, or the one kept for it when the tab is
    /// cold — a tab past the live-view cap, or one whose view is not the one
    /// in the window, has no view this can honestly ask.
    ///
    /// Only the hosted view is snapshotted: the pool's background web views
    /// are out of the window, and this WebKit answers an off-screen view with
    /// a blank frame — which the card would then show in place of a picture
    /// it already had.
    private func takeSnapshot() async -> UIImage? {
        guard let webView = env.tabManager.webView(for: tab.id),
              webView.window != nil else {
            return await env.tabManager.previewImage(for: tab.id)
        }
        let fresh: UIImage? = await withCheckedContinuation { continuation in
            let config = WKSnapshotConfiguration(); config.snapshotWidth = 420
            webView.takeSnapshot(with: config) { image, _ in
                continuation.resume(returning: image)
            }
        }
        if let fresh {
            env.tabManager.storePreview(fresh, for: tab.id)
            return fresh
        }
        return await env.tabManager.previewImage(for: tab.id)
    }

    private var closeButton: some View {
        Button(action: onClose) {
            Image(systemName: "xmark")
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(palette.primaryText)
                .frame(width: 30, height: 30)
                .background(palette.card, in: Circle())
                .overlay {
                    Circle().strokeBorder(palette.cardStroke, lineWidth: 0.5)
                }
                .frame(width: 44, height: 44)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .offset(x: 9, y: -9)
        .accessibilityLabel("关闭标签页")
    }
}

/// The identity check shown before the private tab list.
///
/// `LAContext` is what gates the private list, so the biometric prompt a user
/// sees is the standard system one.
private struct PrivateUnlockSheet: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.browserPalette) private var palette

    var onUnlock: () -> Void
    var onCancel: () -> Void

    @State private var errorMessage: String?
    @State private var isVerifying = false

    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "lock.shield")
                .font(.system(size: 32))
                .foregroundStyle(palette.accent)
                .frame(width: 62, height: 62)
                .background(palette.accent.opacity(0.12), in: Circle())
                .padding(.top, 34)

            Text("验证身份")
                .font(.headline)
                .foregroundStyle(palette.primaryText)

            if let errorMessage {
                Text(errorMessage)
                    .font(.footnote)
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 30)
            }

            Spacer()

            VStack(spacing: 10) {
                Button {
                    Task { await authenticate() }
                } label: {
                    HStack(spacing: 8) {
                        if isVerifying {
                            ProgressView().tint(.white)
                        }
                        Text(isVerifying ? "验证中…" : "解锁")
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .disabled(isVerifying)

                Button("取消") { onCancel() }
                    .frame(maxWidth: .infinity)
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 28)
        }
        .background(palette.surface)
        .presentationDetents([.height(320)])
        .task { await authenticate() }
    }

    /// One shared check with the sidebar and every 无痕 entry point. The
    /// sheet is only the surface that carries the error copy; the prompt itself
    /// is the system's Face ID / Touch ID / passcode sheet.
    private func authenticate() async {
        guard !isVerifying else { return }
        isVerifying = true
        defer { isVerifying = false }

        switch await env.requestPrivateAccess(reason: "查看无痕标签页") {
        case .granted:
            errorMessage = nil
            onUnlock()
        case .unavailable:
            errorMessage = "此设备未设置密码或生物识别，无法验证身份。"
        case .cancelled:
            errorMessage = "验证已取消。可以重试，或退出无痕标签页。"
        case .failed:
            errorMessage = "验证未通过。"
        }
    }
}


// MARK: - Overview glass

/// The one translucent treatment every control on the overview wears.
///
/// The mode pill, the header circles, the search field and the pinned chips
/// used to be raw `.ultraThinMaterial` fills with no edge. Against a bright
/// page print the material alone has no silhouette, so the controls read as
/// islands of blur. The hairline gives each one the edge a piece of glass gets
/// from its own rim, and using one helper keeps their radii and edges from
/// drifting apart.
private struct OverviewGlass<S: InsettableShape>: ViewModifier {
    @Environment(\.browserReduceTransparency) private var reduceTransparency
    @Environment(\.browserPalette) private var palette

    var shape: S

    func body(content: Content) -> some View {
        content
            .background {
                // The system's reduced-transparency setting must not turn the
                // overview's controls into washed-out smears over the page
                // print; a palette control fill keeps their silhouette.
                if reduceTransparency || palette.visualStyle.surface == .paper {
                    shape.fill(palette.card)
                } else {
                    shape.fill(palette.visualStyle.cardMaterial)
                }
            }
            .overlay {
                shape.strokeBorder(
                    palette.cardStroke,
                    lineWidth: 0.5
                )
                .allowsHitTesting(false)
            }
    }
}

private extension View {
    func overviewGlass<S: InsettableShape>(_ shape: S) -> some View {
        modifier(OverviewGlass(shape: shape))
    }
}


/// The card's honest fallback when there is no print of the home.
///
/// A capture can fail, for example before the home has rendered. The fallback
/// shows the mode and nothing else; no tiles, names or rows are invented.
private struct HomeTabPlaceholder: View {
    var isPrivate: Bool
    @Environment(\.browserPalette) private var palette

    var body: some View {
        ZStack {
            palette.surface
            VStack(spacing: 7) {
                Image(systemName: isPrivate ? "eyeglasses" : "house")
                    .font(.system(size: 22, weight: .medium))
                    .foregroundStyle(palette.secondaryText.opacity(0.55))
                Text(isPrivate ? "无痕主页" : "主页")
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(palette.secondaryText.opacity(0.7))
            }
        }
    }
}
