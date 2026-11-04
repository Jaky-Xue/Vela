//
//  SettingsView.swift
//  Vela
//
//  The settings centre and the sub-pages that hang off it.
//
//  The root is grouped by *what the setting acts on*, not by where the feature
//  was implemented: 浏览器 is the browser itself (startup, tabs, its own chrome
//  and look), 网页与内容 is what happens inside a page, 隐私与安全 is what the
//  app keeps or shows about its owner, and 关于 stays out of the way at
//  the end. The rows are deliberately wordless beyond their names and current
//  values — the section already says the context, and the screen behind the
//  row is where the detail belongs.
//
//  Only destinations with a backing implementation are listed, and the About
//  page records which of the remaining ones are absent rather than shipping
//  rows that lead nowhere. A settings row that opens an empty screen is worse
//  than an absent row.
//

import SwiftUI
import UIKit

struct SettingsView: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.browserPalette) private var palette
    @Environment(\.dismiss) private var dismiss

    /// A page to open above the root. Any context that names a specific
    /// screen pushes it directly instead of landing the user on a list of
    /// nouns to hunt through.
    @State private var pushedDestination: SettingsDestination?

    init(initialDestination: SettingsDestination? = nil) {
        _pushedDestination = State(initialValue: initialDestination)
    }

    var body: some View {
        List {
            Section {
                NavigationLink {
                    GeneralSettingsView()
                } label: {
                    settingsRow(
                        icon: "gearshape",
                        title: "通用"
                    )
                }

                NavigationLink {
                    AppearanceSettingsView()
                } label: {
                    settingsRow(
                        icon: "paintpalette",
                        title: "外观",
                        detail: appearanceDetail
                    )
                }

                NavigationLink {
                    ToolbarSettingsView()
                } label: {
                    settingsRow(
                        icon: "dock.rectangle",
                        title: "工具栏"
                    )
                }

                NavigationLink {
                    MenuSettingsView()
                } label: {
                    settingsRow(
                        icon: "square.grid.2x2",
                        title: "菜单面板"
                    )
                }

                NavigationLink {
                    DownloadSettingsView()
                } label: {
                    settingsRow(
                        icon: "arrow.down.circle",
                        title: "下载",
                        detail: env.downloads.activeCount > 0
                            ? "\(env.downloads.activeCount) 个进行中"
                            : ""
                    )
                }
            } header: {
                Text("浏览器")
            }

            Section {
                NavigationLink {
                    SearchEngineSettingsView()
                } label: {
                    settingsRow(
                        icon: "magnifyingglass",
                        title: "搜索引擎",
                        detail: env.settings.preferences.searchEngine.activeEngine.name
                    )
                }

                NavigationLink {
                    UserAgentSettingsView()
                } label: {
                    settingsRow(
                        icon: "safari",
                        title: "网页标识",
                        detail: userAgentDetail
                    )
                }

                NavigationLink {
                    UserScriptsView()
                } label: {
                    settingsRow(
                        icon: "curlybraces",
                        title: "用户脚本",
                        detail: env.settings.preferences.userScriptsEnabled ? "" : "已关闭"
                    )
                }

                NavigationLink {
                    ContentBlockerSettingsView()
                } label: {
                    settingsRow(
                        icon: "shield",
                        title: "广告拦截",
                        detail: contentBlockerDetail
                    )
                }

                NavigationLink {
                    ElementHideSettingsView()
                } label: {
                    settingsRow(
                        icon: "eye.slash",
                        title: "隐藏的元素",
                        detail: env.settings.manualElementHide.sites.isEmpty
                            ? ""
                            : "\(env.settings.manualElementHide.sites.count) 个网站"
                    )
                }
            } header: {
                Text("网页与内容")
            }

            Section {
                NavigationLink {
                    PasswordVaultView()
                } label: {
                    settingsRow(
                        icon: "key.fill",
                        title: "密码与保险箱",
                        detail: env.passwords.credentials.isEmpty ? "" : "\(env.passwords.credentials.count) 条"
                    )
                }

                NavigationLink {
                    PrivateBrowsingSettingsView()
                } label: {
                    settingsRow(
                        icon: "eyeglasses",
                        title: "无痕模式",
                        detail: env.settings.preferences.lockPrivateTabs ? "需验证" : "无需验证"
                    )
                }

                NavigationLink {
                    SitePermissionsSettingsView()
                } label: {
                    settingsRow(
                        icon: "lock.shield",
                        title: "网站权限"
                    )
                }

                NavigationLink {
                    ExternalNavigationSettingsView()
                } label: {
                    settingsRow(
                        icon: "arrow.up.forward.app",
                        title: "外部应用跳转",
                        detail: env.settings.preferences.externalNavigationDefault.displayName
                    )
                }

                NavigationLink {
                    WebRTCProtectionSettingsView()
                } label: {
                    settingsRow(
                        icon: "shield.lefthalf.filled",
                        title: "WebRTC 泄露防护",
                        detail: env.settings.webRTCProtectionEnabled
                            ? env.settings.webRTCProtectionSelection.displayName
                            : "已关闭"
                    )
                }

                NavigationLink {
                    ClearDataView()
                } label: {
                    settingsRow(
                        icon: "trash",
                        title: "清除浏览数据"
                    )
                }
            } header: {
                Text("隐私与安全")
            }

            Section {
                NavigationLink {
                    DataTransferSettingsView()
                } label: {
                    settingsRow(
                        icon: "arrow.up.arrow.down.circle",
                        title: "导入与导出",
                        detail: ""
                    )
                }
            } header: {
                Text("数据")
            }

            Section {
                NavigationLink {
                    AboutView()
                } label: {
                    settingsRow(
                        icon: "info.circle",
                        title: "关于 Vela"
                    )
                }
            } header: {
                Text("关于")
            }
        }
        .listStyle(.insetGrouped)
        .settingsList()
        .navigationDestination(item: $pushedDestination) { destination in
            destination.view
        }
        // The appearance is applied to the window and to the presented view
        // controllers (`AppearanceMode.applyToAllWindows`), so this sheet —
        // including the Appearance screen pushed from it — re-resolves its
        // colours without a per-sheet preference pin.
        .navigationTitle("设置")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("完成") { dismiss() }
            }
        }
    }

    /// What the 外观 row says is in force: the palette by name and the
    /// appearance the app is actually using. The mode reads 跟随系统 in that
    /// case rather than naming a colour, because the row's job is to say what
    /// the user chose, not what the system decided for them.
    private var appearanceDetail: String {
        let paletteName = BrowserPalette.all
            .first { $0.id == env.settings.preferences.themePaletteId }?
            .displayName ?? BrowserPalette.default.displayName
        return "\(paletteName) · \(env.settings.appearanceMode.displayName)"
    }

    /// What the 广告拦截 row says is in force.
    private var contentBlockerDetail: String {
        guard env.settings.contentBlocker.enabled else { return "已关闭" }
        let blocker = env.services.contentBlocker
        if blocker.isReady { return "\(blocker.ruleCount) 条规则" }
        return blocker.isCompiling ? "编译中" : "未就绪"
    }

    /// What the 网页标识 row says is in force: a chosen preset by its name, a
    /// hand-typed string as 自定义, or 自动. The page layout follows the
    /// identifier, so this one row answers both questions.
    private var userAgentDetail: String {
        let stored = env.settings.preferences.customUserAgent
        if !stored.isEmpty {
            return BrowserUserAgentPreset.all.first { $0.userAgent == stored }?.title ?? "自定义"
        }
        return "自动"
    }

    /// One settings row: a themed icon tile, the name, and the value in force.
    ///
    /// The value is the only secondary line. It answers "what is set" — a
    /// palette name, a count, a mode — without the row restating what its
    /// screen contains; the root is a map, and opening a row is how a screen's
    /// scope becomes known.
    private func settingsRow(
        icon: String,
        title: String,
        detail: String = ""
    ) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(palette.accent)
                .frame(width: 28, height: 28)
                .background(
                    palette.accent.opacity(0.13),
                    in: RoundedRectangle(cornerRadius: 8, style: .continuous)
                )

            Text(title)
                .foregroundStyle(palette.primaryText)

            Spacer(minLength: 8)

            if !detail.isEmpty {
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(palette.secondaryText)
                    .lineLimit(1)
            }
        }
        .padding(.vertical, 3)
    }
}


