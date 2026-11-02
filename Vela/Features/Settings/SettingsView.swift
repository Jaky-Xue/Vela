//
//  SettingsView.swift
//  Vela
//
//  The settings centre and the sub-pages that hang off it.
//
//  The root is grouped by *what the setting acts on*, not by where the feature
//  was implemented: 浏览器 is the browser itself (startup, tabs, its own chrome
//  and look), 网页与内容 is what happens inside a page, 隐私与安全 is what the
//  app keeps or shows about its owner, and 诊断与关于 stays out of the way at
//  the end. Each row carries one line of scope, so a user does not have to
//  open three screens to find out which one owns the control they want.
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
                        tint: .gray,
                        title: "通用",
                        subtitle: "启动、标签页保留、历史记录、界面布局"
                    )
                }

                NavigationLink {
                    AppearanceSettingsView()
                } label: {
                    settingsRow(
                        icon: "paintpalette",
                        tint: .purple,
                        title: "外观",
                        subtitle: "明暗、配色、背景、主页图标",
                        detail: appearanceDetail
                    )
                }

                NavigationLink {
                    ToolbarSettingsView()
                } label: {
                    settingsRow(
                        icon: "dock.rectangle",
                        tint: .teal,
                        title: "工具栏",
                        subtitle: "底部与 iPad 顶部工具栏的控件和顺序"
                    )
                }

                NavigationLink {
                    MenuSettingsView()
                } label: {
                    settingsRow(
                        icon: "square.grid.2x2",
                        tint: .orange,
                        title: "菜单面板",
                        subtitle: "菜单里的快捷功能、排序与隐藏"
                    )
                }
            } header: {
                Text("浏览器")
            } footer: {
                Text("浏览器本身的样子和操作方式。")
            }

            Section {
                NavigationLink {
                    SearchEngineSettingsView()
                } label: {
                    settingsRow(
                        icon: "magnifyingglass",
                        tint: .blue,
                        title: "搜索引擎",
                        subtitle: "默认搜索与地址栏推荐",
                        detail: env.settings.preferences.searchEngine.activeEngine.name
                    )
                }

                NavigationLink {
                    UserAgentSettingsView()
                } label: {
                    settingsRow(
                        icon: "safari",
                        tint: .brown,
                        title: "网页标识",
                        subtitle: "网站看到的设备与浏览器身份",
                        detail: userAgentDetail
                    )
                }

                NavigationLink {
                    UserScriptsView()
                } label: {
                    settingsRow(
                        icon: "curlybraces",
                        tint: .orange,
                        title: "用户脚本",
                        subtitle: "安装、更新与运行时机",
                        detail: env.settings.preferences.userScriptsEnabled ? "" : "已关闭"
                    )
                }

                NavigationLink {
                    ElementHideSettingsView()
                } label: {
                    settingsRow(
                        icon: "eye.slash",
                        tint: .gray,
                        title: "隐藏的元素",
                        subtitle: "用元素选择器在各网站隐藏的内容",
                        detail: env.settings.manualElementHide.sites.isEmpty
                            ? ""
                            : "\(env.settings.manualElementHide.sites.count) 个网站"
                    )
                }
            } header: {
                Text("网页与内容")
            } footer: {
                Text("这些设置作用于打开的网页；网页本身的颜色和排版仍由网站决定。")
            }

            Section {
                NavigationLink {
                    PasswordVaultView()
                } label: {
                    settingsRow(
                        icon: "key.fill",
                        tint: .yellow,
                        title: "密码与保险箱",
                        subtitle: "系统钥匙串保存的登录信息",
                        detail: env.passwords.credentials.isEmpty ? "" : "\(env.passwords.credentials.count) 条"
                    )
                }

                NavigationLink {
                    PrivateBrowsingSettingsView()
                } label: {
                    settingsRow(
                        icon: "eyeglasses",
                        tint: .purple,
                        title: "无痕模式",
                        subtitle: "身份验证、预览模糊与会话范围",
                        detail: env.settings.preferences.lockPrivateTabs ? "需验证" : "无需验证"
                    )
                }

                NavigationLink {
                    SitePermissionsSettingsView()
                } label: {
                    settingsRow(
                        icon: "lock.shield",
                        tint: .cyan,
                        title: "网站权限",
                        subtitle: "相机、麦克风、位置、剪贴板与访问记录"
                    )
                }

                NavigationLink {
                    ExternalNavigationSettingsView()
                } label: {
                    settingsRow(
                        icon: "arrow.up.forward.app",
                        tint: .pink,
                        title: "外部应用跳转",
                        subtitle: "把链接交给其他 App 打开",
                        detail: env.settings.preferences.externalNavigationDefault.displayName
                    )
                }

                NavigationLink {
                    WebRTCProtectionSettingsView()
                } label: {
                    settingsRow(
                        icon: "shield.lefthalf.filled",
                        tint: .indigo,
                        title: "WebRTC 泄露防护",
                        subtitle: "防止网页获取真实网络地址",
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
                        tint: .red,
                        title: "清除浏览数据",
                        subtitle: "历史、缓存、Cookie 与网站数据"
                    )
                }
            } header: {
                Text("隐私与安全")
            } footer: {
                Text("密码和身份验证由系统钥匙串与面容 ID / 触控 ID 负责，Vela 不保存可逆向的凭据。")
            }

            Section {
                NavigationLink {
                    DownloadSettingsView()
                } label: {
                    settingsRow(
                        icon: "arrow.down.circle",
                        tint: .blue,
                        title: "下载",
                        subtitle: "保存位置、并发数与断点续传",
                        detail: "\(env.downloads.activeCount) 个进行中"
                    )
                }
            } header: {
                Text("下载与数据")
            }

            Section {
                NavigationLink {
                    NavigationDiagnosticsView()
                } label: {
                    settingsRow(
                        icon: "waveform.path.ecg",
                        tint: .teal,
                        title: "加载诊断",
                        subtitle: "最近的网页加载记录与失败原因",
                        detail: "\(env.navigationLog.entries.count) 条"
                    )
                }

                NavigationLink {
                    AboutView()
                } label: {
                    settingsRow(
                        icon: "info.circle",
                        tint: .gray,
                        title: "关于 Vela",
                        subtitle: "版本、许可与尚未实现的能力"
                    )
                }
            } header: {
                Text("诊断与关于")
            }
        }
        .listStyle(.insetGrouped)
        .browserListSurface()
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

    /// What the 网页标识 row says is in force — the same answer the identifier
    /// screen gives, so the two cannot disagree: a chosen preset by its name,
    /// a hand-typed string as 自定义, and the desktop-site toggle only when no
    /// string overrides it.
    private var userAgentDetail: String {
        let stored = env.settings.preferences.customUserAgent
        if !stored.isEmpty {
            return BrowserUserAgentPreset.all.first { $0.userAgent == stored }?.title ?? "自定义"
        }
        if env.settings.preferences.desktopSiteByDefault {
            return "桌面版"
        }
        switch UIDevice.current.userInterfaceIdiom {
        case .pad: return "自动 · iPad"
        case .mac: return "自动 · Mac"
        default: return "自动 · iPhone"
        }
    }

    /// One settings row: an icon tile, the name, a one-line statement of what
    /// the screen owns, and an optional current value.
    ///
    /// The second line is the information layering. Without it the root read
    /// as a list of nouns — 通用, 外观, 工具栏 — and the only way to learn that
    /// 通用 contained the history retention was to open it and come back.
    private func settingsRow(
        icon: String,
        tint: Color,
        title: String,
        subtitle: String = "",
        detail: String = ""
    ) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 28, height: 28)
                .background(tint, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                .shadow(color: tint.opacity(0.28), radius: 4, y: 1)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .foregroundStyle(palette.primaryText)
                if !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(palette.secondaryText)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Spacer(minLength: 8)

            if !detail.isEmpty {
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(palette.secondaryText)
                    .lineLimit(1)
            }
        }
        .padding(.vertical, 2)
    }
}


// MARK: - Deep links

/// A settings screen a context can ask for by name.
///
/// The settings sheet is one NavigationStack; a context that says "翻译设置"
/// should land on that screen rather than on the root. Every case here has a
/// row in `SettingsView`, so a deep link and the list cannot describe
/// different screens.
enum SettingsDestination: String, Identifiable, Hashable, CaseIterable {
    case general
    case appearance
    case searchEngine
    case userAgent
    case userScripts
    case passwords
    case privateBrowsing
    case sitePermissions
    case externalNavigation
    case webrtc
    case clearData
    case downloads
    case diagnostics
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
        case .passwords: PasswordVaultView()
        case .privateBrowsing: PrivateBrowsingSettingsView()
        case .sitePermissions: SitePermissionsSettingsView()
        case .externalNavigation: ExternalNavigationSettingsView()
        case .webrtc: WebRTCProtectionSettingsView()
        case .clearData: ClearDataView()
        case .downloads: DownloadSettingsView()
        case .diagnostics: NavigationDiagnosticsView()
        case .about: AboutView()
        }
    }
}
