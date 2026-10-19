//
//  BrowserSidebarView.swift
//  Vela
//
//  The iPad layout's leading column: the open tabs, the mode switch, and the
//  doors to the library screens.
//
//  The sidebar is a native column of the shell, not a drawer: on a regular-width
//  iPad it is always visible, so switching tabs is one tap rather than a trip
//  through the tab overview. The phone layout keeps the overview and hides this.
//

import SwiftUI

struct BrowserSidebarView: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.browserPalette) private var palette

    var onOpenBookmarks: () -> Void
    var onOpenHistory: () -> Void
    var onOpenDownloads: () -> Void
    var onOpenSettings: () -> Void

    @State private var mode: BrowserSessionPrivacyMode = .regular

    private var tabs: [BrowserTabState] {
        mode == .private ? env.tabManager.privateTabs : env.tabManager.regularTabs
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Rectangle().fill(palette.separator).frame(height: 0.5)
            tabList
            Rectangle().fill(palette.separator).frame(height: 0.5)
            footer
        }
        .background {
            AmbientSurfaceFill(opacity: 0.48)
                .ignoresSafeArea()
        }
        .overlay(alignment: .trailing) {
            Rectangle()
                .fill(palette.separator)
                .frame(width: 0.5)
                .ignoresSafeArea()
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
                    _ = env.tabManager.createTab(privacyMode: mode, openSource: .user)
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 15, weight: .semibold))
                        .frame(width: 32, height: 32)
                        .background(palette.controlFill.opacity(0.7), in: Circle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(palette.primaryText)
                .accessibilityLabel("新建标签页")
            }

            Picker("标签模式", selection: $mode) {
                Text("普通").tag(BrowserSessionPrivacyMode.regular)
                Text("无痕").tag(BrowserSessionPrivacyMode.private)
            }
            .pickerStyle(.segmented)
        }
        .padding(.horizontal, 14)
        .padding(.top, 12)
        .padding(.bottom, 10)
    }

    // MARK: - Tabs

    private var tabList: some View {
        ScrollView {
            VStack(spacing: 3) {
                if tabs.isEmpty {
                    Text("没有标签页")
                        .font(.caption)
                        .foregroundStyle(palette.secondaryText)
                        .frame(maxWidth: .infinity)
                        .padding(.top, 24)
                } else {
                    ForEach(tabs) { tab in
                        tabRow(tab)
                    }
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 8)
        }
    }

    private func tabRow(_ tab: BrowserTabState) -> some View {
        let isActive = tab.id == env.tabManager.activeTabId
        return HStack(spacing: 8) {
            Button {
                env.tabManager.activateTab(id: tab.id)
            } label: {
                HStack(spacing: 9) {
                    SiteIconView(host: tab.displayHost, size: 20)
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
    }

    private func tabTitle(_ tab: BrowserTabState) -> String {
        if tab.isHome { return "新标签页" }
        if !tab.title.isEmpty { return tab.title }
        if !tab.displayHost.isEmpty { return tab.displayHost }
        return "标签页"
    }

    // MARK: - Footer

    private var footer: some View {
        HStack(spacing: 0) {
            footerButton("书签", symbol: "book", action: onOpenBookmarks)
            footerButton("历史", symbol: "clock.arrow.circlepath", action: onOpenHistory)
            footerButton("下载", symbol: "arrow.down.circle", action: onOpenDownloads)
            footerButton("设置", symbol: "gearshape", action: onOpenSettings)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 8)
    }

    private func footerButton(_ title: String, symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 3) {
                Image(systemName: symbol)
                    .font(.system(size: 15, weight: .medium))
                Text(title)
                    .font(.system(size: 9, weight: .medium))
            }
            .foregroundStyle(palette.secondaryText)
            .frame(maxWidth: .infinity, minHeight: 40)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
    }
}