// MARK: - Deep links

/// A settings screen a context can ask for by name.
///
/// The settings sheet is one NavigationStack; a context that says "网页标识"
/// should land on that screen rather than on the root. Every case here has a
/// row in `SettingsView`, so a deep link and the list cannot describe
/// different screens.
enum SettingsDestination: String, Identifiable, Hashable, CaseIterable {
    case general
    case appearance
    case searchEngine
    case userAgent
    case userScripts
    case contentBlocker
    case dataTransfer
    case passwords
    case privateBrowsing
    case sitePermissions
    case externalNavigation
    case webrtc
    case clearData
    case downloads
    case about

    var id: String { rawValue }

    @MainActor
    @ViewBuilder
    var view: some View {
        switch self {
        case .general: GeneralSettingsView()
        case .appearance: AppearanceSettingsView()
        case .searchEngine: SearchEngineSettingsView()
        case .userAgent: UserAgentSettingsView()
        case .userScripts: UserScriptsView()
        case .contentBlocker: ContentBlockerSettingsView()
        case .dataTransfer: DataTransferSettingsView()
        case .passwords: PasswordVaultView()
        case .privateBrowsing: PrivateBrowsingSettingsView()
        case .sitePermissions: SitePermissionsSettingsView()
        case .externalNavigation: ExternalNavigationSettingsView()
        case .webrtc: WebRTCProtectionSettingsView()
        case .clearData: ClearDataView()
        case .downloads: DownloadSettingsView()
        case .about: AboutView()
        }
    }
}
