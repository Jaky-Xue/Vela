//
//  UserAgentSettingsView.swift
//  Vela
//
//  The 网页标识 screen: desktop, mobile, and custom user-agent presets.
//

import SwiftUI
import UIKit

// MARK: - User agent

struct UserAgentSettingsView: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.browserPalette) private var palette

    /// Flips on when the copy button is pressed, off again shortly after —
    /// the button's own confirmation.
    @State private var didCopyIdentity = false

    /// The preset currently in force: the match for the stored custom string,
    /// or the default when none is stored. A stored string that matches no
    /// preset was typed by hand and is reported as such.
    private var selectedPreset: BrowserUserAgentPreset? {
        let stored = env.settings.preferences.customUserAgent
        guard !stored.isEmpty else { return BrowserUserAgentPreset.all[0] }
        return BrowserUserAgentPreset.all.first { $0.userAgent == stored }
    }

    /// The name of what is in force. With the desktop-site toggle on and no
    /// preset chosen, the identity is Vela's default in its desktop form —
    /// saying just 「Vela 默认」 there would contradict the string below it.
    private var effectivePresetTitle: String {
        guard let preset = selectedPreset else { return "自定义" }
        if preset.id == BrowserUserAgentPreset.all[0].id,
           env.settings.preferences.customUserAgent.isEmpty,
           env.settings.preferences.desktopSiteByDefault {
            return "\(preset.title) · 桌面版"
        }
        return preset.title
    }

    /// The string the next request will actually carry, computed the way the
    /// web view computes it — through `BrowserUserAgent.identity`, which is
    /// the one place that answers the question. Reading the stored fields
    /// directly instead is what let this row show the mobile identifier while
    /// pages were receiving the desktop one.
    private var effectiveOutgoingIdentifier: String {
        let identity = BrowserUserAgent.identity(
            custom: env.settings.preferences.customUserAgent,
            prefersDesktop: env.settings.preferences.desktopSiteByDefault
        )
        return identity.customUserAgent
            ?? (env.settings.preferences.desktopSiteByDefault
                ? BrowserUserAgent.desktopIdentifier
                : BrowserUserAgent.deviceIdentifier)
    }

    var body: some View {
        List {
            Section {
                HStack {
                    Text("默认网页标识")
                    Spacer(minLength: 8)
                    Text(effectivePresetTitle)
                        .foregroundStyle(.secondary)
                }
            } footer: {
                Text("选择后，之后打开的页面都会以它出现。视频网站（如 YouTube）始终使用移动版 Safari 标识，以保证播放与字幕可用。")
            }

            Section {
                presetRow(BrowserUserAgentPreset.all[0])
            } header: {
                Text("自动")
            } footer: {
                Text("初始使用当前设备对应的标识：iPhone 用手机版，iPad 用平板版，Mac 用桌面版。手动选择下面的预设或填写自定义标识会覆盖它。")
            }

            Section("移动端网页") {
                ForEach(BrowserUserAgentPreset.all.filter {
                    !$0.isDesktop && $0.id != BrowserUserAgentPreset.all[0].id
                }) { preset in
                    presetRow(preset)
                }
            }

            Section("桌面端网页") {
                ForEach(BrowserUserAgentPreset.all.filter { $0.isDesktop }) { preset in
                    presetRow(preset)
                }
            }

            Section {
                TextField("自定义 User-Agent", text: Binding(
                    get: { env.settings.preferences.customUserAgent },
                    set: { value in
                        env.settings.update { $0.customUserAgent = value }
                        apply(reload: false)
                    }
                ), axis: .vertical)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .font(.system(size: 13, design: .monospaced))
                .lineLimit(3...6)

                Button("恢复默认") {
                    env.settings.update {
                        $0.customUserAgent = ""
                        $0.desktopSiteByDefault = false
                    }
                    apply(reload: true)
                }
            } header: {
                Text("自定义标识")
            } footer: {
                Text("填写后覆盖上面选择的预设。")
            }

            Section {
                Text(effectiveOutgoingIdentifier)
                    .font(.system(size: 12, design: .monospaced))
                    .textSelection(.enabled)
                    .foregroundStyle(palette.primaryText)
                    .frame(maxWidth: .infinity, alignment: .leading)

                Button {
                    UIPasteboard.general.string = effectiveOutgoingIdentifier
                    // The button is what confirms the copy; without a state
                    // change the tap reads as having done nothing.
                    didCopyIdentity = true
                    Task {
                        try? await Task.sleep(nanoseconds: 1_600_000_000)
                        didCopyIdentity = false
                    }
                } label: {
                    Label(
                        didCopyIdentity ? "已复制" : "复制标识",
                        systemImage: didCopyIdentity ? "checkmark" : "doc.on.doc"
                    )
                }
            } header: {
                Text("当前标识")
            } footer: {
                Text("这是下一个页面请求实际会携带的字符串。")
            }
        }
        .navigationTitle("网页标识")
        .navigationBarTitleDisplayMode(.inline)
    }

    /// One preset row with the reference screen's radio affordance: an empty
    /// ring for the choices not taken, a filled check for the one in force —
    /// and, under the title, what the identifier claims, so a choice can be
    /// read before it is taken rather than only after.
    private func presetRow(_ preset: BrowserUserAgentPreset) -> some View {
        let isSelected = selectedPreset?.id == preset.id
        return Button {
            env.settings.update {
                $0.customUserAgent = preset.userAgent ?? ""
                // The automatic preset means "the device's own identity"; a
                // stored desktop toggle from the menu must not quietly turn it
                // into the desktop one.
                $0.desktopSiteByDefault = preset.isDesktop
            }
            apply(reload: true)
        } label: {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text(preset.title)
                        .foregroundStyle(palette.primaryText)
                    Text(preset.claimedSummary)
                        .font(.footnote)
                        .foregroundStyle(palette.secondaryText)
                        .lineLimit(1)
                }
                Spacer(minLength: 8)
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 20, weight: .light))
                    .foregroundStyle(isSelected ? Color.blue : Color.secondary.opacity(0.55))
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// Pushes the identifier onto every open tab, and reloads the active one when
    /// the change should be visible at once.
    ///
    /// A `User-Agent` only takes effect on the next request, so without this the
    /// screen would save a value that nothing reads until the user happened to
    /// navigate again — which is exactly how it behaved before.
    private func apply(reload: Bool) {
        env.tabManager.applyUserAgentToAllWebViews()
        guard reload, let tab = env.tabManager.activeTab else { return }
        _ = env.tabManager.reload(tab: tab)
    }
}
