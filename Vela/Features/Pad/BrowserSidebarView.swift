//
//  BrowserSidebarView.swift
//  Vela
//
//  The iPad layout's tab drawer: the open tabs, the mode switch and a search
//  field, in a floating glass panel.
//
//  Safari's iPad sidebar is a rounded sheet that slides in over the page; this
//  is the same shape and the same motion. The panel supplies its own glass, so
//  this view paints no background at all — a second material here would be a
//  blurred layer inside a blurred layer.
//

import SwiftUI

struct BrowserSidebarView: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.browserPalette) private var palette

    var onClose: (() -> Void)? = nil

    @State private var mode: BrowserSessionPrivacyMode = .regular
    @State private var searchQuery = ""

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
            Rectangle()
                .fill(palette.separator.opacity(0.55))
                .frame(height: 0.5)
                .padding(.horizontal, 14)
            tabList
        }
        .onAppear {
            mode = env.tabManager.activeTab?.privacyMode ?? .regular
        }
        .onChange(of: env.tabManager.activeTabId) { _, _ in
            if let active = env.tabManager.activeTab {
                mode = active.privacyMode
            }
        }
    }

    // MARK: - Header

    private var header: some View {
        VStack(spacing: BrowserSpacing.compact) {
            HStack(spacing: 8) {
                Text("Vela")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(palette.primaryText)
                Spacer()
                Button {
                    let requestedMode = mode
                    Task { @MainActor in
                        if requestedMode == .private {
                            switch await env.requestPrivateAccess(reason: "新建无痕标签页") {
                            case .granted:
                                break
                            case .cancelled:
                                return
                            case .unavailable:
                                env.privateAccessNotice = "此设备未设置密码或面容 ID / 触控 ID，无法验证身份。"
                                return
                            case .failed:
                                env.privateAccessNotice = "验证未通过。"
                                return
                            }
                        }
                        _ = env.tabManager.createTab(privacyMode: requestedMode, openSource: .user)
                    }
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 15, weight: .semibold))
                        .frame(width: 32, height: 32)
                        .background(palette.controlFill.opacity(0.7), in: Circle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(palette.primaryText)
                .accessibilityLabel("新建标签页")

                if let onClose {
                    Button(action: onClose) {
                        Image(systemName: "xmark")
                            .font(.system(size: 13, weight: .semibold))
                            .frame(width: 32, height: 32)
                            .background(palette.controlFill.opacity(0.7), in: Circle())
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(palette.secondaryText)
                    .accessibilityLabel("收起侧边栏")
                }
            }

            // The private segment is the sidebar's 无痕 switch, so it runs the
            // same device check as the phone overview. The mode only moves
            // once the check passes; a cancelled prompt leaves the sidebar on
            // the regular column instead of opening a list the user did not
            // authenticate to see.
            Picker("标签模式", selection: Binding(
                get: { mode },
                set: { requested in
                    guard requested == .private,
                          env.requiresPrivateAuthentication else {
                        mode = requested
                        return
                    }
                    Task { @MainActor in
                        switch await env.requestPrivateAccess(reason: "查看无痕标签页") {
                        case .granted:
                            mode = .private
                        case .cancelled:
                            break
                        case .unavailable:
                            env.privateAccessNotice = "此设备未设置密码或面容 ID / 触控 ID，无法验证身份。"
                        case .failed:
                            env.privateAccessNotice = "验证未通过。"
                        }
                    }
                }
            )) {
                Text("普通").tag(BrowserSessionPrivacyMode.regular)
                Text("无痕").tag(BrowserSessionPrivacyMode.private)
            }
            .pickerStyle(.segmented)

            searchField
        }
        .padding(.horizontal, 14)
        .padding(.top, 12)
        .padding(.bottom, 10)
    }

    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(palette.secondaryText)

            TextField("搜索标签页", text: $searchQuery)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
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
                    VStack(spacing: BrowserSpacing.compact) {
                        Image(systemName: "lock.fill")
                            .font(.system(size: 26))
                            .foregroundStyle(palette.accent)
                            .frame(width: 54, height: 54)
                            .background(palette.accent.opacity(0.12), in: Circle())
                        Text("无痕标签页已锁定")
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(palette.primaryText)
                        Button("验证身份") {
                            Task { @MainActor in
                                switch await env.requestPrivateAccess(reason: "查看无痕标签页") {
                                case .granted:
                                    break
                                case .cancelled:
                                    break
                                case .unavailable:
                                    env.privateAccessNotice = "此设备未设置密码或面容 ID / 触控 ID，无法验证身份。"
                                case .failed:
                                    env.privateAccessNotice = "验证未通过。"
                                }
                            }
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.top, 32)
                } else if visibleTabs.isEmpty {
                    Text(searchQuery.isEmpty ? "没有标签页" : "没有匹配的标签页")
                        .font(.caption)
                        .foregroundStyle(palette.secondaryText)
                        .frame(maxWidth: .infinity)
                        .padding(.top, 24)
                } else {
                    ForEach(visibleTabs) { tab in
                        tabRow(tab)
                    }
                }
            }
            .padding(.horizontal, 8)
            .padding(.top, 8)
            .padding(.bottom, 12)
        }
    }

    private func tabRow(_ tab: BrowserTabState) -> some View {
        let isActive = tab.id == env.tabManager.activeTabId
        return HStack(spacing: 8) {
            Button {
                if tab.privacyMode == .private, env.requiresPrivateAuthentication {
                    Task { @MainActor in
                        switch await env.requestPrivateAccess(reason: "查看无痕标签页") {
                        case .granted:
                            env.tabManager.activateTab(id: tab.id)
                            onClose?()
                        case .cancelled:
                            break
                        case .unavailable:
                            env.privateAccessNotice = "此设备未设置密码或面容 ID / 触控 ID，无法验证身份。"
                        case .failed:
                            env.privateAccessNotice = "验证未通过。"
                        }
                    }
                } else {
                    env.tabManager.activateTab(id: tab.id)
                    onClose?()
                }
            } label: {
                HStack(spacing: 9) {
                    if tab.privacyMode == .private {
                        // A private row carries no title, host or favicon —
                        // the same rule the phone overview's private cards
                        // follow. A drawer left open over the page is the one
                        // place a private tab's name would be readable by
                        // whoever glances at the screen, so the row keeps its
                        // shape, its active dot and its close button and
                        // nothing that names the page.
                        Image(systemName: "eyeglasses")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(palette.secondaryText)
                            .frame(width: 20, height: 20)
                        Text("无痕标签页")
                            .font(.system(size: 13, weight: isActive ? .semibold : .regular))
                            .foregroundStyle(palette.primaryText)
                            .lineLimit(1)
                    } else if tab.isHome {
                        // No host means no favicon; a question-mark placeholder
                        // in front of 新标签页 read as an error.
                        Image(systemName: "plus")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(palette.secondaryText)
                            .frame(width: 20, height: 20)
                    } else {
                        SiteIconView(
                            host: tab.displayHost,
                            size: 20,
                            allowsThirdPartyLookup: true
                        )
                    }
                    if tab.privacyMode != .private {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(tabTitle(tab))
                                .font(.system(size: 13, weight: isActive ? .semibold : .regular))
                                .foregroundStyle(palette.primaryText)
                                .lineLimit(1)
                            if !tab.displayHost.isEmpty {
                                Text(tab.displayHost)
                                    .font(.system(size: 10))
                                    .foregroundStyle(palette.secondaryText)
                                    .lineLimit(1)
                            }
                        }
                    }
                    Spacer(minLength: 0)
                    if isActive {
                        Circle()
                            .fill(palette.accent)
                            .frame(width: 6, height: 6)
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 7)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Button {
                env.tabManager.closeTab(id: tab.id)
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(palette.secondaryText)
                    .frame(width: 24, height: 24)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("关闭标签页")
            .opacity(isActive ? 1 : 0.55)
        }
        .background(
            isActive ? palette.accent.opacity(0.13) : Color.clear,
            in: RoundedRectangle(cornerRadius: 9, style: .continuous)
        )
        .privacySensitive(tab.privacyMode == .private)
    }

    private func tabTitle(_ tab: BrowserTabState) -> String {
        if tab.isHome { return "新标签页" }
        if !tab.title.isEmpty { return tab.title }
        if !tab.displayHost.isEmpty { return tab.displayHost }
        return "标签页"
    }
}
