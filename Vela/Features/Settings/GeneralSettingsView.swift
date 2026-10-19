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
            } header: {
                Text("启动与标签页")
            }

            Section {
                Picker("保留时长", selection: Binding(
                    get: { env.settings.preferences.historyRetentionDays },
                    set: { value in env.settings.update { $0.historyRetentionDays = value } }
                )) {
                    ForEach(Self.retentionChoices, id: \.1) { choice in
                        Text(choice.0).tag(choice.1)
                    }
                }
            } header: {
                Text("历史记录保留")
            } footer: {
                Text("超过保留期的记录会在下次访问时清理。")
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
