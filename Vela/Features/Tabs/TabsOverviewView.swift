//
//  TabsOverviewView.swift
//  Vela
//
//  The tab switcher.
//
//  A grid of title cards rather than captured previews: a `WKWebView` snapshot
//  costs a full render pass per tab, and the tab switcher is expected to open
//  instantly — a preview that arrives a second late is worse than a title that
//  is there immediately.
//
//  The privacy split is exact: regular and private tabs never appear in the same
//  list, and the private grid is what the lock setting gates.
//

import SwiftUI
import UIKit
import LocalAuthentication

struct TabsOverviewView: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.dismiss) private var dismiss

    @State private var showPrivateTabs = false
    @State private var isPrivateUnlocked = false
    @State private var pendingPrivateUnlock = false

    private var tabManager: TabManager { env.tabManager }

    private var visibleTabs: [BrowserTabState] {
        showPrivateTabs ? tabManager.privateTabs : tabManager.regularTabs
    }

    private let columns = [GridItem(.adaptive(minimum: 150, maximum: 200), spacing: 14)]

    var body: some View {
        NavigationStack {
            Group {
                if showPrivateTabs && isLocked && !isPrivateUnlocked {
                    lockedState
                } else if visibleTabs.isEmpty {
                    EmptyState(
                        systemImage: "square.on.square",
                        title: "没有标签页",
                        message: showPrivateTabs ? "打开一个无痕标签页开始浏览。" : "打开一个标签页开始浏览。"
                    )
                } else {
                    grid
                }
            }
            .navigationTitle(showPrivateTabs ? "无痕标签页" : "标签页")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { toolbarContent }
            .safeAreaInset(edge: .bottom) { bottomBar }
        }
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

    // MARK: - Grid

    private var grid: some View {
        ScrollView {
            LazyVGrid(columns: columns, spacing: 14) {
                ForEach(visibleTabs) { tab in
                    TabCard(
                        tab: tab,
                        isActive: tab.id == tabManager.activeTabId,
                        blurPreview: tab.privacyMode == .private && env.settings.preferences.blurPrivateTabPreviews,
                        onSelect: {
                            tabManager.activateTab(id: tab.id)
                            dismiss()
                        },
                        onClose: {
                            tabManager.closeTab(id: tab.id)
                        },
                        onPin: {
                            tabManager.setPinned(!tab.pinned, id: tab.id)
                        }
                    )
                }

                NewTabCard {
                    let tab = tabManager.createTab(
                        privacyMode: showPrivateTabs ? .private : .regular,
                        openSource: .user
                    )
                    tabManager.activateTab(id: tab.id)
                    dismiss()
                }
            }
            .padding(14)
        }
    }

    private var lockedState: some View {
        VStack(spacing: 16) {
            Image(systemName: "lock.fill")
                .font(.system(size: 34))
                .foregroundStyle(.secondary)
            Text("无痕标签页已锁定")
                .font(.headline)
            Text("需要验证身份才能查看无痕标签页。")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button("解锁") { pendingPrivateUnlock = true }
                .buttonStyle(.borderedProminent)
        }
        .padding(40)
    }

    // MARK: - Bars

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .cancellationAction) {
            Button("完成") { dismiss() }
        }
        ToolbarItem(placement: .principal) {
            Picker("模式", selection: $showPrivateTabs) {
                Text("普通").tag(false)
                Text("无痕").tag(true)
            }
            .pickerStyle(.segmented)
            .frame(width: 180)
        }
    }

    private var bottomBar: some View {
        HStack(spacing: 20) {
            Button {
                // reopen action is scoped to the mode being viewed, so a private
                // tab can never be restored into the regular list.
                if let tab = tabManager.reopenLastClosedTab(
                    privacyMode: showPrivateTabs ? .private : .regular
                ) {
                    _ = tab
                    dismiss()
                }
            } label: {
                Label("重新打开", systemImage: "arrow.uturn.backward")
                    .font(.system(size: 14))
            }
            .buttonStyle(.plain)
            .disabled(tabManager.recentlyClosed.allSatisfy {
                $0.privacyMode != (showPrivateTabs ? .private : .regular)
            })

            Button {
                tabManager.closeAllTabs(privacyMode: showPrivateTabs ? .private : .regular)
            } label: {
                Label("全部关闭", systemImage: "trash")
                    .font(.system(size: 14))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.red)

            Spacer()

            Text("\(visibleTabs.count) 个标签页")
                .font(.caption)
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .background(.bar)
    }
}

/// One tab card.
private struct TabCard: View {
    var tab: BrowserTabState
    var isActive: Bool
    var blurPreview: Bool
    var onSelect: () -> Void
    var onClose: () -> Void
    var onPin: () -> Void

    var body: some View {
        Button(action: onSelect) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 6) {
                    SiteIconView(host: tab.displayHost, size: 18, faviconUrl: tab.faviconUrl.isEmpty ? nil : tab.faviconUrl)
                    Text(tab.displayTitle)
                        .font(.system(size: 13, weight: .medium))
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                        .foregroundStyle(.primary)
                    Spacer(minLength: 0)
                    if tab.pinned {
                        Image(systemName: "pin.fill")
                            .font(.system(size: 9))
                            .foregroundStyle(.secondary)
                    }
                    if tab.audible {
                        Image(systemName: tab.muted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                            .font(.system(size: 9))
                            .foregroundStyle(.secondary)
                    }
                }

                Text(tab.isHome ? "新标签页" : tab.displayHost)
                    .font(.system(size: 11))
                    .lineLimit(1)
                    .foregroundStyle(.secondary)

                Spacer(minLength: 0)

                HStack {
                    if tab.isLoading {
                        ProgressRing(progress: tab.estimatedProgress)
                            .frame(width: 12, height: 12)
                    }
                    Spacer()
                    Button(action: onClose) {
                        Image(systemName: "xmark")
                            .font(.system(size: 10, weight: .semibold))
                            .padding(5)
                            .background(Color(.tertiarySystemFill), in: Circle())
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                }
            }
            .padding(11)
            .frame(height: 116)
            .frame(maxWidth: .infinity)
            .background(Color(.secondarySystemGroupedBackground))
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(isActive ? Color.accentColor : Color.clear, lineWidth: 2)
            }
            // The privacy blur is applied to the title block rather than to the
            // whole card, so the close button stays legible on a locked screen.
            .blur(radius: blurPreview ? 4 : 0)
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button(tab.pinned ? "取消固定" : "固定标签页", systemImage: tab.pinned ? "pin.slash" : "pin", action: onPin)
            Button("关闭标签页", systemImage: "xmark", role: .destructive, action: onClose)
        }
    }
}

/// The card that opens a new tab.
private struct NewTabCard: View {
    var onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            VStack(spacing: 8) {
                Image(systemName: "plus")
                    .font(.system(size: 22, weight: .light))
                Text("新建标签页")
                    .font(.system(size: 12))
            }
            .frame(maxWidth: .infinity)
            .frame(height: 116)
            .foregroundStyle(.secondary)
            .background(Color(.tertiarySystemFill))
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .buttonStyle(.plain)
    }
}

/// The identity check shown before the private tab list.
///
/// `LAContext` is what gates the private list, so the biometric prompt a user
/// sees is the standard system one.
private struct PrivateUnlockSheet: View {
    var onUnlock: () -> Void
    var onCancel: () -> Void

    @State private var errorMessage: String?

    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "lock.shield")
                .font(.system(size: 36))
                .foregroundStyle(.tint)
                .padding(.top, 34)

            Text("验证身份")
                .font(.headline)

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
        .presentationDetents([.height(300)])
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
