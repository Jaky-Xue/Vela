//
//  SettingsSubpages.swift
//  Vela
//
//  The settings destinations past the main list: ad blocking, default
//  site permissions, external navigation, downloads, and clearing
//  site data.
//

import SwiftUI
import WebKit

// MARK: - Ad block

struct AdBlockSettingsView: View {
    @Environment(AppEnvironment.self) private var env

    @State private var newRule = ""
    @State private var updatingSourceId: String?
    /// The index of the local rule under edit, and its text.
    @State private var editingRuleIndex: Int?
    @State private var editingRuleText = ""

    private var isEditingRule: Binding<Bool> {
        Binding(
            get: { editingRuleIndex != nil },
            set: { if !$0 { editingRuleIndex = nil } }
        )
    }

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
                Text("系统不提供拦截计数，这里显示规则条数与实际隐藏的元素数。")
            }

            Section {
                ForEach(env.settings.adBlockSettings.ruleSources) { source in
                    NavigationLink {
                        AdBlockSourceRulesView(source: source)
                    } label: {
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
                ForEach(
                    Array(env.settings.adBlockSettings.preferences.localRules.enumerated()),
                    id: \.offset
                ) { index, rule in
                    Button {
                        editingRuleText = rule
                        editingRuleIndex = index
                    } label: {
                        HStack(spacing: 8) {
                            Text(rule)
                                .font(.system(size: 13, design: .monospaced))
                                .foregroundStyle(.primary)
                            Spacer(minLength: 0)
                            Image(systemName: "pencil")
                                .font(.system(size: 12, weight: .medium))
                                .foregroundStyle(.secondary)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
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
                Text("支持 Adblock Plus 语法的常见写法，例如 ||example.com^ 拦截整站、##.ad-banner 隐藏元素。点按一条规则即可修改，左滑删除。")
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
        .sheet(isPresented: isEditingRule) {
            NavigationStack {
                Form {
                    Section {
                        TextField("规则", text: $editingRuleText, axis: .vertical)
                            .font(.system(size: 14, design: .monospaced))
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .lineLimit(3...10)
                    } footer: {
                        Text("保存后会立即重新编译规则。")
                    }
                }
                .navigationTitle("编辑自定义规则")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("取消") { editingRuleIndex = nil }
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("保存") { saveEditedLocalRule() }
                            .disabled(
                                editingRuleText
                                    .trimmingCharacters(in: .whitespacesAndNewlines)
                                    .isEmpty
                            )
                    }
                }
            }
            .browserAmbientSheet()
        }
        .navigationTitle("广告与内容过滤")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            Task { await env.refreshAdBlockRules() }
        }
    }

    /// Writes the edited rule back and recompiles. A rule deleted while the
    /// editor was open leaves nothing to write, so the index is checked.
    private func saveEditedLocalRule() {
        guard let index = editingRuleIndex else { return }
        var rules = env.settings.adBlockSettings.preferences.localRules
        guard rules.indices.contains(index) else {
            editingRuleIndex = nil
            return
        }
        rules[index] = editingRuleText.trimmingCharacters(in: .whitespacesAndNewlines)
        env.settings.setLocalAdBlockRules(rules)
        editingRuleIndex = nil
        editingRuleText = ""
        Task { await env.refreshAdBlockRules() }
    }
}

// MARK: - One source's rules

/// The rule text a source contributes, searchable and copyable.
///
/// Until this existed the only number a user could see was "已加载规则";
/// the rules themselves — the shipped lists and every subscription — were
/// compiled and never readable. System and subscription rules are shown as
/// they are: editing them would be overwritten by the next update, so the
/// one edit offered is to copy a rule into the user's own rules.
struct AdBlockSourceRulesView: View {
    @Environment(AppEnvironment.self) private var env

    let source: AdBlockCustomRuleSource

    @State private var text: String?
    @State private var query = ""

    private var lines: [String] {
        guard let text else { return [] }
        return text
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    private var visibleLines: [String] {
        let needle = query.trimmingCharacters(in: .whitespaces)
        guard !needle.isEmpty else { return lines }
        return lines.filter { $0.localizedCaseInsensitiveContains(needle) }
    }

    var body: some View {
        List {
            Section {
                if text != nil, !lines.isEmpty {
                    ForEach(Array(visibleLines.enumerated()), id: \.offset) { _, line in
                        Text(line)
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundStyle(isComment(line) ? Color.secondary : Color.primary)
                            .textSelection(.enabled)
                            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                Button {
                                    addLocalRule(line)
                                } label: {
                                    Label("加入自定义规则", systemImage: "plus")
                                }
                                .tint(.blue)
                            }
                    }
                } else {
                    ContentUnavailableView(
                        text == nil ? "还没有规则内容" : "没有规则",
                        systemImage: "shield.slash",
                        description: Text(
                            source.sourceType == .remote
                                ? "这个订阅还没有下载，请回到上一页更新它。"
                                : "这个来源目前没有规则。"
                        )
                    )
                }
            } header: {
                Text("共 \(visibleLines.count) 条")
            } footer: {
                Text("规则按原样显示，以 ! 或 [ 开头的是注释与元数据。向左轻扫一条规则，可以把它加入自定义规则后再修改。")
            }
        }
        .navigationTitle(source.name)
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $query, prompt: "搜索规则")
        .task {
            if text == nil {
                text = env.adBlockRuleText(sourceId: source.id) ?? ""
            }
        }
    }

    private func isComment(_ line: String) -> Bool {
        line.hasPrefix("!") || line.hasPrefix("[")
    }

    private func addLocalRule(_ line: String) {
        var rules = env.settings.adBlockSettings.preferences.localRules
        guard !rules.contains(line) else { return }
        rules.append(line)
        env.settings.setLocalAdBlockRules(rules)
        Task { await env.refreshAdBlockRules() }
    }
}

// MARK: - Site permissions

struct SitePermissionsSettingsView: View {
    @Environment(AppEnvironment.self) private var env

    var body: some View {
        List {
            Section {
                // Only the kinds a web view actually asks about. The model
                // carries location, sensor and clipboard too, but iOS never
                // routes those through a web view, so a picker for them was a
                // setting that decided nothing.
                ForEach([SitePermissionKind.camera, .microphone]) { kind in
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
                Text("「询问」会在页面上弹出确认。系统层面拒绝时，这里的「允许」不生效。")
            }

            Section {
                Label("相机与麦克风", systemImage: "camera")
            } header: {
                Text("系统权限")
            } footer: {
                Text("请到「设置 ▸ Vela」中开启。")
            }
        }
        .navigationTitle("网站权限")
        .navigationBarTitleDisplayMode(.inline)
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
    }
}
