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
    @Environment(\.dismiss) private var dismiss

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
    private var visibleTabs: [BrowserTabState] {
        let tabs = showPrivateTabs ? tabManager.privateTabs : tabManager.regularTabs
        guard !searchQuery.isEmpty else { return tabs }
        return tabs.filter {
            $0.displayTitle.localizedCaseInsensitiveContains(searchQuery)
                || $0.displayHost.localizedCaseInsensitiveContains(searchQuery)
        }
    }

    private var pinnedTabs: [BrowserTabState] { visibleTabs.filter(\.pinned) }
    private var unpinnedTabs: [BrowserTabState] { visibleTabs.filter { !$0.pinned } }

    /// Safari's cards are large — three across on a portrait iPad, four in
    /// landscape — so the regular width sizes for that. A compact width takes
    /// the smaller minimum, which is what puts two columns on a phone.
    private var columns: [GridItem] {
        [GridItem(
            .adaptive(
                minimum: horizontalSizeClass == .regular ? 240 : 170,
                maximum: 320
            ),
            spacing: BrowserSpacing.regular
        )]
    }

    var body: some View {
        ZStack {
            backgroundLayer

            if showPrivateTabs && isLocked && !isPrivateUnlocked {
                lockedState
            } else {
                contentStack
            }
        }
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
        ZStack {
            if let backgroundPrint {
                Image(uiImage: backgroundPrint)
                    .resizable()
                    .scaledToFill()
                    .blur(radius: 32)
                    .overlay(palette.chromeBackground.opacity(0.72))
                    .scaleEffect(1.2)
                    .ignoresSafeArea()
            } else {
                LinearGradient(
                    colors: [palette.chromeBackground, palette.surface],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .ignoresSafeArea()
            }
        }
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
                    dismiss()
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
                dismiss()
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
    private var modePill: some View {
        Menu {
            Button {
                withAnimation(.snappy(duration: 0.25)) { showPrivateTabs = false }
            } label: {
                if showPrivateTabs {
                    Label("普通标签页", systemImage: "checkmark")
                } else {
                    Text("普通标签页")
                }
            }

            Button {
                withAnimation(.snappy(duration: 0.25)) { showPrivateTabs = true }
            } label: {
                if showPrivateTabs {
                    Text("无痕标签页")
                } else {
                    Label("无痕标签页", systemImage: "checkmark")
                }
            }
        } label: {
            HStack(spacing: 8) {
                if showPrivateTabs {
                    Text("无痕浏览")
                        .fontWeight(.semibold)
                    Capsule()
                        .fill(palette.primaryText.opacity(0.3))
                        .frame(width: 1, height: 12)
                }
                Text("\(visibleTabs.count) 个标签页")
                    .monospacedDigit()
            }
            .font(.footnote)
            .foregroundStyle(palette.primaryText)
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .background(.ultraThinMaterial, in: Capsule())
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
            // The card's shape is the screen's own shape, clamped: wide cards
            // in landscape, upright ones in portrait. The ceiling sits where
            // Safari's landscape cards do — past it a wide card stops reading
            // as a page and starts reading as a letterbox.
            let aspect = min(1.5, max(0.72, geo.size.width / max(geo.size.height, 1)))

            ScrollView {
                LazyVGrid(columns: columns, spacing: BrowserSpacing.loose) {
                    ForEach(unpinnedTabs) { tab in
                        TabCard(
                            tab: tab,
                            aspect: aspect,
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
                    }
                }
                .padding(.horizontal, BrowserSpacing.regular + 4)
                .padding(.top, BrowserSpacing.regular - 6)
                .padding(.bottom, BrowserSpacing.loose)
            }
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
        dismiss()
    }

    private func addTab() {
        let tab = tabManager.createTab(
            privacyMode: currentMode,
            openSource: .user
        )
        tabManager.activateTab(id: tab.id)
        dismiss()
    }

    private func prepare() async {
        if !didSyncMode {
            didSyncMode = true
            // The overview opens onto the mode of the tab you came from, the
            // way Safari's does, rather than always landing on regular.
            showPrivateTabs = tabManager.activeTab?.privacyMode == .private
        }
        // The print behind the scrim is the page you came from — unless that
        // page is private and the lock is on: a blurred private page is still
        // a private page, and the lock's job is exactly to keep it off screen.
        guard let active = tabManager.activeTab, !active.isHome,
              !(active.privacyMode == .private && isLocked)
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
    var isActive: Bool
    var blurPreview: Bool
    var onSelect: () -> Void
    var onClose: () -> Void
    var onPin: () -> Void

    /// The page's picture, taken once per card appearance from the live web
    /// view. A cold tab has no web view to ask and keeps its placeholder
    /// until it has been opened once; the overview's lifetime bounds the cache.
    @State private var snapshot: UIImage?

    var body: some View {
        VStack(spacing: BrowserSpacing.tight) {
            ZStack(alignment: .topTrailing) {
                cardFace

                closeButton
            }
            .shadow(color: .black.opacity(0.35), radius: 10, y: 4)
            .blur(radius: blurPreview ? 5 : 0)

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
            .blur(radius: blurPreview ? 3 : 0)
        }
        .contentShape(Rectangle())
        .onTapGesture(perform: onSelect)
        .contextMenu {
            Button(tab.pinned ? "取消固定" : "固定标签页", systemImage: tab.pinned ? "pin.slash" : "pin", action: onPin)
            Button("关闭标签页", systemImage: "xmark", role: .destructive, action: onClose)
        }
        .task(id: tab.id) {
            guard snapshot == nil, !tab.isHome else { return }
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
    @ViewBuilder
    private var thumbnail: some View {
        if let snapshot {
            Image(uiImage: snapshot)
                .resizable()
                .scaledToFill()
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
