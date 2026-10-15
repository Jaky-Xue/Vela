//
//  SettingsSubpages.swift
//  Vela
//
//  The settings destinations past the main list: ad blocking, secure DNS, default
//  site permissions, external navigation, site controls, downloads, and clearing
//  site data.
//

import SwiftUI
import WebKit

// MARK: - Ad block

struct AdBlockSettingsView: View {
    @Environment(AppEnvironment.self) private var env

    @State private var newRule = ""
    @State private var updatingSourceId: String?

    var body: some View {
        List {
            Section {
                Toggle("启用广告与内容过滤", isOn: Binding(
                    get: { env.settings.adBlockSettings.preferences.enabled },
                    set: { value in
                        env.settings.setAdBlockEnabled(value)
                        Task { await env.refreshAdBlockRules() }
                    }
                ))
                Toggle("隐藏页面元素", isOn: Binding(
                    get: { env.settings.adBlockSettings.preferences.cosmeticFilteringEnabled },
                    set: { value in
                        env.settings.update { $0.adBlock.preferences.cosmeticFilteringEnabled = value }
                        Task { await env.refreshAdBlockRules() }
                    }
                ))
            } footer: {
                Text("关闭元素隐藏只会停止过滤页面内的广告位，请求拦截仍然生效。")
            }

            Section {
                LabeledContent("已加载规则") {
                    Text("\(env.adBlock.ruleCount)")
                        .monospacedDigit()
                }
                LabeledContent("隐藏选择器") {
                    Text("\(env.adBlock.cosmeticSelectors.count)")
                        .monospacedDigit()
                }
                if env.adBlock.unsupportedRuleCount > 0 {
                    LabeledContent("规则集中无法表达") {
                        Text("\(env.adBlock.unsupportedRuleCount)")
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                }
                if env.adBlock.lastPageHiddenCount > 0 {
                    LabeledContent("当前页面隐藏") {
                        Text("\(env.adBlock.lastPageHiddenCount) 个元素")
                            .monospacedDigit()
                    }
                }
            } header: {
                Text("过滤状态")
            } footer: {
                Text("系统不提供被拦截请求的计数，因此这里显示的是规则条数和实际隐藏的元素数。规则集中无法用系统接口表达的条目会被跳过，数量显示在上方。")
            }

            Section {
                ForEach(env.settings.adBlockSettings.ruleSources) { source in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(source.name)
                            if !source.lastError.isEmpty {
                                Text(source.lastError)
                                    .font(.caption)
                                    .foregroundStyle(.red)
                            } else if let updated = source.lastUpdatedAt {
                                Text("更新于 \(updated.formatted(date: .abbreviated, time: .shortened))")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            } else if source.sourceType == .system {
                                Text("随 App 内置")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            } else {
                                Text("尚未下载")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        Spacer()
                        if updatingSourceId == source.id {
                            ProgressView()
                        }
                        Toggle("", isOn: Binding(
                            get: { source.enabled },
                            set: { value in
                                env.settings.setRuleSourceEnabled(value, sourceId: source.id)
                                Task { await env.refreshAdBlockRules() }
                            }
                        ))
                        .labelsHidden()
                    }
                    .swipeActions(edge: .leading, allowsFullSwipe: true) {
                        if source.sourceType == .remote {
                            Button {
                                updatingSourceId = source.id
                                Task {
                                    await env.updateAdBlockSource(id: source.id)
                                    updatingSourceId = nil
                                }
                            } label: {
                                Label("更新", systemImage: "arrow.clockwise")
                            }
                            .tint(.blue)
                        }
                    }
                }

                Menu {
                    ForEach(AdBlockCustomRuleSource.catalog.filter { candidate in
                        !env.settings.adBlockSettings.ruleSources.contains { $0.id == candidate.id }
                    }) { candidate in
                        Button(candidate.name) {
                            var sources = env.settings.adBlockSettings.ruleSources
                            sources.append(candidate)
                            env.settings.update { $0.adBlock.ruleSources = sources }
                            Task { await env.updateAdBlockSource(id: candidate.id) }
                        }
                    }
                } label: {
                    Label("添加订阅规则", systemImage: "plus")
                }
            } header: {
                Text("规则来源")
            }

            Section {
                ForEach(env.settings.adBlockSettings.preferences.siteExceptions) { exception in
                    HStack {
                        Text(exception.host)
                        Spacer()
                        Button {
                            env.settings.removeAdBlockSiteException(host: exception.host)
                            Task { await env.refreshAdBlockRules() }
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .onDelete { offsets in
                    for index in offsets {
                        let host = env.settings.adBlockSettings.preferences.siteExceptions[index].host
                        env.settings.removeAdBlockSiteException(host: host)
                    }
                    Task { await env.refreshAdBlockRules() }
                }
            } header: {
                Text("不做过滤的网站")
            } footer: {
                Text("在某个网站上关闭过滤后，该网站会被加入这里。")
            }

            Section {
                ForEach(env.settings.adBlockSettings.preferences.localRules, id: \.self) { rule in
                    Text(rule)
                        .font(.system(size: 13, design: .monospaced))
                }
                .onDelete { offsets in
                    var rules = env.settings.adBlockSettings.preferences.localRules
                    rules.remove(atOffsets: offsets)
                    env.settings.setLocalAdBlockRules(rules)
                    Task { await env.refreshAdBlockRules() }
                }

                HStack {
                    TextField("例如：||example.com^", text: $newRule)
                        .font(.system(size: 13, design: .monospaced))
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    Button("添加") {
                        let trimmed = newRule.trimmingCharacters(in: .whitespaces)
                        guard !trimmed.isEmpty else { return }
                        var rules = env.settings.adBlockSettings.preferences.localRules
                        rules.append(trimmed)
                        env.settings.setLocalAdBlockRules(rules)
                        newRule = ""
                        Task { await env.refreshAdBlockRules() }
                    }
                    .disabled(newRule.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            } header: {
                Text("自定义规则")
            } footer: {
                Text("支持 Adblock Plus 语法的常见写法，例如 ||example.com^ 拦截整站、##.ad-banner 隐藏元素。")
            }

            Section {
                ForEach(env.settings.manualElementHide.sites) { site in
                    DisclosureGroup {
                        ForEach(site.rules) { rule in
                            Text(rule.selector)
                                .font(.system(size: 12, design: .monospaced))
                                .foregroundStyle(.secondary)
                                .swipeActions {
                                    Button("删除", role: .destructive) {
                                        env.settings.removeManualElementHide(ruleId: rule.id, host: site.host)
                                    }
                                }
                        }
                    } label: {
                        Text(site.host)
                    }
                }
            } header: {
                Text("手动隐藏的页面元素")
            } footer: {
                Text("在页面菜单中选择「隐藏页面元素」，然后点选要去掉的元素。")
            }
        }
        .navigationTitle("广告与内容过滤")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            Task { await env.refreshAdBlockRules() }
        }
    }
}

// MARK: - Privacy

struct PrivacySettingsView: View {
    @Environment(AppEnvironment.self) private var env

    var body: some View {
        List {
            Section {
                ForEach(TrackingProtectionLevel.allCases) { level in
                    Button {
                        env.settings.update { $0.webSecurity.trackingProtection = level }
                    } label: {
                        HStack(alignment: .top, spacing: 12) {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(level.displayName)
                                    .foregroundStyle(.primary)
                                Text(level.detail)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .multilineTextAlignment(.leading)
                            }
                            Spacer(minLength: 0)
                            if env.settings.preferences.webSecurity.trackingProtection == level {
                                Image(systemName: "checkmark")
                                    .foregroundStyle(.tint)
                            }
                        }
                    }
                }
            } header: {
                Text("跟踪保护")
            } footer: {
                Text("iOS 上的第三方 Cookie 拦截由 WebKit 执行，与这里的选择一致。")
            }

            Section {
                Toggle("发送「请勿跟踪」请求", isOn: Binding(
                    get: { env.settings.preferences.webSecurity.sendDoNotTrack },
                    set: { value in env.settings.update { $0.webSecurity.sendDoNotTrack = value } }
                ))
                Toggle("优先使用 HTTPS", isOn: Binding(
                    get: { env.settings.preferences.webSecurity.httpsFirstNavigation },
                    set: { value in env.settings.update { $0.webSecurity.httpsFirstNavigation = value } }
                ))
            } header: {
                Text("浏览安全")
            } footer: {
                Text("「请勿跟踪」依赖网站自觉，多数网站会忽略它。")
            }
        }
        .navigationTitle("跟踪保护")
        .navigationBarTitleDisplayMode(.inline)
    }
}

// MARK: - Secure DNS

struct SecureDnsSettingsView: View {
    @Environment(AppEnvironment.self) private var env

    @State private var showingAddProfile = false
    @State private var newProfileName = ""
    @State private var newProfileTemplate = ""

    var body: some View {
        List {
            Section {
                ForEach(SecureDnsMode.allCases) { mode in
                    Button {
                        env.settings.update { $0.secureDns.mode = mode }
                    } label: {
                        HStack {
                            Text(mode.displayName).foregroundStyle(.primary)
                            Spacer()
                            if env.settings.preferences.secureDns.mode == mode {
                                Image(systemName: "checkmark").foregroundStyle(.tint)
                            }
                        }
                    }
                }
            } header: {
                Text("模式")
            } footer: {
                Text("「自动」由系统选择服务商。自定义服务器需要 iOS 配置描述文件才能对所有网络生效；在 Vela 内它用于 DoH 探测与站点连接信息展示。")
            }

            if env.settings.preferences.secureDns.mode == .secure {
                Section("服务器") {
                    ForEach(env.settings.preferences.secureDns.allProfiles) { profile in
                        Button {
                            env.settings.update { $0.secureDns.selectedProfileId = profile.id }
                        } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(profile.name).foregroundStyle(.primary)
                                    Text(profile.template)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                }
                                Spacer()
                                if env.settings.preferences.secureDns.selectedProfileId == profile.id {
                                    Image(systemName: "checkmark").foregroundStyle(.tint)
                                }
                            }
                        }
                        .swipeActions {
                            if !profile.isBuiltIn {
                                Button("删除", role: .destructive) {
                                    env.settings.update { preferences in
                                        preferences.secureDns.customProfiles.removeAll { $0.id == profile.id }
                                    }
                                }
                            }
                        }
                    }

                    Button("添加自定义服务器", systemImage: "plus") {
                        newProfileName = ""
                        newProfileTemplate = ""
                        showingAddProfile = true
                    }
                }
            }
        }
        .navigationTitle("安全 DNS")
        .navigationBarTitleDisplayMode(.inline)
        .alert("添加 DNS 服务器", isPresented: $showingAddProfile) {
            TextField("名称", text: $newProfileName)
            TextField("https://example.com/dns-query", text: $newProfileTemplate)
            Button("取消", role: .cancel) {}
            Button("添加") {
                let name = newProfileName.trimmingCharacters(in: .whitespaces)
                let template = newProfileTemplate.trimmingCharacters(in: .whitespaces)
                guard !name.isEmpty, template.hasPrefix("https://") else { return }
                env.settings.update { preferences in
                    preferences.secureDns.customProfiles.append(
                        SecureDnsProfile(id: UUID().uuidString, name: name, template: template)
                    )
                }
            }
        }
    }
}

// MARK: - Site permissions

struct SitePermissionsSettingsView: View {
    @Environment(AppEnvironment.self) private var env

