//
//  SettingsView.swift
//  Vela
//
//  The settings centre and its sub-pages. Ported from
//  `AiraBrowser/entry/src/main/ets/app/pages/SettingsCenterPage.ets` plus the
//  per-domain pages under `app/pages/` (Aira Browser 3.7.4, GPL-3.0).
//
//  Aira has 84 settings pages and a catalog that owns their order
//  (`SettingsDestinationCatalog.ets`). Vela ports the destinations that have a
//  backing implementation, and says so on the About page rather than shipping
//  rows that lead nowhere — a settings row that opens an empty screen is worse
//  than an absent one.
//

import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var env: AppEnvironment
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        List {
            Section {
                NavigationLink {
                    SearchEngineSettingsView()
                } label: {
                    settingsRow(
                        icon: "magnifyingglass",
                        tint: .blue,
                        title: "搜索引擎",
                        detail: env.settings.preferences.searchEngine.activeEngine.name
                    )
                }

                NavigationLink {
                    AppearanceSettingsView()
                } label: {
                    settingsRow(icon: "paintpalette", tint: .purple, title: "外观")
                }

                NavigationLink {
                    AdBlockSettingsView()
                } label: {
                    settingsRow(
                        icon: "shield.lefthalf.filled",
                        tint: .green,
                        title: "广告与内容过滤",
                        detail: env.settings.adBlockSettings.preferences.enabled ? "已开启" : "已关闭"
                    )
                }

                NavigationLink {
                    UserScriptsView()
                } label: {
                    settingsRow(
                        icon: "curlybraces",
                        tint: .orange,
                        title: "用户脚本",
                        detail: env.settings.preferences.userScriptsEnabled ? "" : "已关闭"
                    )
                }
            }

            Section("隐私与安全") {
                NavigationLink {
                    PrivacySettingsView()
                } label: {
                    settingsRow(
                        icon: "hand.raised",
                        tint: .indigo,
                        title: "跟踪保护",
                        detail: env.settings.preferences.webSecurity.trackingProtection.displayName
                    )
                }

                NavigationLink {
                    SecureDnsSettingsView()
                } label: {
                    settingsRow(
                        icon: "network.badge.shield.half.filled",
                        tint: .teal,
                        title: "安全 DNS",
                        detail: env.settings.preferences.secureDns.mode.displayName
                    )
                }

                NavigationLink {
                    SitePermissionsSettingsView()
                } label: {
                    settingsRow(icon: "lock.shield", tint: .cyan, title: "网站权限")
                }

                NavigationLink {
                    ExternalNavigationSettingsView()
                } label: {
                    settingsRow(
                        icon: "arrow.up.forward.app",
                        tint: .pink,
                        title: "外部应用跳转",
                        detail: env.settings.preferences.externalNavigationDefault.displayName
                    )
                }

                NavigationLink {
                    ClearDataView()
                } label: {
                    settingsRow(icon: "trash", tint: .red, title: "清除浏览数据")
                }
            }

            Section("浏览") {
                NavigationLink {
                    GeneralSettingsView()
                } label: {
                    settingsRow(icon: "gearshape", tint: .gray, title: "通用")
                }

                NavigationLink {
                    DownloadSettingsView()
                } label: {
                    settingsRow(
                        icon: "arrow.down.circle",
                        tint: .blue,
                        title: "下载",
                        detail: "\(env.downloads.activeCount) 个进行中"
                    )
                }

                NavigationLink {
                    UserAgentSettingsView()
                } label: {
                    settingsRow(
                        icon: "safari",
                        tint: .brown,
                        title: "网页标识",
                        detail: env.settings.preferences.desktopSiteByDefault ? "桌面版" : "手机版"
                    )
                }
            }

            Section {
                NavigationLink {
                    AboutView()
                } label: {
                    settingsRow(icon: "info.circle", tint: .gray, title: "关于 Vela")
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("设置")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("完成") { dismiss() }
            }
        }
    }

    private func settingsRow(icon: String, tint: Color, title: String, detail: String = "") -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 26, height: 26)
                .background(tint, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            Text(title)
            Spacer()
            if !detail.isEmpty {
                Text(detail)
                    .foregroundStyle(.secondary)
                    .font(.subheadline)
            }
        }
    }
}

// MARK: - Search engines

/// Ported from `SearchDefaultEnginePage.ets`, `SearchBuiltInEnginesPage.ets`
/// and `SearchEngineEditPage.ets`.
struct SearchEngineSettingsView: View {
    @EnvironmentObject private var env: AppEnvironment

    @State private var showingCustomEngineForm = false
    @State private var editingEngine: SearchEngineRecord?

