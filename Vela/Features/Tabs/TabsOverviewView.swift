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
    @Environment(\.browserPalette) private var palette
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
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(palette.surface)
            .navigationTitle(showPrivateTabs ? "无痕标签页" : "标签页")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(palette.chromeBackground, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
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
        HStack(spacing: BrowserSpacing.regular) {
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
                    .foregroundStyle(palette.primaryText)
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

            Spacer(minLength: 0)

            Text("\(visibleTabs.count) 个标签页")
                .font(.caption)
                .foregroundStyle(palette.secondaryText)
                .monospacedDigit()
        }
        .padding(.horizontal, BrowserSpacing.regular + 4)
        .padding(.vertical, BrowserSpacing.compact + 2)
        .background(.bar)
    }
}

/// One tab card.
///
/// The card is a tappable surface with a real button inside it, rather than a
/// `Button` wrapping another `Button`. Nested buttons are resolved by whichever
/// gesture SwiftUI decides wins, which in practice made the close control also
/// select the tab it was closing — and closed a different tab than the one the
/// user aimed at, because selection re-orders the grid under the finger.
private struct TabCard: View {
    @Environment(\.browserPalette) private var palette

    var tab: BrowserTabState
    var isActive: Bool
    var blurPreview: Bool
    var onSelect: () -> Void
    var onClose: () -> Void
    var onPin: () -> Void

    var body: some View {
        ZStack(alignment: .topTrailing) {
            VStack(alignment: .leading, spacing: 0) {
                header
                Spacer(minLength: 0)
                footer
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(height: 124)
            .contentShape(RoundedRectangle(cornerRadius: BrowserRadius.card, style: .continuous))
            .onTapGesture(perform: onSelect)

            closeButton
        }
        .browserCard(
            material: .thinMaterial,
            radius: BrowserRadius.card,
            elevation: .card,
            tint: cardTint
        )
        .overlay {
            RoundedRectangle(cornerRadius: BrowserRadius.card, style: .continuous)
                .strokeBorder(
                    isActive ? palette.accent : palette.cardStroke,
                    lineWidth: isActive ? 2 : 0.5
                )
                .allowsHitTesting(false)
        }
        .contextMenu {
            Button(tab.pinned ? "取消固定" : "固定标签页", systemImage: tab.pinned ? "pin.slash" : "pin", action: onPin)
            Button("关闭标签页", systemImage: "xmark", role: .destructive, action: onClose)
        }
    }

    /// The active tab is tinted as well as ringed. On a grid of a dozen cards a
    /// ring alone is easy to lose; the fill is what makes the current tab read
    /// as the current tab at a glance.
    private var cardTint: Color {
        isActive ? palette.accent.opacity(0.14) : palette.card.opacity(0.35)
    }

    private var header: some View {
        HStack(alignment: .top, spacing: BrowserSpacing.tight + 2) {
            SiteIconView(
                host: tab.displayHost,
                size: 26,
                faviconUrl: tab.faviconUrl.isEmpty ? nil : tab.faviconUrl
            )
            .shadow(color: .black.opacity(0.08), radius: 2, y: 1)

            VStack(alignment: .leading, spacing: 1) {
                Text(tab.displayTitle)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                    .foregroundStyle(palette.primaryText)
                Text(tab.isHome ? "新标签页" : tab.displayHost)
                    .font(.system(size: 11))
                    .lineLimit(1)
                    .foregroundStyle(palette.secondaryText)
            }
            .blur(radius: blurPreview ? 4 : 0)
        }
        // Room for the close button, which floats over the top-right corner.
        .padding(.trailing, 34)
    }

    private var footer: some View {
        HStack(spacing: BrowserSpacing.tight) {
            if tab.isLoading {
                ProgressRing(progress: tab.estimatedProgress)
                    .frame(width: 12, height: 12)
            }
            if tab.pinned {
                Image(systemName: "pin.fill")
                    .font(.system(size: 10))
                    .foregroundStyle(palette.accent)
            }
            if tab.audible {
                Image(systemName: tab.muted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                    .font(.system(size: 10))
                    .foregroundStyle(palette.secondaryText)
            }
            Spacer(minLength: 0)
        }
        .frame(height: 14)
    }

    private var closeButton: some View {
        Button(action: onClose) {
            Image(systemName: "xmark")
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(palette.secondaryText)
                .frame(width: 20, height: 20)
                .background(palette.controlFill, in: Circle())
                // The glyph stays small so it does not compete with the title,
                // but the target does not: a 20 pt disc is half the minimum a
                // finger can reliably hit, and this is the control that destroys
                // something.
                .frame(width: 36, height: 36)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(4)
        .accessibilityLabel("关闭标签页")
    }
}

/// The card that opens a new tab.
private struct NewTabCard: View {
    @Environment(\.browserPalette) private var palette

    var onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            VStack(spacing: BrowserSpacing.tight) {
                Image(systemName: "plus")
                    .font(.system(size: 22, weight: .light))
                Text("新建标签页")
                    .font(.system(size: 12, weight: .medium))
            }
            .frame(maxWidth: .infinity)
            .frame(height: 124)
            .foregroundStyle(palette.secondaryText)
            .background(palette.controlFill.opacity(0.5), in: RoundedRectangle(cornerRadius: BrowserRadius.card, style: .continuous))
            // A dashed border rather than a stroke: this card is not a tab, and
            // it should not read as one with an empty title.
            .overlay {
                RoundedRectangle(cornerRadius: BrowserRadius.card, style: .continuous)
                    .strokeBorder(
                        palette.secondaryText.opacity(0.35),
                        style: StrokeStyle(lineWidth: 1, dash: [5, 4])
                    )
            }
        }
        .buttonStyle(.plain)
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