    var body: some View {
        List {
            Section {
                ForEach(SitePermissionKind.allCases) { kind in
                    Picker(kind.displayName, selection: Binding(
                        get: { env.settings.preferences.sitePermissions[kind] },
                        set: { value in env.settings.setSitePermissionDefault(value, kind: kind) }
                    )) {
                        Text("询问").tag(SitePermissionRule.ask)
                        Text("允许").tag(SitePermissionRule.allow)
                        Text("拒绝").tag(SitePermissionRule.block)
                    }
                    .pickerStyle(.menu)
                }
            } header: {
                Text("默认行为")
            } footer: {
                Text("网站请求这些能力时按这里的设置处理。「询问」会在页面上弹出确认。系统级权限（相机、麦克风、位置）仍需要你在系统设置中允许 Vela 使用。")
            }

            Section {
                Label("相机与麦克风", systemImage: "camera")
                Label("位置", systemImage: "location")
            } header: {
                Text("系统权限")
            } footer: {
                Text("如果系统层面拒绝了权限，这里的「允许」不会生效。请到「设置 ▸ Vela」中开启。")
            }
        }
        .navigationTitle("网站权限")
        .navigationBarTitleDisplayMode(.inline)
    }
}

// MARK: - External navigation

struct ExternalNavigationSettingsView: View {
    @Environment(AppEnvironment.self) private var env

