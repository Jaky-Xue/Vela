//
//  SettingsView.swift
//  Vela
//
//  The settings centre and the sub-pages that hang off it.
//
//  Only destinations with a backing implementation are listed, and the About page
//  records which of the remaining ones are absent rather than shipping rows that
//  lead nowhere. A settings row that opens an empty screen is worse than an
//  absent row.
//

import SwiftUI
import UIKit

struct SettingsView: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.browserPalette) private var palette
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

                NavigationLink {
                    NavigationDiagnosticsView()
                } label: {
                    settingsRow(
                        icon: "waveform.path.ecg",
                        tint: .teal,
                        title: "加载诊断",
                        detail: "\(env.navigationLog.entries.count) 条记录"
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
        .browserListSurface()
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
                .foregroundStyle(palette.primaryText)
            Spacer()
            if !detail.isEmpty {
                Text(detail)
                    .foregroundStyle(palette.secondaryText)
                    .font(.subheadline)
            }
        }
    }
}

// MARK: - Search engines

struct SearchEngineSettingsView: View {
    @Environment(AppEnvironment.self) private var env

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

/// The palette picker, plus the per-app appearance override.
struct AppearanceSettingsView: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.browserPalette) private var palette

    var body: some View {
        List {
            Section {
                Picker("外观", selection: Binding(
                    get: { env.settings.appearanceMode },
                    set: { env.settings.setAppearanceMode($0) }
                )) {
                    ForEach(AppearanceMode.allCases) { mode in
                        Label(mode.displayName, systemImage: mode.symbolName)
                            .tag(mode)
                    }
                }
                .pickerStyle(.inline)
                .labelsHidden()

                // A preview strip, so the choice can be judged without leaving
                // the screen and flipping the whole app back and forth.
                AppearancePreviewStrip()
                    .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
            } header: {
                Text("外观模式")
            } footer: {
                Text("「跟随系统」会随系统的浅色/深色设置实时切换；选择浅色或深色则固定该外观，不随系统变化。")
            }

            Section {
                ForEach(BrowserPalette.all) { candidate in
                    Button {
                        env.settings.update { $0.themePaletteId = candidate.id }
                    } label: {
                        HStack(spacing: 12) {
                            Circle()
                                .fill(candidate.accent)
                                .frame(width: 22, height: 22)
                                .overlay {
                                    Circle().strokeBorder(palette.cardStroke, lineWidth: 0.5)
                                }
                            VStack(alignment: .leading, spacing: 2) {
                                Text(candidate.displayName)
                                    .foregroundStyle(palette.primaryText)
                                Text("\(candidate.light.accent.hexDescription) · \(candidate.dark.accent.hexDescription)")
                                    .font(.caption2)
                                    .foregroundStyle(palette.secondaryText)
                            }
                            Spacer()
                            if env.settings.preferences.themePaletteId == candidate.id {
                                Image(systemName: "checkmark")
                                    .foregroundStyle(palette.accent)
                            }
                        }
                    }
                }
            } header: {
                Text("配色")
            } footer: {
                Text("每套配色都带有浅色与深色两组颜色，切换外观时会自动使用对应的一组。")
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

/// A miniature of the chrome, rendered in the *other* appearance.
///
/// The point is side-by-side comparison: the strip always shows the mode the
/// user is not currently in, so a change to the picker above is visible
/// immediately without leaving the screen.
private struct AppearancePreviewStrip: View {
    @Environment(\.browserPalette) private var palette
    @Environment(\.colorScheme) private var colorScheme

    private var previewScheme: ColorScheme {
        colorScheme == .dark ? .light : .dark
    }

    private var previewTokens: BrowserColorTokens {
        palette.tokens(for: previewScheme)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: "lock.fill")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.green)
                Text("vela.example.com")
                    .font(.footnote)
                    .foregroundStyle(previewTokens.primaryText)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12)
            .frame(height: 38)
            .background(previewTokens.controlFill, in: RoundedRectangle(cornerRadius: BrowserRadius.field, style: .continuous))

            HStack(spacing: 0) {
                ForEach(["chevron.left", "chevron.right", "square.on.square", "book", "ellipsis"], id: \.self) { symbol in
                    Image(systemName: symbol)
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(previewTokens.primaryText)
                        .frame(maxWidth: .infinity)
                }
            }
            .frame(height: 34)
            .background(previewTokens.chrome, in: RoundedRectangle(cornerRadius: BrowserRadius.chip, style: .continuous))

            Text(previewScheme == .dark ? "深色预览" : "浅色预览")
                .font(.caption2)
                .foregroundStyle(previewTokens.secondaryText)
        }
        .padding(10)
        .background(previewTokens.surface, in: RoundedRectangle(cornerRadius: BrowserRadius.card, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: BrowserRadius.card, style: .continuous)
                .strokeBorder(previewTokens.cardStroke, lineWidth: 0.5)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("配色预览")
    }
}

// MARK: - Colour description

extension Color {
    /// The colour as `#RRGGBB`, for the settings list.
    ///
    /// Resolved against the standard sRGB space and no trait collection: these
    /// are the palette's authored values, and showing them is the only way a
    /// user can tell two similar palettes apart in a list.
    var hexDescription: String {
        let uiColor = UIColor(self)
        var red: CGFloat = 0
        var green: CGFloat = 0
        var blue: CGFloat = 0
        var alpha: CGFloat = 0
        guard uiColor.getRed(&red, green: &green, blue: &blue, alpha: &alpha) else {
            return "#------"
        }
        return String(
            format: "#%02X%02X%02X",
            Int((red * 255).rounded()),
            Int((green * 255).rounded()),
            Int((blue * 255).rounded())
        )
    }
}

