//
//  UserAgentSettingsView.swift
//  Vela
//
//  The 网页标识 screen: the string pages read, and the layout it brings.
//
//  The identifier is the whole answer. A desktop string lays the document out
//  as a desktop one, a mobile string as a mobile one, and the automatic preset
//  follows the device — there is no separate layout switch to fall out of step
//  with the string. Per-site answers are listed on this screen too, because
//  they are per-site identifiers, not a second display setting.
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

    /// The string the next request will actually carry, computed the way the
    /// web view computes it — through `BrowserUserAgent.identity`, which is
    /// the one place that answers the question. Reading the stored fields
    /// directly instead is what let this row show the mobile identifier while
    /// pages were receiving the desktop one.
    private var effectiveOutgoingIdentity: BrowserWebIdentity {
        BrowserUserAgent.identity(
            custom: env.settings.preferences.customUserAgent,
            prefersDesktop: false
        )
    }

    private var effectiveOutgoingIdentifier: String {
        if let custom = effectiveOutgoingIdentity.customUserAgent {
            return custom
        }
        // WebKit builds its own identifier when there is no override. Show the
        // one for the layout the identity chose rather than always the
        // device's form: a mobile preset on an iPad asks for the phone page.
        if effectiveOutgoingIdentity.isDesktop {
            return BrowserUserAgent.desktopIdentifier
        }
        switch BrowserDeviceClass.current {
        case .phone: return BrowserUserAgent.mobileIdentifier
        case .pad: return BrowserUserAgent.padIdentifier
        case .mac: return BrowserUserAgent.desktopIdentifier
        }
    }

    var body: some View {
        List {
            Section {
                presetRow(BrowserUserAgentPreset.all[0])
            } header: {
                Text("自动")
            } footer: {
                Text("标识决定网站看到的浏览器字符串，也决定页面按桌面版还是手机版排版。自动模式跟随设备：iPhone 为手机版，iPad 与 Mac 为桌面版；选了桌面端标识就按桌面版排版。")
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
                    // The per-site choices live in their own section and are
                    // left where the user put them.
                    env.settings.update { $0.customUserAgent = "" }
                    apply(reload: true)
                }
            } header: {
                Text("自定义标识")
            }

            Section {
                Toggle("桌面版按桌面宽度排版", isOn: Binding(
                    get: { env.settings.preferences.desktopViewportEnabled ?? true },
                    set: { value in
                        env.settings.update { $0.desktopViewportEnabled = value }
                        apply(reload: true)
                    }
                ))
                .tint(palette.accent)
            } header: {
                Text("桌面排版")
            } footer: {
                Text("桌面版下把 width=device-width 的页面按 1200 的桌面宽度排版并等比缩放，让 768–1024 宽的 iPad 也进入桌面断点。个别网站排版异常时可关闭。")
            }

            Section {
                if env.settings.siteDisplay.modes.isEmpty {
                    Text("没有单独的网站设置。")
                        .font(.footnote)
                        .foregroundStyle(palette.secondaryText)
                } else {
                    ForEach(env.settings.siteDisplay.sortedHosts) { entry in
                        HStack {
                            Text(entry.host)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Spacer(minLength: 8)
                            Text(entry.mode.title)
                                .foregroundStyle(palette.secondaryText)
                        }
                        .font(.footnote)
                    }
                    .onDelete { offsets in
                        let current = env.settings.siteDisplay.sortedHosts
                        let removing = offsets.compactMap { index in
                            current.indices.contains(index) ? current[index].host : nil
                        }
                        for host in removing {
                            env.settings.setSiteDisplayMode(nil, forPageHost: host)
                        }
                        apply(reload: true)
                    }

                    Button("清除所有站点设置", role: .destructive) {
                        env.settings.clearSiteDisplayModes()
                        apply(reload: true)
                    }
                }
            } header: {
                Text("按站点")
            } footer: {
                Text("在菜单的「桌面网站」里切换当前网站；长按该图标可恢复自动。")
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
            }

        }
        .navigationTitle("网页标识")
        .navigationBarTitleDisplayMode(.inline)
        .settingsList()
    }

    /// One preset row with the reference screen's radio affordance: an empty
    /// ring for the choices not taken, a filled check for the one in force —
    /// and, under the title, what the identifier claims, so a choice can be
    /// read before it is taken rather than only after.
    private func presetRow(_ preset: BrowserUserAgentPreset) -> some View {
        let isSelected = selectedPreset?.id == preset.id
        return Button {
            // The preset carries its own layout: choosing a desktop string
            // lays the page out as a desktop document.
            env.settings.update { $0.customUserAgent = preset.userAgent ?? "" }
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
                    .foregroundStyle(isSelected ? palette.accent : palette.secondaryText.opacity(0.55))
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