    var body: some View {
        List {
            Section {
                Picker("默认行为", selection: Binding(
                    get: { env.settings.preferences.externalNavigationDefault },
                    set: { value in env.settings.setExternalNavigationDefault(value) }
                )) {
                    ForEach(ExternalNavigationAppOpenPolicy.allCases) { policy in
                        Text(policy.displayName).tag(policy)
                    }
                }
                .pickerStyle(.segmented)
            } header: {
                Text("当网页要求打开其他 App")
            } footer: {
                Text("很多网站会在你点开链接时尝试拉起自家 App。默认「询问」时 Vela 会先问你是要用 App 打开还是留在浏览器里。")
            }

            Section {
                ForEach(env.settings.preferences.externalNavigationRules) { rule in
                    HStack {
                        Text(rule.host)
                        Spacer()
                        Text(rule.policy.displayName)
                            .foregroundStyle(.secondary)
                            .font(.subheadline)
                    }
                }
                .onDelete { offsets in
                    env.settings.update { preferences in
                        preferences.externalNavigationRules.remove(atOffsets: offsets)
                    }
                }
            } header: {
                Text("网站例外")
            } footer: {
                Text("在弹窗里选择「记住」之后，该网站会出现在这里。")
            }
        }
        .navigationTitle("外部应用跳转")
        .navigationBarTitleDisplayMode(.inline)
    }
}

// MARK: - Clear data

/// Ported from `SettingsSiteDataClearCoordinator`. Clearing is one action over
/// several stores, because clearing some and not others leaves the user
/// believing more was removed than actually was.
struct ClearDataView: View {
    @Environment(AppEnvironment.self) private var env