    var body: some View {
        List {
            Section("默认搜索引擎") {
                ForEach(env.settings.preferences.searchEngine.selectableEngines) { engine in
                    Button {
                        env.settings.setDefaultSearchEngine(id: engine.id)
                    } label: {
                        HStack {
                            Text(engine.name)
                                .foregroundStyle(.primary)
                            Spacer()
                            if env.settings.preferences.searchEngine.defaultSearchEngineId == engine.id {
                                Image(systemName: "checkmark")
                                    .foregroundStyle(.tint)
                            }
                        }
                    }
                }
            }

            Section {
                ForEach(BuiltInSearchEngineId.allCases) { engine in
                    let option = searchEngineOptions.first { $0.id == engine.rawValue }
                    Toggle(isOn: Binding(
                        get: {
                            env.settings.preferences.searchEngine.enabledBuiltInEngineIds.contains(engine.rawValue)
                        },
                        set: { enabled in
                            env.settings.setSearchEngineEnabled(enabled, id: engine)
                        }
                    )) {
                        Text(option?.name ?? engine.rawValue)
                    }
                }
            } header: {
                Text("在地址栏中可切换的引擎")
            } footer: {
                Text("关闭的引擎不会出现在地址栏的引擎切换列表里，但仍可设为默认。")
            }

            Section {
                ForEach(env.settings.preferences.searchEngine.customEngines) { engine in
                    Button {
                        editingEngine = engine
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(engine.name)
                                .foregroundStyle(.primary)
                            Text(engine.searchUrlTemplate)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                }
                .onDelete { offsets in
                    for index in offsets {
                        env.settings.removeCustomSearchEngine(
                            id: env.settings.preferences.searchEngine.customEngines[index].id
                        )
                    }
                }

                Button("添加自定义引擎", systemImage: "plus") {
                    showingCustomEngineForm = true
                }
            } header: {
                Text("自定义引擎")
            } footer: {
                Text("网址模板中用 {searchTerms} 表示搜索词。")
            }

            Section("搜索建议") {
                Toggle("显示搜索建议", isOn: Binding(
                    get: { env.settings.preferences.searchEngine.searchSuggestions.regularEnabled },
                    set: { value in
                        env.settings.update { $0.searchEngine.searchSuggestions.regularEnabled = value }
                    }
                ))
                Toggle("历史与书签建议", isOn: Binding(
                    get: { env.settings.preferences.searchEngine.searchSuggestions.browsingHistoryEnabled },
                    set: { value in
                        env.settings.update { $0.searchEngine.searchSuggestions.browsingHistoryEnabled = value }
                    }
                ))
                Toggle("已打开标签页建议", isOn: Binding(
                    get: { env.settings.preferences.searchEngine.searchSuggestions.openTabsEnabled },
                    set: { value in
                        env.settings.update { $0.searchEngine.searchSuggestions.openTabsEnabled = value }
                    }
                ))
            }

            Section {
                Toggle("搜索失败时自动切换引擎", isOn: Binding(
                    get: { env.settings.preferences.searchEngine.fallbackSearch.enabled },
                    set: { value in
                        env.settings.update { $0.searchEngine.fallbackSearch.enabled = value }
                    }
                ))
                if env.settings.preferences.searchEngine.fallbackSearch.enabled {
                    Picker("备用引擎", selection: Binding(
                        get: { env.settings.preferences.searchEngine.fallbackSearch.fallbackSearchEngineId },
                        set: { value in
                            env.settings.update { $0.searchEngine.fallbackSearch.fallbackSearchEngineId = value }
                        }
                    )) {
                        ForEach(env.settings.preferences.searchEngine.selectableEngines) { engine in
                            Text(engine.name).tag(engine.id)
                        }
                    }
                }
            } header: {
                Text("搜索回退")
            } footer: {
                Text("搜索引擎被网络阻断时，Vela 会检测到结果页没有真正加载，并提示切换到备用引擎。")
            }
        }
        .navigationTitle("搜索引擎")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showingCustomEngineForm) {
            CustomSearchEngineForm(engine: nil) { engine in
                env.settings.addCustomSearchEngine(engine)
            }
        }
        .sheet(item: $editingEngine) { engine in
            CustomSearchEngineForm(engine: engine) { updated in
                env.settings.removeCustomSearchEngine(id: engine.id)
                env.settings.addCustomSearchEngine(updated)
            }
        }
    }
}

private struct CustomSearchEngineForm: View {
    @Environment(\.dismiss) private var dismiss

    var engine: SearchEngineRecord?
    var onSave: (SearchEngineRecord) -> Void

    @State private var name: String
    @State private var template: String
    @State private var homepage: String

