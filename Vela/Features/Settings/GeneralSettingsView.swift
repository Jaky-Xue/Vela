//
//  GeneralSettingsView.swift
//  Vela
//
//  Startup, tab and history retention, interface layout, and page display.
//
//  Three sections, each a place the setting acts on. Nothing here explains
//  itself in a paragraph: a toggle is named for what it does, a picker shows
//  the options, and the layout choices are their own pictures.
//

import SwiftUI
import UIKit

// MARK: - General

struct GeneralSettingsView: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.browserPalette) private var palette

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
                .disabled(env.settings.preferences.tabsNotRetained ?? false)

                Toggle("在后台打开新标签页", isOn: Binding(
                    get: { env.settings.preferences.openNewTabsInBackground },
                    set: { value in env.settings.update { $0.openNewTabsInBackground = value } }
                ))
            } header: {
                Text("启动")
            }

            Section {
                Toggle("不保留标签页", isOn: Binding(
                    get: { env.settings.preferences.tabsNotRetained ?? false },
                    set: { value in env.setTabsNotRetained(value) }
                ))

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
                Text("保留")
            }

            Section {
                ForEach(InterfaceLayoutMode.allCases) { mode in
                    Button {
                        env.settings.interfaceLayout = mode
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: mode.symbolName)
                                .font(.system(size: 15, weight: .semibold))
                                .foregroundStyle(
                                    env.settings.interfaceLayout == mode
                                        ? palette.accent
                                        : palette.secondaryText
                                )
                                .frame(width: 26)

                            Text(mode.displayName)
                                .foregroundStyle(palette.primaryText)

                            Spacer(minLength: 0)

                            if env.settings.interfaceLayout == mode {
                                Image(systemName: "checkmark")
                                    .font(.system(size: 13, weight: .semibold))
                                    .foregroundStyle(palette.accent)
                            }
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }

                Toggle(isOn: Binding(
                    get: { env.settings.preferences.forcedZoomEnabled ?? false },
                    set: { value in
                        env.settings.update { $0.forcedZoomEnabled = value }
                        env.tabManager.applyGestureZoomToAllWebViews()
                    }
                )) {
                    Text("允许双指缩放")
                }

                Toggle("全局顶部保护", isOn: Binding(
                    get: { env.settings.preferences.topProtectionEnabled },
                    set: { value in env.settings.update { $0.topProtection = value } }
                ))
            } header: {
                Text("界面与显示")
            }
        }
        .navigationTitle("通用")
        .navigationBarTitleDisplayMode(.inline)
        .settingsList()
    }
}
