//
//  SiteDisplaySettingsView.swift
//  Vela
//
//  The 桌面网站 screen: how pages are laid out, separate from the identifier.
//
//  It used to live inside 网页标识, which made a user-agent preset look like
//  it also changed the page layout. The two are different questions — what the
//  site is told, and how the document is laid out — and each now has its own
//  screen. The menu's 桌面网站 tile is the per-site quick control; this screen
//  owns the default and the list of answers already given.
//

import SwiftUI

struct SiteDisplaySettingsView: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.browserPalette) private var palette

    private var settings: SettingsService { env.settings }

    var body: some View {
        List {
            Section {
                Picker("默认显示", selection: Binding(
                    get: { settings.siteDisplayDefault },
                    set: { value in
                        settings.siteDisplayDefault = value
                        apply()
                    }
                )) {
                    ForEach(BrowserSiteDisplayDefault.allCases) { option in
                        Text(option.title).tag(option)
                    }
                }
                .pickerStyle(.inline)
                .labelsHidden()
            } header: {
                Text("默认")
            } footer: {
                Text("没有单独设置的网站使用这个选择。自动模式跟随设备：iPhone 手机版，iPad 与 Mac 桌面版。标识设为「自动」时会跟着这个选择选匹配的字符串；在网页标识里手动选定的字符串不会被改写。")
            }

            Section {
                Toggle("桌面版按桌面宽度排版", isOn: Binding(
                    get: { env.settings.preferences.desktopViewportEnabled ?? true },
                    set: { value in
                        env.settings.update { $0.desktopViewportEnabled = value }
                        apply()
                    }
                ))
                .tint(palette.accent)
            } header: {
                Text("桌面排版")
            } footer: {
                Text("桌面版下把 width=device-width 的页面按 1200 的桌面宽度排版并等比缩放，让 768–1024 宽的 iPad 也进入桌面断点。个别网站排版异常时可关闭。")
            }

            Section {
                if settings.siteDisplay.modes.isEmpty {
                    Text("没有单独的网站设置。")
                        .font(.footnote)
                        .foregroundStyle(palette.secondaryText)
                } else {
                    ForEach(settings.siteDisplay.sortedHosts) { entry in
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
                        let current = settings.siteDisplay.sortedHosts
                        let removing = offsets.compactMap { index in
                            current.indices.contains(index) ? current[index].host : nil
                        }
                        for host in removing {
                            env.settings.setSiteDisplayMode(nil, forPageHost: host)
                        }
                        apply()
                    }

                    Button("清除所有站点设置", role: .destructive) {
                        settings.clearSiteDisplayModes()
                        apply()
                    }
                }
            } header: {
                Text("按站点设置")
            } footer: {
                Text("在菜单的「桌面网站」里切换当前网站；长按该图标可恢复自动。")
            }
        }
        .navigationTitle("桌面网站")
        .navigationBarTitleDisplayMode(.inline)
        .settingsList()
    }

    /// Re-applies the choice to the open pages. A layout and an identifier
    /// only reach WebKit on the next request, so the active tab reloads to
    /// make the change visible; every other tab picks it up when it navigates.
    private func apply() {
        env.tabManager.applyUserAgentToAllWebViews()
        guard let tab = env.tabManager.activeTab else { return }
        _ = env.tabManager.reload(tab: tab)
    }
}