    init(engine: SearchEngineRecord?, onSave: @escaping (SearchEngineRecord) -> Void) {
        self.engine = engine
        self.onSave = onSave
        _name = State(initialValue: engine?.name ?? "")
        _template = State(initialValue: engine?.searchUrlTemplate ?? "https://example.com/search?q={searchTerms}")
        _homepage = State(initialValue: engine?.homepageUrl ?? "")
    }

    private var isValid: Bool {
        !name.trimmingCharacters(in: .whitespaces).isEmpty && template.contains("{searchTerms}")
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("名称") {
                    TextField("例如：站内搜索", text: $name)
                }
                Section {
                    TextField("网址模板", text: $template)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                } header: {
                    Text("网址模板")
                } footer: {
                    Text("必须包含 {searchTerms}，它会替换成搜索词。")
                }
                Section("主页（可选）") {
                    TextField("https://example.com", text: $homepage)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                }
            }
            .navigationTitle(engine == nil ? "添加搜索引擎" : "编辑搜索引擎")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") {
                        onSave(
                            SearchEngineRecord(
                                id: engine?.id ?? "custom-\(UUID().uuidString)",
                                kind: .custom,
                                name: name,
                                searchUrlTemplate: template,
                                homepageUrl: homepage,
                                isEditable: true,
                                position: engine?.position ?? 0
                            )
                        )
                        dismiss()
                    }
                    .disabled(!isValid)
                }
            }
        }
    }
}

// MARK: - Appearance

/// Ported from `ThemePaletteSettingsPage.ets`.
struct AppearanceSettingsView: View {
    @EnvironmentObject private var env: AppEnvironment

    var body: some View {
        List {
            Section("配色") {
                ForEach(BrowserPalette.all) { palette in
                    Button {
                        env.settings.update { $0.themePaletteId = palette.id }
                    } label: {
                        HStack(spacing: 12) {
                            Circle()
                                .fill(palette.accent)
                                .frame(width: 22, height: 22)
                            Text(palette.displayName)
                                .foregroundStyle(.primary)
                            Spacer()
                            if env.settings.preferences.themePaletteId == palette.id {
                                Image(systemName: "checkmark")
                                    .foregroundStyle(.tint)
                            }
                        }
                    }
                }
            }

            Section {
                Toggle("无痕标签页需要验证身份", isOn: Binding(
                    get: { env.settings.preferences.lockPrivateTabs },
                    set: { value in env.settings.update { $0.lockPrivateTabs = value } }
                ))
                Toggle("模糊无痕标签页预览", isOn: Binding(
                    get: { env.settings.preferences.blurPrivateTabPreviews },
                    set: { value in env.settings.update { $0.blurPrivateTabPreviews = value } }
                ))
            } header: {
                Text("无痕模式")
            }
        }
        .navigationTitle("外观")
        .navigationBarTitleDisplayMode(.inline)
    }
}

// MARK: - General

/// Ported from `GeneralStartupSettingsPage.ets`,
/// `GeneralTabAutoCloseSettingsPage.ets` and
/// `GeneralHistoryRetentionSettingsPage.ets`.
struct GeneralSettingsView: View {
    @EnvironmentObject private var env: AppEnvironment

    private static let retentionChoices: [(String, Int)] = [
        ("不自动清理", 0),
        ("7 天", 7),
        ("30 天", 30),
        ("90 天", 90),
        ("180 天", 180),
        ("1 年", 365)
    ]

    var body: some View {
        List {
            Section {
                Toggle("启动时恢复上次的标签页", isOn: Binding(
                    get: { env.settings.preferences.restoreTabsOnLaunch },
                    set: { value in env.settings.update { $0.restoreTabsOnLaunch = value } }
                ))
                Toggle("在后台打开新标签页", isOn: Binding(
                    get: { env.settings.preferences.openNewTabsInBackground },
                    set: { value in env.settings.update { $0.openNewTabsInBackground = value } }
                ))
            } header: {
                Text("启动与标签页")
            } footer: {
                Text("后台打开时，新标签页不会自动切换到前台。")
            }

            Section {
                Picker("保留时长", selection: Binding(
                    get: { env.settings.preferences.historyRetentionDays },
                    set: { value in env.settings.update { $0.historyRetentionDays = value } }
                )) {
                    ForEach(Self.retentionChoices, id: \.1) { choice in
                        Text(choice.0).tag(choice.1)
                    }
                }
            } header: {
                Text("历史记录保留")
            } footer: {
                Text("超过保留期的记录会在下一次访问网页时被清理。设为「不自动清理」则一直保留。")
            }

            Section {
                Toggle("阅读模式", isOn: Binding(
                    get: { env.settings.preferences.readerModeAvailable },
                    set: { value in env.settings.update { $0.readerModeAvailable = value } }
                ))
            } header: {
                Text("阅读")
            }
        }
        .navigationTitle("通用")
        .navigationBarTitleDisplayMode(.inline)
    }
}

