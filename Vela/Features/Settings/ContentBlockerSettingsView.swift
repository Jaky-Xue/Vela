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

    /// A site typed into the whitelist field. The active tab is not always a
    /// page — opening 设置 from the home leaves no host to add — so the list
    /// needs a way in that does not depend on what is behind the sheet.
    @State private var newHost = ""
    @State private var showAddHost = false

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
                Text("过滤广告与跟踪请求。规则变更后刷新网页。")
            }

            Section {
                LabeledContent("规则数量") {
                    Text(ruleCountText)
                        .foregroundStyle(palette.secondaryText)
                }
                LabeledContent("元素隐藏规则", value: "\(blocker.hiddenRuleCount)")
                LabeledContent("跳过规则", value: "\(blocker.skippedRuleCount)")
                if blocker.lastError != nil && blocker.isReady {
                    Text("使用缓存").font(.footnote)
                }
                if let loadedAt = blocker.loadedAt {
                    LabeledContent("上次编译") {
                        Text(loadedAt.formatted(date: .omitted, time: .shortened))
                            .foregroundStyle(palette.secondaryText)
                    }
                }
                if let error = blocker.lastError, !error.isEmpty {
                    DisclosureGroup("错误详情") { Text(error).font(.footnote) }
                }
                NavigationLink {
                    FilterSourcesSettingsView()
                } label: {
                    SettingsActionLabel(title: "过滤规则", systemImage: "line.3.horizontal.decrease.circle")
                }
                Button {
                    blocker.prepare()
                } label: {
                    SettingsActionLabel(title: "更新规则", systemImage: "arrow.clockwise")
                }
                .disabled(blocker.isCompiling)
            } header: {
                Text("规则")
            } footer: {
                Text("显示已加载规则数。")
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
                        let current = settings.whitelistedHosts
                        let removing = offsets.compactMap { index in
                            current.indices.contains(index) ? current[index] : nil
                        }
                        env.settings.updateContentBlocker { preferences in
                            preferences.whitelistedHosts.removeAll { removing.contains($0) }
                        }
                        env.applyContentBlockerSettings()
                    }
                }

                Button {
                    newHost = ""; showAddHost = true
                } label: {
                    SettingsActionLabel(title: "添加网站", systemImage: "plus")
                }

                Button {
                    addActiveSite()
                } label: {
                    SettingsActionLabel(title: "添加当前网站", systemImage: "plus.circle")
                }
                .disabled(activeHost == nil || isWhitelisted(activeHost))
            } header: {
                Text("不拦截的网站")
            } footer: {
                Text("包含子域名；手动隐藏单独管理。")
            }
        }
        .navigationTitle("广告拦截")
        .navigationBarTitleDisplayMode(.inline)
        .settingsList()
        .sheet(isPresented: $showAddHost) {
            NavigationStack {
                List {
                    SettingsInputRow(title: "网站域名", prompt: "example.com", text: $newHost, keyboard: .URL)
                    if !newHost.isEmpty && normalizedNewHost == nil { Text("域名无效").foregroundStyle(.orange) }
                }.settingsList().navigationTitle("添加网站").navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("取消") { showAddHost = false } }
                    ToolbarItem(placement: .confirmationAction) { Button("添加") { addEnteredSite(); showAddHost = false }.disabled(!canAddEnteredSite) }
                }
            }
        }
    }

    /// The count, or the state that explains why there is no count yet. An
    /// error is not "编译中" — saying so would leave the screen waiting for a
    /// compile that already failed.
    private var ruleCountText: String {
        if blocker.isReady { return "\(blocker.ruleCount) 条" }
        if blocker.isCompiling { return "编译中…" }
        return "未就绪"
    }

    private func isWhitelisted(_ host: String?) -> Bool {
        guard let host else { return false }
        return settings.isExcepted(host: host)
    }

    /// The typed field, normalised, or nil when it does not look like a site.
    /// A bare word is a search term, not a host; accepting it would put a row
    /// on the list that can never match a page.
    private var normalizedNewHost: String? {
        let normalized = BrowserSiteHost.normalize(newHost)
        guard !normalized.isEmpty,
              !normalized.contains(" "),
              normalized == "localhost" || normalized.contains(".") else {
            return nil
        }
        return normalized
    }

    private var canAddEnteredSite: Bool {
        guard let host = normalizedNewHost else { return false }
        return !settings.isExcepted(host: host)
    }

    private func addEnteredSite() {
        guard let host = normalizedNewHost, !settings.isExcepted(host: host) else { return }
        addSite(host)
        newHost = ""
    }

    private func addActiveSite() {
        guard let host = activeHost else { return }
        addSite(host)
    }

    private func addSite(_ rawHost: String) {
        let normalized = BrowserSiteHost.normalize(rawHost)
        guard !normalized.isEmpty else { return }
        env.settings.updateContentBlocker { preferences in
            if !preferences.whitelistedHosts.contains(normalized) {
                preferences.whitelistedHosts.append(normalized)
            }
        }
        env.applyContentBlockerSettings()
    }
}
