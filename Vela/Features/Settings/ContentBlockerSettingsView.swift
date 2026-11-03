//
//  ContentBlockerSettingsView.swift
//  Vela
//
//  The 广告拦截 screen: the switch, the compiled rule count, and the sites
//  that are allowed to load their ads anyway.
//

import SwiftUI

struct ContentBlockerSettingsView: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.browserPalette) private var palette

    private var settings: ContentBlockerSettings { env.settings.contentBlocker }
    private var blocker: ContentBlocker { env.services.contentBlocker }

    /// The site in front of the settings sheet, as a whitelist candidate.
    private var activeHost: String? {
        guard let tab = env.tabManager.activeTab,
              let host = URL(string: tab.url)?.host,
              !host.isEmpty else { return nil }
        return host
    }

    var body: some View {
        List {
            Section {
                Toggle("广告与跟踪器拦截", isOn: Binding(
                    get: { settings.enabled },
                    set: { value in
                        env.settings.updateContentBlocker { $0.enabled = value }
                        env.applyContentBlockerSettings()
                    }
                ))
                .tint(palette.accent)
            } header: {
                Text("拦截")
            } footer: {
                Text("使用内置规则拦截常见广告、统计与跟踪请求，并隐藏页面里的广告位。规则在启动时编译，只作用于启用之后发出的请求。")
            }

            Section {
                LabeledContent("规则数量") {
                    Text(blocker.isReady ? "\(blocker.ruleCount) 条" : "编译中…")
                        .foregroundStyle(palette.secondaryText)
                }
                if let loadedAt = blocker.loadedAt {
                    LabeledContent("上次编译") {
                        Text(loadedAt.formatted(date: .omitted, time: .shortened))
                            .foregroundStyle(palette.secondaryText)
                    }
                }
                if let error = blocker.lastError, !error.isEmpty {
                    Text(error)
                        .font(.footnote)
                        .foregroundStyle(.red)
                }
                Button {
                    blocker.prepare()
                } label: {
                    Label("重新编译规则", systemImage: "arrow.clockwise")
                }
                .disabled(blocker.isCompiling)
            } header: {
                Text("规则")
            } footer: {
                Text("WebKit 不报告具体拦下了哪些请求，所以这里只显示实际编译进来的规则条数，不编造拦截次数。")
            }

            Section {
                if settings.whitelistedHosts.isEmpty {
                    Text("没有例外站点。")
                        .font(.footnote)
                        .foregroundStyle(palette.secondaryText)
                } else {
                    ForEach(settings.whitelistedHosts, id: \.self) { host in
                        Text(host)
                            .font(.footnote)
                    }
                    .onDelete { offsets in
                        let hosts = settings.whitelistedHosts
                        env.settings.updateContentBlocker { preferences in
                            preferences.whitelistedHosts.removeAll { host in
                                guard let index = hosts.firstIndex(of: host) else { return false }
                                return offsets.contains(index)
                            }
                        }
                        env.applyContentBlockerSettings()
                    }
                }

                Button {
                    addActiveSite()
                } label: {
                    Label("将当前网站加入白名单", systemImage: "plus.circle")
                }
                .disabled(activeHost == nil || isWhitelisted(activeHost))
            } header: {
                Text("不拦截的网站")
            } footer: {
                Text("白名单里的网站按原样加载，不做任何拦截；匹配包含其子域名。")
            }
        }
        .navigationTitle("广告拦截")
        .navigationBarTitleDisplayMode(.inline)
        .settingsList()
    }

    private func isWhitelisted(_ host: String?) -> Bool {
        guard let host else { return false }
        return settings.isExcepted(host: host)
    }

    private func addActiveSite() {
        guard let host = activeHost else { return }
        let normalized = BrowserSiteHost.normalize(host)
        guard !normalized.isEmpty else { return }
        env.settings.updateContentBlocker { preferences in
            if !preferences.whitelistedHosts.contains(normalized) {
                preferences.whitelistedHosts.append(normalized)
            }
        }
        env.applyContentBlockerSettings()
    }
}