    @State private var clearHistory = true
    @State private var clearCookies = true
    @State private var clearCache = true
    @State private var clearBookmarks = false
    @State private var showConfirm = false
    @State private var isClearing = false

    var body: some View {
        List {
            Section {
                Toggle("浏览历史与搜索记录", isOn: $clearHistory)
                Toggle("Cookie 与网站数据", isOn: $clearCookies)
                Toggle("缓存", isOn: $clearCache)
                Toggle("书签", isOn: $clearBookmarks)
            } header: {
                Text("要清除的内容")
            } footer: {
                Text("书签默认不清除。密码和已保存的登录状态不在 Vela 的管理范围内，它们由系统钥匙串保存。")
            }

            Section {
                Button(role: .destructive) {
                    showConfirm = true
                } label: {
                    HStack {
                        if isClearing { ProgressView() }
                        Text("立即清除")
                    }
                }
                .disabled(isClearing)
            }

            Section {
                LabeledContent("历史记录", value: "\(env.history.entryCount) 条")
                LabeledContent("书签", value: "\(env.bookmarks.allBookmarks.count) 条")
                LabeledContent("下载记录", value: "\(env.downloads.tasks.count) 条")
            } header: {
                Text("当前数据")
            }
        }
        .navigationTitle("清除浏览数据")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            // The counts come from the published history list, which is no
            // longer refreshed on every page load.
            env.history.reload()
        }
        .alert("确认清除？", isPresented: $showConfirm) {
            Button("取消", role: .cancel) {}
            Button("清除", role: .destructive, action: performClear)
        } message: {
            Text("此操作无法撤销。")
        }
    }

    private func performClear() {
        isClearing = true
        Task {
            if clearHistory {
                env.history.removeAll()
            }
            if clearBookmarks {
                env.bookmarks.clearRoot(.toolbar)
                env.bookmarks.clearRoot(.other)
            }
            if clearCookies || clearCache {
                await env.clearAllBrowsingData(includeWebKitData: clearCookies)
                // The cache-only case still needs WebKit's transient data cleared.
                if clearCache, !clearCookies {
                    await clearCacheOnly()
                }
            }
            if clearHistory, !clearBookmarks {
                // `eraseAllData` is deliberately not used here: it would take
                // the bookmarks with it.
                env.history.reload()
            }
            isClearing = false
        }
    }

    private func clearCacheOnly() async {
        let types: Set<String> = [
            WKWebsiteDataTypeDiskCache,
            WKWebsiteDataTypeMemoryCache,
            WKWebsiteDataTypeOfflineWebApplicationCache
        ]
        await withCheckedContinuation { continuation in
            WKWebsiteDataStore.default().removeData(
                ofTypes: types,
                modifiedSince: Date(timeIntervalSince1970: 0)
            ) {
                continuation.resume()
            }
        }
    }
}

// MARK: - Downloads

struct DownloadSettingsView: View {
    @Environment(AppEnvironment.self) private var env

    var body: some View {
        List {
            Section {
                ForEach(DownloadDirectoryPreference.allCases) { preference in
                    Button {
                        env.settings.updateDownloadSettings { $0.directoryPreference = preference }
                    } label: {
                        HStack(alignment: .top, spacing: 12) {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(preference.displayName).foregroundStyle(.primary)
                                Text(preference.detail)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .multilineTextAlignment(.leading)
                            }
                            Spacer(minLength: 0)
                            if env.settings.downloadSettings.directoryPreference == preference {
                                Image(systemName: "checkmark").foregroundStyle(.tint)
                            }
                        }
                    }
                }
            } header: {
                Text("保存位置")
            } footer: {
                Text("iOS 不允许 App 直接写入任意路径，因此下载只能保存在 Vela 自己的文件夹里，或者由你在下载时选择位置。")
            }

            Section {
                Toggle("下载前询问", isOn: Binding(
                    get: { env.settings.downloadSettings.confirmBeforeDownload },
                    set: { value in env.settings.updateDownloadSettings { $0.confirmBeforeDownload = value } }
                ))
                Toggle("完成后自动移除记录", isOn: Binding(
                    get: { env.settings.downloadSettings.autoRemoveCompleted },
                    set: { value in env.settings.updateDownloadSettings { $0.autoRemoveCompleted = value } }
                ))
            } footer: {
                Text("「自动移除记录」只删除列表里的条目，已经下载的文件会保留。")
            }
        }
        .navigationTitle("下载")
        .navigationBarTitleDisplayMode(.inline)
    }
}
