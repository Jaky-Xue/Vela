//
//  SettingsView.swift
//  Vela
//
//  The settings centre and the sub-pages that hang off it.
//
//  Only destinations with a backing implementation are listed, and the About page
//  records which of the remaining ones are absent rather than shipping rows that
//  lead nowhere. A settings row that opens an empty screen is worse than an
//  absent row.
//

import SwiftUI
import UIKit

struct SettingsView: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.browserPalette) private var palette
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        List {
            Section {
                NavigationLink {
                    SearchEngineSettingsView()
                } label: {
                    settingsRow(
                        icon: "magnifyingglass",
                        tint: .blue,
                        title: "搜索引擎",
                        detail: env.settings.preferences.searchEngine.activeEngine.name
                    )
                }

                NavigationLink {
                    AppearanceSettingsView()
                } label: {
                    settingsRow(icon: "paintpalette", tint: .purple, title: "外观")
                }

                NavigationLink {
                    AdBlockSettingsView()
                } label: {
                    settingsRow(
                        icon: "shield.lefthalf.filled",
                        tint: .green,
                        title: "广告与内容过滤",
                        detail: env.settings.adBlockSettings.preferences.enabled ? "已开启" : "已关闭"
                    )
                }

                NavigationLink {
                    UserScriptsView()
                } label: {
                    settingsRow(
                        icon: "curlybraces",
                        tint: .orange,
                        title: "用户脚本",
                        detail: env.settings.preferences.userScriptsEnabled ? "" : "已关闭"
                    )
                }
            }

            Section("隐私与安全") {
                NavigationLink {
                    SitePermissionsSettingsView()
                } label: {
                    settingsRow(icon: "lock.shield", tint: .cyan, title: "网站权限")
                }

                NavigationLink {
                    ExternalNavigationSettingsView()
                } label: {
                    settingsRow(
                        icon: "arrow.up.forward.app",
                        tint: .pink,
                        title: "外部应用跳转",
                        detail: env.settings.preferences.externalNavigationDefault.displayName
                    )
                }

                NavigationLink {
                    PasswordVaultView()
                } label: {
                    settingsRow(icon: "key.fill", tint: .yellow, title: "密码与保险箱")
                }

                NavigationLink {
                    WebRTCProtectionSettingsView()
                } label: {
                    settingsRow(
                        icon: "shield.lefthalf.filled",
                        tint: .indigo,
                        title: "WebRTC 泄露防护",
                        detail: env.settings.webRTCProtectionEnabled
                            ? env.settings.webRTCProtectionSelection.displayName
                            : "已关闭"
                    )
                }

                NavigationLink {
                    ClearDataView()
                } label: {
                    settingsRow(icon: "trash", tint: .red, title: "清除浏览数据")
                }
            }

            Section("浏览") {
                NavigationLink {
                    GeneralSettingsView()
                } label: {
                    settingsRow(icon: "gearshape", tint: .gray, title: "通用")
                }

                NavigationLink {
                    HomeSettingsView()
                } label: {
                    settingsRow(icon: "house", tint: .indigo, title: "主页")
                }

                NavigationLink {
                    ToolbarSettingsView()
                } label: {
                    settingsRow(icon: "dock.rectangle", tint: .teal, title: "工具栏")
                }

                NavigationLink {
                    MenuSettingsView()
                } label: {
                    settingsRow(icon: "square.grid.2x2", tint: .orange, title: "菜单面板")
                }

                NavigationLink {
                    DownloadSettingsView()
                } label: {
                    settingsRow(
                        icon: "arrow.down.circle",
                        tint: .blue,
                        title: "下载",
                        detail: "\(env.downloads.activeCount) 个进行中"
                    )
                }

                NavigationLink {
                    UserAgentSettingsView()
                } label: {
                    settingsRow(
                        icon: "safari",
                        tint: .brown,
                        title: "网页标识",
                        detail: userAgentDetail
                    )
                }

                NavigationLink {
                    TranslationSettingsView()
                } label: {
                    settingsRow(
                        icon: "character.bubble",
                        tint: .blue,
                        title: "网页翻译",
                        detail: env.settings.translationSettings.provider.displayName
                    )
                }

                NavigationLink {
                    NavigationDiagnosticsView()
                } label: {
                    settingsRow(
                        icon: "waveform.path.ecg",
                        tint: .teal,
                        title: "加载诊断",
                        detail: "\(env.navigationLog.entries.count) 条记录"
                    )
                }
            }

            Section {
                NavigationLink {
                    AboutView()
                } label: {
                    settingsRow(icon: "info.circle", tint: .gray, title: "关于 Vela")
                }
            }
        }
        .listStyle(.insetGrouped)
        .browserListSurface()
        // The sheet's content observes the setting directly; a preference
        // applied only by the presenting view can stay at the value the sheet
        // was presented with.
        .preferredColorScheme(env.settings.appearanceMode.colorScheme)
        .navigationTitle("设置")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("完成") { dismiss() }
            }
        }
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

    private func settingsRow(icon: String, tint: Color, title: String, detail: String = "") -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 26, height: 26)
                .background(tint, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            Text(title)
                .foregroundStyle(palette.primaryText)
            Spacer()
            if !detail.isEmpty {
                Text(detail)
                    .foregroundStyle(palette.secondaryText)
                    .font(.subheadline)
            }
        }
    }
}