// MARK: - General

struct GeneralSettingsView: View {
    @Environment(AppEnvironment.self) private var env

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

struct UserAgentSettingsView: View {
    @Environment(AppEnvironment.self) private var env

    /// The identifier a page actually received, read back from the page.
    ///
    /// The reason this screen exists at all: a site that says the browser is too
    /// old is making a claim about a string, and the only way to check the claim
    /// is to look at the string that was sent. This is that string — taken from a
    /// live page, so the platform and engine tokens are the real ones rather than
    /// Vela's reconstruction.
    @State private var identifierReportedByPage: String?

    /// Changes whenever the identifier changes, so the read-back repeats.
    private var identityKey: String {
        "\(env.settings.preferences.desktopSiteByDefault)|\(env.settings.preferences.customUserAgent)"
    }

    var body: some View {
        List {
            Section {
                Toggle("默认请求桌面版网站", isOn: Binding(
                    get: { env.settings.preferences.desktopSiteByDefault },
                    set: { value in
                        env.settings.update { $0.desktopSiteByDefault = value }
                        apply(reload: true)
                    }
                ))
            } footer: {
                Text("关闭后网站会看到 iPhone 的标识，多数网站会给出移动版页面。")
            }

            Section {
                VStack(alignment: .leading, spacing: BrowserSpacing.compact) {
                    identifierRow(
                        title: "页面实际收到",
                        value: identifierReportedByPage,
                        note: identifierReportedByPage == nil
                            ? "打开任意网页后，这里会显示这个设备真实发出的标识。"
                            : nil
                    )
                    Divider()
                    identifierRow(
                        title: "将要发出",
                        value: BrowserUserAgent.mobileIdentifier,
                        note: nil
                    )
                }
                Button {
                    UIPasteboard.general.string = identifierReportedByPage ?? BrowserUserAgent.mobileIdentifier
                } label: {
                    Label("复制标识", systemImage: "doc.on.doc")
                }
            } header: {
                Text("当前网页标识")
            } footer: {
                Text("标识由系统提供的平台与引擎部分，加上 Vela 补上的 Safari 部分拼成，版本号取自本机系统，因此系统升级后不需要更新应用。「页面实际收到」是从正在显示的页面里读回来的，如果某个网站说浏览器版本太低，先把这个串复制出来对照一下。")
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
                    env.settings.update { $0.customUserAgent = "" }
                    apply(reload: true)
                }
            } header: {
                Text("自定义标识")
            } footer: {
                Text("填写后覆盖上面的开关，此后打开的页面都用这个标识。重新载入当前页面即可看到效果。")
            }
        }
        .navigationTitle("网页标识")
        .navigationBarTitleDisplayMode(.inline)
        .task(id: identityKey) {
            await readIdentifierFromPage()
        }
    }

    /// One labelled identifier, in the monospaced type a string like this needs.
    private func identifierRow(title: String, value: String?, note: String?) -> some View {
        VStack(alignment: .leading, spacing: BrowserSpacing.hairline) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            if let value {
                Text(value)
                    .font(.system(size: 12, design: .monospaced))
                    .textSelection(.enabled)
            }
            if let note {
                Text(note)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }

    /// Reads the identifier back from the page the user is looking at.
    ///
    /// `navigator.userAgent` rather than `webView.customUserAgent`: the point is
    /// what the page received, and the custom value is only the part Vela sets —
    /// the platform and engine tokens are WebKit's and appear only here.
    private func readIdentifierFromPage() async {
        guard let tab = env.tabManager.activeTab,
              !tab.isHome,
              let webView = env.tabManager.webView(for: tab.id) else {
            identifierReportedByPage = nil
            return
        }
        let value = try? await webView.evaluateJavaScript("navigator.userAgent")
        let text = value as? String
        identifierReportedByPage = (text?.isEmpty == false) ? text : nil
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

// MARK: - About

/// The attribution section below is what the GPL-3.0 licence and the upstream
/// trademark policy require.
struct AboutView: View {
    @Environment(AppEnvironment.self) private var env

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
                Text("Vela 是 Aira Browser 的 iOS 移植。它保留了 Aira 的数据表结构和功能语义，并针对 iOS 平台重新实现。")
                    .font(.footnote)
                Text("上游项目：Aira Browser，以 GPL-3.0 发布。Vela 是修改后的分发版本，按照上游商标政策使用了自己的名称、应用标识和视觉标识。")
                    .font(.footnote)
            } header: {
                Text("关于本项目")
            }

            Section {
                Text("iOS 不允许使用第三方浏览器内核，因此 Vela 的网页渲染、网络请求和广告过滤都通过 WebKit 完成。以下能力因此受限：")
                    .font(.footnote)
                VStack(alignment: .leading, spacing: 6) {
                    limitation("广告过滤", "使用系统的 WKContentRuleList。规则语法支持常见的 Adblock Plus 子集，但正则规则、$csp、$rewrite 和扩展选择器无法表达。")
                    limitation("用户脚本", "在页面内执行，因此 GM_xmlhttpRequest、GM_download、GM_cookie 这类需要特权的接口不可用。申请了这些权限的脚本仍可安装，详情页会标注。")
                    limitation("下载", "由 WKDownload 完成，支持断点续传，但没有分片多连接和下载队列。")
                    limitation("统计", "WebKit 不报告被拦截的请求数，所以 Vela 不显示这个数字，只显示规则条数和实际隐藏的元素数。")
                    limitation("同步", "WebDAV 与自建 Personal Server 的数据模型已移植，客户端的同步调度尚未实现。")
                }
                .font(.caption)
            } header: {
                Text("能力边界")
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
