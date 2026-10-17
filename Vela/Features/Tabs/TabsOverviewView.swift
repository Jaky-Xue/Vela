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
import WebKit

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
                } else {
                    // The grid renders with no tabs at all: the add card is
                    // the only thing in it, which is the honest picture of an
                    // empty strip — and the state 全部关闭 leaves behind. An
                    // empty-state message here would only restate what the
                    // dashed card already says.
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

/// One tab card: the page's own screenshot above its title — the shape
/// Safari's tab overview uses, which is what this one is modelled on.
private struct TabCard: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.browserPalette) private var palette

    var tab: BrowserTabState
    var isActive: Bool
    var blurPreview: Bool
    var onSelect: () -> Void
    var onClose: () -> Void
    var onPin: () -> Void

    /// The page's picture, taken once per card appearance from the live web
    /// view. A cold tab has no web view to ask and keeps its placeholder
    /// until it has been opened once; the sheet's lifetime bounds the cache.
    @State private var snapshot: UIImage?

    var body: some View {
        VStack(spacing: 6) {
            ZStack(alignment: .topTrailing) {
                thumbnail
                    .frame(maxWidth: .infinity)
                    .aspectRatio(0.72, contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .strokeBorder(
                                isActive ? palette.accent : palette.cardStroke,
                                lineWidth: isActive ? 2 : 0.5
                            )
                            .allowsHitTesting(false)
                    }

                closeButton
            }
            .blur(radius: blurPreview ? 5 : 0)

            HStack(spacing: 5) {
                SiteIconView(
                    host: tab.displayHost,
                    size: 14,
                    faviconUrl: tab.faviconUrl.isEmpty ? nil : tab.faviconUrl
                )
                Text(tab.displayTitle)
                    .font(.caption2)
                    .lineLimit(1)
                    .foregroundStyle(palette.primaryText)
                Spacer(minLength: 0)
            }
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
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(palette.primaryText)
                .frame(width: 20, height: 20)
                .background(.thinMaterial, in: Circle())
                .frame(width: 34, height: 34)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("关闭标签页")
    }
}

/// The card that opens a new tab, in the same thumbnail shape as the cards
/// beside it, dashed where they are solid.
private struct NewTabCard: View {
    @Environment(\.browserPalette) private var palette

    var onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            VStack(spacing: 6) {
                ZStack {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(palette.controlFill.opacity(0.4))
                    Image(systemName: "plus")
                        .font(.system(size: 22, weight: .light))
                        .foregroundStyle(palette.secondaryText)
                }
                .frame(maxWidth: .infinity)
                .aspectRatio(0.72, contentMode: .fit)
                .overlay {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .strokeBorder(
                            palette.secondaryText.opacity(0.35),
                            style: StrokeStyle(lineWidth: 1, dash: [5, 4])
                        )
                }

                Text("新建标签页")
                    .font(.caption2)
                    .foregroundStyle(palette.secondaryText)
            }
            .contentShape(Rectangle())
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
