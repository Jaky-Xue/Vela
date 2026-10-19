//
//  WebRTCProtectionSettingsView.swift
//  Vela
//
//  The WebRTC leak-protection policy.
//
//  This is a browser-level policy rather than a per-site permission: a page can
//  open a peer connection from any frame, and there is no prompt at which to
//  ask the user about each one. The modes are explained in place, because the
//  trade-off (relay-only can break calls; blocked removes the API) is the
//  setting.
//

import SwiftUI

struct WebRTCProtectionSettingsView: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.browserPalette) private var palette

    private var mode: WebRTCProtectionMode { env.settings.webRTCProtection }

    var body: some View {
        List {
            Section {
                ForEach(WebRTCProtectionMode.allCases) { option in
                    Button {
                        apply(option)
                    } label: {
                        HStack(alignment: .top, spacing: 12) {
                            Image(systemName: option.symbolName)
                                .font(.system(size: 15, weight: .semibold))
                                .foregroundStyle(option == mode ? palette.onAccent : palette.accent)
                                .frame(width: 34, height: 34)
                                .background(
                                    option == mode ? palette.accent : palette.accent.opacity(0.13),
                                    in: RoundedRectangle(cornerRadius: 9, style: .continuous)
                                )

                            VStack(alignment: .leading, spacing: 3) {
                                Text(option.displayName)
                                    .foregroundStyle(palette.primaryText)
                                Text(option.summary)
                                    .font(.caption2)
                                    .foregroundStyle(palette.secondaryText)
                                    .fixedSize(horizontal: false, vertical: true)
                            }

                            Spacer(minLength: 6)

                            if option == mode {
                                Image(systemName: "checkmark")
                                    .foregroundStyle(palette.accent)
                            }
                        }
                        .padding(.vertical, 2)
                    }
                    .buttonStyle(.plain)
                }
            } header: {
                Text("WebRTC 泄露防护")
            } footer: {
                Text("防护脚本在每个 frame 的文档开始时安装，先于网页自己的脚本。修改后会重新载入当前页面。")
            }

            Section("说明") {
                LabeledContent("当前模式", value: mode.displayName)
                Text("「防泄露」过滤带私有地址的 host 候选；「仅中继」强制 relay，需要网站自己的 TURN 服务；「完全禁用」会让依赖 WebRTC 的网页功能失效。本机地址必须完全不出现在任何信令中时，请选择「仅中继」。")
                    .font(.footnote)
                    .foregroundStyle(palette.secondaryText)
            }
        }
        .navigationTitle("WebRTC 泄露防护")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func apply(_ option: WebRTCProtectionMode) {
        guard option != mode else { return }
        env.settings.webRTCProtection = option
        if let tab = env.tabManager.activeTab, !tab.isHome {
            _ = env.tabManager.reload(tab: tab)
        }
    }
}
