//
//  SettingsSubpages.swift
//  Vela
//
//  The settings destinations past the main list: default site permissions,
//  external navigation, downloads, and clearing site data.
//

import SwiftUI
import WebKit

// MARK: - Site permissions

struct SitePermissionsSettingsView: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.browserPalette) private var palette

    private var siteRules: [SitePermissionSiteRule] {
        env.settings.preferences.sitePermissionRules ?? []
    }

    var body: some View {
        List {
            Section {
                ForEach(SitePermissionKind.allCases) { kind in
                    Picker(kind.displayName, selection: Binding(
                        get: { env.settings.preferences.sitePermissions[kind] },
                        set: { value in env.settings.setSitePermissionDefault(value, kind: kind) }
                    )) {
                        Text(SitePermissionRule.ask.displayName).tag(SitePermissionRule.ask)
                        Text(SitePermissionRule.allow.displayName).tag(SitePermissionRule.allow)
                        Text(SitePermissionRule.block.displayName).tag(SitePermissionRule.block)
                    }
                    .pickerStyle(.menu)
                }
            } header: {
                Text("默认行为")
            } footer: {
                Text("「询问」会在页面上弹出确认，答案只作用到当前会话；「以后对这个网站都这样」会把答案按网站保存。系统层面拒绝时，这里的「允许」不生效。")
            }

            Section {
                if siteRules.isEmpty {
                    Text("还没有按网站保存的权限。提示里打开「以后对这个网站都这样」后，记录会出现在这里。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(siteRules) { rule in
                        HStack(spacing: 10) {
                            Image(systemName: rule.kind.symbolName)
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(palette.accent)
                                .frame(width: 22)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(rule.host)
                                    .font(.subheadline)
                                Text(rule.kind.displayName)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer(minLength: 6)
                            Text(rule.rule.displayName)
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(rule.rule == .allow ? .green : .red)
                            Button {
                                env.settings.removeSitePermissionRule(id: rule.id)
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .foregroundStyle(.secondary)
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("移除这条权限")
                        }
                    }
                }
            } header: {
                Text("按网站保存")
            }

            Section {
                if env.permissionAudit.records.isEmpty {
                    Text("还没有访问记录。网页请求权限时会记录在这里。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(Array(env.permissionAudit.records.prefix(100))) { record in
                        HStack(alignment: .top, spacing: 10) {
                            Image(systemName: record.kind.symbolName)
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(record.decision == .allowed ? .green : .red)
                                .frame(width: 22)
                                .padding(.top, 2)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(record.host)
                                    .font(.subheadline)
                                Text("\(record.kind.displayName) · \(record.decision.displayName) · \(record.scope.displayName)")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer(minLength: 6)
                            Text(record.createdAt.formatted(date: .numeric, time: .shortened))
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .multilineTextAlignment(.trailing)
                        }
                    }
                    Button("清除访问记录", role: .destructive) {
                        env.permissionAudit.clear()
                    }
                }
            } header: {
                Text("访问记录")
            } footer: {
                Text("记录只保存网站、权限类型、结果和作用范围，不保存页面地址或内容；最多保留 500 条。")
            }

            Section {
                Label("相机、麦克风与定位", systemImage: "camera")
            } header: {
                Text("系统权限")
            } footer: {
                Text("网页的「允许」还要经过 iOS 对 Vela 本身的授权。请到「设置 ▸ Vela」中开启；定位在首次使用时会由系统另行询问。")
            }
        }
        .navigationTitle("网站权限")
        .navigationBarTitleDisplayMode(.inline)
        .browserListSurface()
    }
}

// MARK: - Hidden elements

/// The selectors the element picker added, grouped by site.
///
/// The picker is a direct action — the user pointed at one element and asked
/// for it to go — so its records are kept and managed here rather than folded
/// into a filter-list subscription. Removing a rule takes effect on the next
/// load of that site.
struct ElementHideSettingsView: View {
    @Environment(AppEnvironment.self) private var env

