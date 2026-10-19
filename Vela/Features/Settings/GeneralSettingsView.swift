//
//  GeneralSettingsView.swift
//  Vela
//
//  Startup, tab, history-retention, reading and top-protection settings.
//

import SwiftUI
import UIKit

// MARK: - General

struct GeneralSettingsView: View {
    @Environment(AppEnvironment.self) private var env

    private static let retentionChoices: [(String, Int)] = [
        ("不自动清理", 0),
        ("7 天", 7),
        ("30 天", 30),
        ("90 天", 90),
        ("180 天", 180),
        ("1 年", 365)
    ]

    var body: some View {
        List {
            Section {
                Toggle("启动时恢复上次的标签页", isOn: Binding(
                    get: { env.settings.preferences.restoreTabsOnLaunch },
                    set: { value in env.settings.update { $0.restoreTabsOnLaunch = value } }
                ))
                Toggle("在后台打开新标签页", isOn: Binding(
                    get: { env.settings.preferences.openNewTabsInBackground },
                    set: { value in env.settings.update { $0.openNewTabsInBackground = value } }
                ))
                Toggle("不保留标签页", isOn: Binding(
                    get: { env.settings.preferences.tabsNotRetained ?? false },
                    set: { value in env.setTabsNotRetained(value) }
                ))
            } header: {
                Text("启动与标签页")
            } footer: {
                Text("开启「不保留标签页」后，退出应用不会保存当前标签页，下次启动从新标签页开始。")
            }

            Section {
                Toggle("不保留历史记录", isOn: Binding(
                    get: { env.settings.preferences.historyNotRetained ?? false },
                    set: { value in env.settings.update { $0.historyNotRetained = value } }
                ))

                Picker("保留时长", selection: Binding(
                    get: { env.settings.preferences.historyRetentionDays },
                    set: { value in env.settings.update { $0.historyRetentionDays = value } }
                )) {
                    ForEach(Self.retentionChoices, id: \.1) { choice in
                        Text(choice.0).tag(choice.1)
                    }
                }
                .disabled(env.settings.preferences.historyNotRetained ?? false)
            } header: {
                Text("历史记录保留")
            } footer: {
                Text("开启「不保留历史记录」后，新的访问和搜索不再写入历史；已有记录不会自动删除，可在「清除浏览数据」中清理。")
            }

            Section {
                Toggle("阅读模式", isOn: Binding(
                    get: { env.settings.preferences.readerModeAvailable },
                    set: { value in env.settings.update { $0.readerModeAvailable = value } }
                ))
            } header: {
                Text("阅读")
            }

            Section {
                ForEach(InterfaceLayoutMode.allCases) { mode in
                    Button {
                        env.settings.interfaceLayout = mode
                    } label: {
                        HStack(alignment: .top, spacing: 12) {
                            Image(systemName: mode.symbolName)
                                .font(.system(size: 15, weight: .semibold))
                                .frame(width: 26)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(mode.displayName)
                                    .foregroundStyle(.primary)
                                Text(mode.detail)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            Spacer(minLength: 0)
                            if env.settings.interfaceLayout == mode {
                                Image(systemName: "checkmark")
                                    .foregroundStyle(.tint)
                            }
                        }
                    }
                }
            } header: {
                Text("界面布局")
            } footer: {
                Text("iPad 布局包含标签侧边栏、书签栏和双栏内容；系统 Split View / Stage Manager 调整窗口大小时，自动模式会按宽度切换。硬件键盘快捷键见菜单栏「浏览器」。")
            }

            Section {
                Toggle("全局顶部保护", isOn: Binding(
                    get: { env.settings.preferences.topProtectionEnabled },
                    set: { value in env.settings.update { $0.topProtection = value } }
                ))
            } header: {
                Text("页面显示")
            } footer: {
                Text("开启后，页面内容只从系统状态栏下方开始，不再滚动到时钟底下。")
            }
        }
        .navigationTitle("通用")
        .navigationBarTitleDisplayMode(.inline)
    }
}