// MARK: - User agent

/// Ported from `BrowserUserAgentSettingsPage.ets`.
struct UserAgentSettingsView: View {
    @EnvironmentObject private var env: AppEnvironment

    var body: some View {
        List {
            Section {
                Toggle("默认请求桌面版网站", isOn: Binding(
                    get: { env.settings.preferences.desktopSiteByDefault },
                    set: { value in env.settings.update { $0.desktopSiteByDefault = value } }
                ))
            } footer: {
                Text("关闭后网站会看到 iPhone 的标识，多数网站会给出移动版页面。")
            }

            Section {
                TextField("自定义 User-Agent", text: Binding(
                    get: { env.settings.preferences.customUserAgent },
                    set: { value in env.settings.update { $0.customUserAgent = value } }
                ), axis: .vertical)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .font(.system(size: 13, design: .monospaced))
                .lineLimit(3...6)

                Button("恢复默认") {
                    env.settings.update { $0.customUserAgent = "" }
                }
            } header: {
                Text("自定义标识")
            } footer: {
                Text("留空则使用 Vela 的默认标识。修改后需要重新加载页面才会生效。")
            }
        }
        .navigationTitle("网页标识")
        .navigationBarTitleDisplayMode(.inline)
    }
}

// MARK: - About

/// Ported from `SettingsAboutOverviewViewModel.ets`. The attribution section is
/// what the GPL-3.0 licence and Aira's trademark policy require.
struct AboutView: View {
    @EnvironmentObject private var env: AppEnvironment

    var body: some View {
        List {
            Section {
                VStack(spacing: 8) {
                    Image(systemName: "sailboat.fill")
                        .font(.system(size: 44))
                        .foregroundStyle(.tint)
                    Text("Vela")
                        .font(.title2.weight(.semibold))
                    Text("版本 3.7.4 (1)")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
                .listRowBackground(Color.clear)
            }

            Section {
                LabeledContent("数据库结构版本") {
                    Text("\(BrowserSchema.velaSchemaVersion)")
                        .monospacedDigit()
                }
                LabeledContent("过滤规则") {
                    Text("\(env.adBlock.ruleCount) 条")
                        .monospacedDigit()
                }
                LabeledContent("已加载的隐藏规则") {
                    Text("\(env.adBlock.cosmeticSelectors.count) 条")
                        .monospacedDigit()
                }
            } header: {
                Text("运行状态")
            }

            Section {
                Text("Vela 是 Aira Browser 鸿蒙客户端的 iOS 移植。它保留了 Aira 的分层结构、数据表结构和功能语义，并针对 iOS 平台重新实现。")
                    .font(.footnote)
                Text("上游项目：Aira Browser，以 GPL-3.0 发布。Vela 是修改后的分发版本，按照上游商标政策使用了自己的名称、应用标识和视觉标识。")
                    .font(.footnote)
            } header: {
                Text("关于本项目")
            }

            Section {
                Text("iOS 不允许使用第三方浏览器内核，因此 Vela 的网页渲染、网络请求和广告过滤都通过 WebKit 完成。这与 Aira 在鸿蒙上自建网络栈和 Rust 过滤引擎的实现方式不同：")
                    .font(.footnote)
                VStack(alignment: .leading, spacing: 6) {
                    limitation("广告过滤", "使用系统的 WKContentRuleList，而不是 Aira 的 Rust 引擎。规则语法支持常见的 Adblock Plus 子集，但正则规则、$csp、$rewrite 和扩展选择器无法表达。")
                    limitation("用户脚本", "在页面内执行，因此 GM_xmlhttpRequest、GM_download、GM_cookie 这类需要特权的接口不可用。申请了这些权限的脚本仍可安装，详情页会标注。")
                    limitation("下载", "由 WKDownload 完成，支持断点续传，但没有 Aira 的分片多连接和下载队列。")
                    limitation("统计", "WebKit 不报告被拦截的请求数，所以 Vela 不显示这个数字，只显示规则条数和实际隐藏的元素数。")
                    limitation("同步", "WebDAV 与自建 Personal Server 的数据模型已移植，客户端的同步调度尚未实现。")
                }
                .font(.caption)
            } header: {
                Text("与鸿蒙版的差异")
            }

            Section {
                Link("GNU General Public License v3.0", destination: URL(string: "https://www.gnu.org/licenses/gpl-3.0.html")!)
                Link("Aira Browser 上游仓库", destination: URL(string: "https://github.com/mason173/aira-browser")!)
            } header: {
                Text("许可与致谢")
            }
        }
        .navigationTitle("关于")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func limitation(_ title: String, _ body: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.primary)
            Text(body)
                .foregroundStyle(.secondary)
        }
    }
}