    var body: some View {
        List {
            if env.settings.manualElementHide.sites.isEmpty {
                Section {
                    Text("还没有隐藏任何元素。在网页上用「隐藏元素」选中一块区域后，会记录在这里。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } else {
                ForEach(env.settings.manualElementHide.sites) { site in
                    Section {
                        ForEach(site.rules) { rule in
                            HStack(spacing: 10) {
                                Text(rule.selector)
                                    .font(.system(.caption, design: .monospaced))
                                    .lineLimit(2)
                                Spacer(minLength: 6)
                                Button {
                                    env.settings.removeManualElementHide(
                                        ruleId: rule.id,
                                        host: site.host
                                    )
                                } label: {
                                    Image(systemName: "xmark.circle.fill")
                                        .foregroundStyle(.secondary)
                                }
                                .buttonStyle(.plain)
                                .accessibilityLabel("移除这条隐藏规则")
                            }
                        }
                    } header: {
                        Text(site.host)
                    }
                }
            }
        }
        .navigationTitle("隐藏的元素")
        .navigationBarTitleDisplayMode(.inline)
        .browserListSurface()
    }
}

// MARK: - External navigation

struct ExternalNavigationSettingsView: View {
    @Environment(AppEnvironment.self) private var env
    @State private var newHost = ""

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
                Text("默认行为")
            } footer: {
                Text("「唤起 App」链接（bilibili:// 等）默认被拦下；这里决定例外网站和 tel:、mailto: 等系统链接的处理。")
            }

            Section {
                HStack {
                    TextField("例如 bilibili.com", text: $newHost)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                    Button("添加", action: addRule)
                        .disabled(newHost.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            } header: {
                Text("添加例外")
            } footer: {
                Text("填入主机名即可，不必带 https://。")
            }

            if !env.settings.preferences.externalNavigationRules.isEmpty {
                Section {
                    ForEach(env.settings.preferences.externalNavigationRules) { rule in
                        Menu {
                            ForEach(ExternalNavigationAppOpenPolicy.allCases) { policy in
                                Button(policy.displayName) {
                                    env.settings.setExternalNavigationRule(host: rule.host, policy: policy)
                                }
                            }
                        } label: {
                            HStack {
                                Text(rule.host)
                                    .foregroundStyle(.primary)
                                Spacer()
                                Text(rule.policy.displayName)
                                    .foregroundStyle(.secondary)
                                    .font(.subheadline)
                            }
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
                    Text("在弹窗里选择「总是允许此网站」也会把网站加到这里的。")
                }
            }
        }
        .navigationTitle("外部应用跳转")
        .navigationBarTitleDisplayMode(.inline)
        .browserListSurface()
    }

    /// Adds the typed host as an exception, defaulting to asking.
    ///
    /// `.ask` because a new exception means "I want a say for this site", and it
    /// is one tap to change the row to allow or block.
    private func addRule() {
        let host = newHost
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "https://", with: "")
            .replacingOccurrences(of: "http://", with: "")
            .split(separator: "/")
            .first
            .map(String.init) ?? ""
        guard !host.isEmpty else { return }
        env.settings.setExternalNavigationRule(host: host, policy: .ask)
        newHost = ""
    }
}

// MARK: - Clear data

/// Clearing is one action over
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
                Text("密码由系统钥匙串保存，不在此清除。")
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
        .browserListSurface()
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
                Text("下载保存在 Vela 的文件夹，或下载时自选位置。")
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
                Text("只删除列表条目，文件保留。")
            }

            Section {
                Toggle("分片多连接下载", isOn: Binding(
                    get: { env.settings.downloadSettings.usesSegmentedDownloads },
                    set: { value in
                        env.settings.updateDownloadSettings { $0.segmentedDownloadsEnabled = value }
                    }
                ))

                Picker("每个文件的分片数", selection: Binding(
                    get: { env.settings.downloadSettings.segmentCount },
                    set: { value in
                        env.settings.updateDownloadSettings { $0.segmentsPerDownload = value }
                    }
                )) {
                    ForEach(1...8, id: \.self) { count in
                        Text("\(count)").tag(count)
                    }
                }
                .disabled(!env.settings.downloadSettings.usesSegmentedDownloads)

                Picker("同时下载数量", selection: Binding(
                    get: { env.settings.downloadSettings.maxConcurrentDownloadCount },
                    set: { value in
                        env.settings.updateDownloadSettings { $0.maxConcurrentDownloads = value }
                    }
                )) {
                    ForEach(1...4, id: \.self) { count in
                        Text("\(count)").tag(count)
                    }
                }
            } header: {
                Text("传输")
            } footer: {
                Text("分片下载需要服务器支持 Range；服务器不支持时会自动退回单连接。超出并发数量的任务会进入队列，按创建顺序开始。")
            }
        }
        .navigationTitle("下载")
        .navigationBarTitleDisplayMode(.inline)
        .browserListSurface()
    }
}
