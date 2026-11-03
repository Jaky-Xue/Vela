//
//  BrowserSidebarView.swift
//
//  Vela
//
//  The iPad layout's tab drawer: a mode switch, a search that opens on demand
//  and the open tabs, in a floating glass panel.
//
//  Safari's iPad sidebar is a rounded sheet that slides in over the page; this
//  is the same shape and the same motion. The panel supplies its own glass, so
//  this view paints no background at all — a second material here would be a
//  blurred layer inside a blurred layer.
//
//  The header is deliberately wordless. The drawer's subject is the tabs
//  below it, and a title row, a two-word segmented control and a permanent
//  search placeholder were three lines of text competing with the one list
//  the user opened. Mode is two glyphs, search is a control that unfolds
//  into a field, and the only words left are the tab titles themselves.
//

import SwiftUI

struct BrowserSidebarView: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.browserPalette) private var palette

    var onClose: (() -> Void)? = nil

    @State private var mode: BrowserSessionPrivacyMode = .regular
    @State private var searchQuery = ""
    @State private var isSearching = false
    @FocusState private var searchFocused: Bool

    private var tabs: [BrowserTabState] {
        mode == .private ? env.tabManager.privateTabs : env.tabManager.regularTabs
    }

    /// The tabs narrowed by the drawer's search field.
    private var visibleTabs: [BrowserTabState] {
        guard !searchQuery.isEmpty else { return tabs }
        return tabs.filter {
            $0.displayTitle.localizedCaseInsensitiveContains(searchQuery)
                || $0.displayHost.localizedCaseInsensitiveContains(searchQuery)
        }
    }

    /// A private column whose identity check has not been passed shows the
    /// lock instead of the list. The sidebar is a door to 无痕 content just as
    /// the phone overview is, so it asks the same question rather than being
    /// the one surface that opens without it.
    private var isLocked: Bool {
        mode == .private && env.requiresPrivateAuthentication
    }

    var body: some View {
        VStack(spacing: 0) {
            header

            if isSearching {
                searchField
                    .padding(.horizontal, 12)
                    .padding(.bottom, 8)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }

            tabList
        }
        .animation(.snappy(duration: 0.22), value: isSearching)
        .onAppear {
            mode = env.tabManager.activeTab?.privacyMode ?? .regular
        }
        .onChange(of: env.tabManager.activeTabId) { _, _ in
            if let active = env.tabManager.activeTab {
                mode = active.privacyMode
            }
        }
        .onChange(of: isSearching) { _, searching in
            if searching {
                // The field is inserted in the same frame the button is
                // tapped; focusing before it exists leaves the keyboard down.
                Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(60))
                    searchFocused = true
                }
            } else {
                searchFocused = false
                searchQuery = ""
            }
        }
    }

    // MARK: - Header

    /// Mode on the leading edge, actions on the trailing one: the switch says
    /// which list this is, and search, new tab and close are what the user
    /// does to it. Two groups, one row — not a title, a switch, a search box
    /// and two circles stacked down the panel.
    private var header: some View {
        HStack(spacing: 8) {
            modeSwitch

            Spacer(minLength: 0)

            headerButton(
                symbol: "magnifyingglass",
                label: isSearching ? "关闭搜索" : "搜索标签页",
                isActive: isSearching
            ) {
                isSearching.toggle()
            }

            headerButton(symbol: "plus", label: "新建标签页") {
                createTab()
            }

            if let onClose {
                headerButton(symbol: "xmark", label: "收起侧边栏", action: onClose)
            }
        }
        .padding(.horizontal, 12)
        .padding(.top, 10)
        .padding(.bottom, 8)
    }

    /// The 无痕 switch, as two glyphs in one capsule.
    ///
    /// The states are the drawer's two columns, so the control reads as a
    /// place rather than as a setting: the selected half is filled, the other
    /// is quiet ink. A two-word segmented control carried the same meaning in
    /// twice the width and twice the text.
    private var modeSwitch: some View {
        HStack(spacing: 2) {
            modeButton(.regular, symbol: "globe", label: "普通标签页")
            modeButton(.private, symbol: "eyeglasses", label: "无痕标签页")
        }
        .padding(3)
        .background(palette.controlFill.opacity(0.55), in: Capsule())
    }

    private func modeButton(
        _ target: BrowserSessionPrivacyMode,
        symbol: String,
        label: String
    ) -> some View {
        let selected = mode == target
        return Button {
            selectMode(target)
        } label: {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(selected ? palette.onAccent : palette.secondaryText)
                .frame(width: 34, height: 26)
                .background(selected ? palette.accent : Color.clear, in: Capsule())
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
        .accessibilityAddTraits(selected ? .isSelected : AccessibilityTraits())
    }

    private func headerButton(
        symbol: String,
        label: String,
        isActive: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(isActive ? palette.accent : palette.primaryText)
                .frame(width: 30, height: 30)
                .background(
                    isActive ? palette.accent.opacity(0.16) : palette.controlFill.opacity(0.6),
                    in: Circle()
                )
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }

    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(palette.secondaryText)

            TextField("搜索标签页", text: $searchQuery)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .focused($searchFocused)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .submitLabel(.search)

            if !searchQuery.isEmpty {
                Button {
                    searchQuery = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(palette.secondaryText)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("清除搜索")
            }
        }
        .padding(.horizontal, 10)
        .frame(height: 32)
        .background(palette.controlFill.opacity(0.5), in: Capsule())
    }

    // MARK: - Tabs

    private var tabList: some View {
        ScrollView {
            VStack(spacing: 3) {
                if isLocked {
                    lockedState
                } else if visibleTabs.isEmpty {
                    emptyState
                } else {
                    ForEach(visibleTabs) { tab in
                        tabRow(tab)
                    }
                }
            }
            .padding(.horizontal, 8)
            .padding(.top, 4)
            .padding(.bottom, 12)
        }
        .scrollBounceBehavior(.basedOnSize)
    }

    private var lockedState: some View {
        VStack(spacing: BrowserSpacing.compact + 2) {
            AccentGlyphBadge(systemImage: "lock.fill", size: 54, iconSize: 24)
            Text("无痕标签页已锁定")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(palette.primaryText)
            Button("验证身份") {
                authenticate { }
            }
            .buttonStyle(.borderedProminent)
            .tint(palette.accent)
            .controlSize(.small)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 28)
    }

    private var emptyState: some View {
        VStack(spacing: BrowserSpacing.compact) {
            AccentGlyphBadge(
                systemImage: searchQuery.isEmpty
                    ? (mode == .private ? "eyeglasses" : "rectangle.on.rectangle")
                    : "magnifyingglass",
                size: 54,
                iconSize: 24
            )
            Text(searchQuery.isEmpty ? "没有标签页" : "没有匹配的标签页")
                .font(.footnote)
                .foregroundStyle(palette.secondaryText)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 28)
    }

    private func tabRow(_ tab: BrowserTabState) -> some View {
        let isActive = tab.id == env.tabManager.activeTabId
        return HStack(spacing: 6) {
            Button {
                activate(tab)
            } label: {
                HStack(spacing: 9) {
                    tabGlyph(tab)

                    if tab.privacyMode == .private {
                        // A private row carries no title, host or favicon —
                        // the same rule the phone overview's private cards
                        // follow. A drawer left open over the page is the one
                        // place a private tab's name would be readable by
                        // whoever glances at the screen, so the row keeps its
                        // shape, its selected-row tint and its close button
                        // and nothing that names the page.
                        Text("无痕标签页")
                            .font(.system(size: 13, weight: isActive ? .semibold : .regular))
                            .foregroundStyle(palette.primaryText)
                            .lineLimit(1)
                    } else {
                        Text(tabTitle(tab))
                            .font(.system(size: 13, weight: isActive ? .semibold : .regular))
                            .foregroundStyle(palette.primaryText)
                            .lineLimit(1)
                    }

                    Spacer(minLength: 0)
                }
                .padding(.leading, 9)
                .padding(.trailing, 4)
                .padding(.vertical, 8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Button {
                env.tabManager.closeTab(id: tab.id)
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(palette.secondaryText)
                    .frame(width: 22, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("关闭标签页")
            .opacity(isActive ? 0.9 : 0.45)
        }
        .padding(.trailing, 5)
        .background(
            isActive ? palette.accent.opacity(0.13) : Color.clear,
            in: RoundedRectangle(cornerRadius: 11, style: .continuous)
        )
        .overlay(alignment: .leading) {
            if isActive {
                Capsule()
                    .fill(palette.accent)
                    .frame(width: 3, height: 18)
                    .offset(x: 3)
                    .allowsHitTesting(false)
            }
        }
        .privacySensitive(tab.privacyMode == .private)
    }

    @ViewBuilder
    private func tabGlyph(_ tab: BrowserTabState) -> some View {
        if tab.privacyMode == .private {
            Image(systemName: "eyeglasses")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(palette.secondaryText)
                .frame(width: 22, height: 22)
        } else if tab.isHome {
            Image(systemName: "plus")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(palette.secondaryText)
                .frame(width: 22, height: 22)
        } else {
            SiteIconView(
                host: tab.displayHost,
                size: 22,
                allowsThirdPartyLookup: true
            )
        }
    }

    private func tabTitle(_ tab: BrowserTabState) -> String {
        if tab.isHome { return "新标签页" }
        if !tab.title.isEmpty { return tab.title }
        if !tab.displayHost.isEmpty { return tab.displayHost }
        return "标签页"
    }

    // MARK: - Actions

    private func activate(_ tab: BrowserTabState) {
        guard tab.privacyMode == .private, env.requiresPrivateAuthentication else {
            env.tabManager.activateTab(id: tab.id)
            onClose?()
            return
        }
        authenticate {
            env.tabManager.activateTab(id: tab.id)
            onClose?()
        }
    }

    private func selectMode(_ target: BrowserSessionPrivacyMode) {
        guard target != mode else { return }
        guard target == .private, env.requiresPrivateAuthentication else {
            mode = target
            return
        }
        authenticate {
            mode = .private
        }
    }

    private func createTab() {
        let requestedMode = mode
        guard requestedMode == .private, env.requiresPrivateAuthentication else {
            _ = env.tabManager.createTab(privacyMode: requestedMode, openSource: .user)
            return
        }
        authenticate {
            _ = env.tabManager.createTab(privacyMode: requestedMode, openSource: .user)
        }
    }

    /// Runs the device check and reports why it failed in the same words the
    /// rest of the app uses. Nothing about the sidebar moves until the check
    /// passes: a cancelled prompt leaves the list the user was looking at in
    /// place.
    private func authenticate(onSuccess: @escaping () -> Void) {
        Task { @MainActor in
            switch await env.requestPrivateAccess(reason: "查看无痕标签页") {
            case .granted:
                onSuccess()
            case .cancelled:
                break
            case .unavailable:
                env.privateAccessNotice = "此设备未设置密码或面容 ID / 触控 ID，无法验证身份。"
            case .failed:
                env.privateAccessNotice = "验证未通过。"
            }
        }
    }
}
