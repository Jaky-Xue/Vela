//
//  PrivateBrowsingSettingsView.swift
//  Vela
//
//  无痕模式's own page: the identity check, the preview blur, and what the
//  mode does and does not keep.
//
//  These switches used to sit under 外观 because the mode changes what is on
//  screen, but they are a privacy decision rather than a look: the lock is the
//  difference between "quickly hide a page" and "a page nobody else can open".
//  The privacy group of 设置 is where a user looks for that.
//

import SwiftUI

struct PrivateBrowsingSettingsView: View {
    @Environment(AppEnvironment.self) private var env
    @State private var lockError: String?

    var body: some View {
        List {
            Section {
                // Turning the lock off is itself a security decision, so it
                // asks for the same check it is removing. Turning it on does
                // not: adding protection cannot expose anything.
                Toggle("查看无痕标签页需要验证身份", isOn: Binding(
                    get: { env.settings.preferences.lockPrivateTabs },
                    set: { value in
                        guard !value, env.settings.preferences.lockPrivateTabs else {
                            env.settings.update { $0.lockPrivateTabs = value }
                            return
                        }
                        Task { @MainActor in
                            switch await env.requestPrivateAccess(reason: "关闭无痕验证") {
                            case .granted:
                                env.settings.update { $0.lockPrivateTabs = false }
                                env.lockPrivateAccess()
                            case .cancelled:
                                break
                            case .unavailable:
                                lockError = "此设备未设置密码或面容 ID / 触控 ID，无法验证身份；验证仍然开启。"
                            case .failed:
                                lockError = "验证未通过，验证仍然开启。"
                            }
                        }
                    }
                ))
            } header: {
                Text("身份验证")
            } footer: {
                Text("开启后，查看无痕标签页、切换无痕模式、从侧边栏进入无痕列表，都会先通过系统的面容 ID、触控 ID 或设备密码。验证只在应用处于前台时有效，退到后台或结束无痕会话后会重新锁定。")
            }

            Section {
                Toggle("模糊无痕标签页预览", isOn: Binding(
                    get: { env.settings.preferences.blurPrivateTabPreviews },
                    set: { value in env.settings.update { $0.blurPrivateTabPreviews = value } }
                ))
            } header: {
                Text("标签页预览")
            } footer: {
                Text("模糊的是标签卡里的网页截图，卡片本身和关闭按钮保持清晰。无痕标签卡不显示页面标题。")
            }

            Section {
                LabeledContent("无痕模式", value: (env.settings.preferences.privateBrowsingMode ?? false) ? "已开启" : "已关闭")
                LabeledContent("当前", value: env.requiresPrivateAuthentication ? "已锁定" : "已验证")
            } header: {
                Text("当前状态")
            } footer: {
                Text("无痕标签页只存在于本次前台会话：退到后台或离开无痕模式时，标签页和网页数据都会被清除。")
            }
        }
        .navigationTitle("无痕模式")
        .navigationBarTitleDisplayMode(.inline)
        .browserListSurface()
        .alert(
            "无法关闭验证",
            isPresented: Binding(
                get: { lockError != nil },
                set: { if !$0 { lockError = nil } }
            ),
            presenting: lockError
        ) { _ in
            Button("好", role: .cancel) { lockError = nil }
        } message: { message in
            Text(message)
        }
    }
}
