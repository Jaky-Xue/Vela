//
//  TabsOverviewView.swift
//  Vela
//
//  The tab switcher, styled on Safari's iPad overview: a full-screen take-over
//  rather than a panel — a blurred print of the page you came from behind a
//  scrim, round header buttons around a mode-and-count pill, pinned tabs as a
//  chip rail, and a grid of page cards with their titles printed underneath.
//
//  The card's shape answers to the screen's own aspect — wide in landscape,
//  upright in portrait — which is the behaviour Safari's overview has and the
//  reason the grid reads as "the pages, shrunk" instead of a wall of tiles.
//
//  The surface pins itself to the dark appearance. Everything on screen sits
//  on the scrim over the blurred page, and a scrim that tracked the user's
//  palette would need re-tuning per palette to hold contrast — pinning dark
//  buys one contrast that always holds.
//
//  The privacy split is exact: regular and private tabs never appear in the
//  same list, and the private grid is what the lock setting gates.
//

import SwiftUI
import UIKit
import LocalAuthentication
import WebKit

struct TabsOverviewView: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.browserPalette) private var palette

    /// Closes the overview. The overview is a layer in the shell's own
    /// hierarchy rather than a presented controller, so there is no
    /// presentation to dismiss — the shell owns the flag, and hands the way
    /// out down here.
    var onClose: () -> Void

    @State private var showPrivateTabs = false
    @State private var didSyncMode = false
    @State private var isPrivateUnlocked = false
    @State private var pendingPrivateUnlock = false
    @State private var isSearching = false
    @State private var searchQuery = ""
    @State private var backgroundPrint: UIImage?
    @FocusState private var searchFieldFocused: Bool
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    private var tabManager: TabManager { env.tabManager }

    private var currentMode: BrowserSessionPrivacyMode {
        showPrivateTabs ? .private : .regular
    }

    /// The tabs of the mode on screen, narrowed by the search field when it
    /// has text. The pinned rail and the grid are two views of this one list,
    /// so a search reaches into both.
    ///
    /// The home tab is the strip's filler, not one of its cards: while real
    /// tabs exist it does not appear here, and the grid shows pages only.
    /// What remains once the real tabs are gone is exactly the filler — the
    /// one card a closing action leaves behind.
    private var visibleTabs: [BrowserTabState] {
        let tabs = showPrivateTabs ? tabManager.privateTabs : tabManager.regularTabs
        let realTabs = tabs.filter { !$0.isHome }
        let listed = realTabs.isEmpty ? tabs : realTabs
        guard !searchQuery.isEmpty else { return listed }
        return listed.filter {
            $0.displayTitle.localizedCaseInsensitiveContains(searchQuery)
                || $0.displayHost.localizedCaseInsensitiveContains(searchQuery)
        }
    }

    private var pinnedTabs: [BrowserTabState] { visibleTabs.filter(\.pinned) }
    private var unpinnedTabs: [BrowserTabState] { visibleTabs.filter { !$0.pinned } }

    /// One chunk of the card list: the cards that share a row. The column
    /// count is part of the identity so a rotation that changes it re-creates
    /// the rows outright rather than asking SwiftUI to re-diff a changed row.
    private struct TabRow: Identifiable {
        let count: Int
        let tabs: [BrowserTabState]
        var id: String { "\(count)-\(tabs.map(\.id).joined(separator: "-"))" }
    }

    private func gridRows(count: Int) -> [TabRow] {
        stride(from: 0, to: unpinnedTabs.count, by: count).map { start in
            TabRow(count: count, tabs: Array(unpinnedTabs[start..<min(start + count, unpinnedTabs.count)]))
        }
    }

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
            if showPrivateTabs && isLocked && !isPrivateUnlocked {
                lockedState
            } else {
                contentStack
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background { backgroundLayer }
        .environment(\.colorScheme, .dark)
        .task { await prepare() }
        .onChange(of: showPrivateTabs) { _, isPrivate in
            // Entering the private grid is what the lock gates, so the unlocked
            // flag is cleared on the way out.
            if !isPrivate {
                isPrivateUnlocked = false
            } else if isLocked {
                isPrivateUnlocked = false
            }
        }
        .sheet(isPresented: $pendingPrivateUnlock) {
            PrivateUnlockSheet(
                onUnlock: {
                    isPrivateUnlocked = true
                    pendingPrivateUnlock = false
                },
                onCancel: {
                    showPrivateTabs = false
                    pendingPrivateUnlock = false
                }
            )
        }
    }

    /// setting, and it only applies to the private grid.
    private var isLocked: Bool {
        env.settings.preferences.lockPrivateTabs
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
        GeometryReader { geo in
            ZStack {
                if let backgroundPrint {
                    Image(uiImage: backgroundPrint)
                        .resizable()
                        .scaledToFill()
                        .frame(width: geo.size.width, height: geo.size.height)
                        .blur(radius: 32)
                        .overlay(palette.chromeBackground.opacity(0.72))
                        .scaleEffect(1.2)
                        .clipped()
                } else {
                    LinearGradient(
                        colors: [palette.chromeBackground, palette.surface],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
            .clipped()
        }
        .ignoresSafeArea()
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
        ZStack {
            // The pill is centred on the screen, not on the leftover space
            // between the two button clusters, which is why it overlays the
            // row rather than sitting in it.
            modePill

            HStack(spacing: BrowserSpacing.compact) {
                overflowMenu
                Spacer()
                trailingButtons
            }
        }
        .padding(.horizontal, BrowserSpacing.regular + 4)
        .padding(.top, BrowserSpacing.compact)
        .padding(.bottom, BrowserSpacing.tight)
    }

    /// The round translucent button the header's actions live in — the shape
    /// Safari's overview buttons use against the blurred page behind them.
    private func headerCircle(_ systemName: String) -> some View {
        Image(systemName: systemName)
            .font(.system(size: 14, weight: .semibold))
            .foregroundStyle(palette.primaryText)
            .frame(width: 36, height: 36)
            .background(.ultraThinMaterial, in: Circle())
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
                withAnimation(.snappy(duration: 0.25)) {
                    tabManager.closeAllTabs(privacyMode: currentMode)
                }
            } label: {
                Label("关闭全部标签页", systemImage: "trash")
            }
            .disabled(visibleTabs.isEmpty)
        } label: {
            headerCircle("ellipsis")
        }
        .accessibilityLabel("标签页操作")
    }

    private var trailingButtons: some View {
        HStack(spacing: BrowserSpacing.compact) {
            Button(action: addTab) {
                Image(systemName: "plus")
                    .font(.system(size: 17, weight: .medium))
                    .foregroundStyle(palette.primaryText)
                    .frame(width: 36, height: 36)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("新建标签页")

            Button {
                if isSearching {
                    withAnimation(.snappy(duration: 0.2)) {
                        isSearching = false
                    }
                    searchQuery = ""
                } else {
                    withAnimation(.snappy(duration: 0.2)) {
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
                    .frame(width: 36, height: 36)
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
                    .frame(width: 36, height: 36)
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
                count: tabManager.displayedTabCount(privacyMode: .regular),
                isActive: !showPrivateTabs
            ) {
                switchMode(to: false)
            }
            modeSegment(
                title: "无痕",
                count: tabManager.displayedTabCount(privacyMode: .private),
                isActive: showPrivateTabs
            ) {
                switchMode(to: true)
            }
        }
        .padding(3)
        .background(.ultraThinMaterial, in: Capsule())
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
                    Capsule().fill(palette.primaryText.opacity(0.15))
                }
            }
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(title)标签页，\(count) 个")
    }

    private func switchMode(to isPrivate: Bool) {
        guard isPrivate != showPrivateTabs else { return }
        withAnimation(.snappy(duration: 0.25)) {
            showPrivateTabs = isPrivate
            // The search was over one mode's tabs; the other mode starts
            // unfiltered and with the field closed.
            searchQuery = ""
            isSearching = false
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
            .background(.ultraThinMaterial, in: Capsule())

            Button {
                withAnimation(.snappy(duration: 0.2)) {
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
                            if !tab.isHome {
                                SiteIconView(
                                    host: tab.displayHost,
                                    size: 16,
                                    faviconUrl: tab.faviconUrl.isEmpty ? nil : tab.faviconUrl
                                )
                            }
                            Text(tab.displayHost.isEmpty ? tab.displayTitle : tab.displayHost)
                                .font(.footnote)
                                .lineLimit(1)
                            Image(systemName: "pin.fill")
                                .font(.system(size: 9))
                                .foregroundStyle(palette.secondaryText)
                        }
                        .padding(.leading, 12)
                        .padding(.trailing, 14)
                        .padding(.vertical, 9)
                        .background(.ultraThinMaterial, in: Capsule())
                    }
                    .buttonStyle(.plain)
                    .contextMenu {
                        Button("取消固定", systemImage: "pin.slash") {
                            tabManager.setPinned(false, id: tab.id)
                        }
                        Button("关闭标签页", systemImage: "xmark", role: .destructive) {
                            withAnimation(.snappy(duration: 0.25)) {
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
                VStack(spacing: BrowserSpacing.loose) {
                    ForEach(gridRows(count: count)) { row in
                        HStack(alignment: .top, spacing: BrowserSpacing.loose) {
                            ForEach(row.tabs) { tab in
                                TabCard(
                                    tab: tab,
                                    aspect: aspect,
                                    aspectBucket: bucket,
                                    isActive: tab.id == tabManager.activeTabId,
                                    blurPreview: tab.privacyMode == .private && env.settings.preferences.blurPrivateTabPreviews,
                                    onSelect: { activate(tab) },
                                    onClose: {
                                        withAnimation(.snappy(duration: 0.25)) {
                                            tabManager.closeTab(id: tab.id)
                                        }
                                    },
                                    onPin: {
                                        tabManager.setPinned(!tab.pinned, id: tab.id)
                                    }
                                )
                                .frame(maxWidth: .infinity)
                            }
                            // The tail row's empty slots, so its cards keep
                            // the width a full row would give them instead of
                            // stretching wide across the leftover space.
                            ForEach(0..<max(0, count - row.tabs.count), id: \.self) { _ in
                                Color.clear
                                    .frame(height: 0)
                                    .frame(maxWidth: .infinity)
                            }
                        }
                    }
                }
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
            Image(systemName: "lock.fill")
                .font(.system(size: 34))
                .foregroundStyle(palette.accent)
                .frame(width: 64, height: 64)
                .background(palette.accent.opacity(0.12), in: Circle())
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
        // The print behind the scrim is the page you came from — unless that
        // page is private. 无痕模糊 is a blur of the tab cards, and a blurred
        // print of a private page stretched across the whole surface is not a
        // card blur: it is the private page itself, on screen, at whatever
        // detail thirty-two points of blur still leave. The gradient stands in
        // for it. (The lock's stricter rule — no private page anywhere, cards
        // included — sits on top of this one.)
        guard let active = tabManager.activeTab, !active.isHome,
              active.privacyMode != .private
        else { return }
        backgroundPrint = await takeSnapshot(of: active.id)
    }

    private func takeSnapshot(of tabId: String) async -> UIImage? {
        guard let webView = tabManager.webView(for: tabId) else { return nil }
        return await withCheckedContinuation { continuation in
            webView.takeSnapshot(with: nil) { image, _ in
                continuation.resume(returning: image)
            }
        }
    }
}

/// One tab card: the page's own screenshot with its title printed underneath
/// and the close button riding the card's top-right corner, half off the edge
/// — the shape Safari's overview uses, which is what this one is modelled on.
private struct TabCard: View {
    @Environment(AppEnvironment.self) private var env
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
                cardFace

                closeButton
            }
            .shadow(color: .black.opacity(0.35), radius: 10, y: 4)

            HStack(spacing: 5) {
                // The start page has no site to identify, so its title stands
                // alone — a letter swatch in front of 主页 is noise.
                if !tab.isHome {
                    SiteIconView(
                        host: tab.displayHost,
                        size: 15,
                        faviconUrl: tab.faviconUrl.isEmpty ? nil : tab.faviconUrl
                    )
                }
                Text(tab.displayTitle)
                    .font(.caption)
                    .lineLimit(1)
                    .foregroundStyle(palette.primaryText)
            }
            .frame(maxWidth: .infinity)
        }
        .contentShape(Rectangle())
        .onTapGesture(perform: onSelect)
        .contextMenu {
            Button(tab.pinned ? "取消固定" : "固定标签页", systemImage: tab.pinned ? "pin.slash" : "pin", action: onPin)
            Button("关闭标签页", systemImage: "xmark", role: .destructive, action: onClose)
        }
        .task(id: aspectBucket) {
            guard !tab.isHome else { return }
            snapshot = await takeSnapshot()
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(tab.displayTitle)
        .accessibilityAddTraits(.isButton)
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
            .overlay { thumbnail }
            .clipShape(RoundedRectangle(cornerRadius: 15, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 15, style: .continuous)
                    .strokeBorder(
                        isActive ? palette.accent : .white.opacity(0.16),
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
        if let snapshot {
            Image(uiImage: snapshot)
                .resizable()
                .scaledToFill()
                .blur(radius: blurPreview ? Self.previewBlurRadius : 0)
        } else {
            ZStack {
                palette.surface
                if tab.isHome {
                    Image(systemName: "house")
                        .font(.system(size: 24))
                        .foregroundStyle(palette.secondaryText.opacity(0.45))
                } else {
                    SiteIconView(host: tab.displayHost, size: 32)
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

    /// The live page's own picture.
    private func takeSnapshot() async -> UIImage? {
        guard let webView = env.tabManager.webView(for: tab.id) else { return nil }
        return await withCheckedContinuation { continuation in
            webView.takeSnapshot(with: nil) { image, _ in
                continuation.resume(returning: image)
            }
        }
    }

    private var closeButton: some View {
        Button(action: onClose) {
            Image(systemName: "xmark")
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(.white.opacity(0.92))
                .frame(width: 27, height: 27)
                .background(Color(white: 0.14).opacity(0.92), in: Circle())
                .overlay {
                    Circle().strokeBorder(.white.opacity(0.22), lineWidth: 0.5)
                }
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
    @Environment(\.browserPalette) private var palette

    var onUnlock: () -> Void
    var onCancel: () -> Void

    @State private var errorMessage: String?

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
                Button("解锁") {
                    Task { await authenticate() }
                }
                .buttonStyle(.borderedProminent)
                .frame(maxWidth: .infinity)

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

    private func authenticate() async {
        let context = LAContext()
        var error: NSError?
        // `deviceOwnerAuthentication` falls back to the passcode when biometrics
        // are unavailable, which matters on a device with no enrolled face or
        // fingerprint — a biometric-only policy would lock the user out of their
        // own tabs.
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else {
            errorMessage = "此设备未设置密码或生物识别，无法验证身份。"
            return
        }
        do {
            let success = try await context.evaluatePolicy(
                .deviceOwnerAuthentication,
                localizedReason: "查看无痕标签页"
            )
            if success { onUnlock() }
        } catch {
            errorMessage = "验证未通过。"
        }
    }
}
