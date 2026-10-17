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
                    HomeSettingsView()
                } label: {
                    settingsRow(icon: "house", tint: .indigo, title: "主页")
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
                        detail: userAgentDetail
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

    /// What the 网页标识 row says is in force — the same answer the identifier
    /// screen gives, so the two cannot disagree: a chosen preset by its name,
    /// a hand-typed string as 自定义, and the desktop-site toggle only when no
    /// string overrides it.
    private var userAgentDetail: String {
        let stored = env.settings.preferences.customUserAgent
        if !stored.isEmpty {
            return BrowserUserAgentPreset.all.first { $0.userAgent == stored }?.title ?? "自定义"
        }
        return env.settings.preferences.desktopSiteByDefault ? "桌面版" : "手机版"
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
                Text("关闭的引擎不出现在地址栏的切换列表里。")
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

            Section {
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
            } header: {
                Text("搜索建议")
            } footer: {
                Text("关闭后地址栏不再显示任何建议。")
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
                    Text("用 {searchTerms} 表示搜索词。")
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
                Text("「跟随系统」随系统设置实时切换。")
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

/// Both appearances, side by side, drawn as the command bar actually looks.
///
/// The point is comparison without leaving the screen — and without the
/// ambiguity the previous preview carried: it rendered only the mode the user
/// was *not* in, so picking 深色 swapped the picture to a light one at the
/// moment the app itself went dark, and its layout was a top address bar the
/// real chrome no longer has. So this strip always shows both modes with the
/// same three-group bottom bar the browser draws — history buttons, the
/// omnibox field, the view controls — and marks the one currently in effect,
/// which is the one the user can compare against by looking up.
private struct AppearancePreviewStrip: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.browserPalette) private var palette
    @Environment(\.colorScheme) private var colorScheme

    /// The mode the app is actually rendering in: the user's choice, or the
    /// system's when the choice is 跟随系统.
    private var effectiveScheme: ColorScheme {
        switch env.settings.appearanceMode {
        case .light: return .light
        case .dark: return .dark
        case .system: return colorScheme
        }
    }

    var body: some View {
        HStack(spacing: 10) {
            AppearancePreviewCard(
                tokens: palette.tokens(for: .light),
                title: "浅色",
                isInEffect: effectiveScheme == .light
            )
            AppearancePreviewCard(
                tokens: palette.tokens(for: .dark),
                title: "深色",
                isInEffect: effectiveScheme == .dark
            )
        }
    }
}

/// One mode's miniature: the chrome's three groups over the page surface, at
/// the proportions of the real bar.
private struct AppearancePreviewCard: View {
    let tokens: BrowserColorTokens
    let title: String
    let isInEffect: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 5) {
                previewGroup {
                    Image(systemName: "chevron.left")
                    Image(systemName: "chevron.right")
                }

                HStack(spacing: 4) {
                    Image(systemName: "lock.fill")
                        .font(.system(size: 7, weight: .bold))
                        .foregroundStyle(.green)
                    Text("vela.example.com")
                        .font(.system(size: 9))
                        .foregroundStyle(tokens.secondaryText)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 7)
                .frame(height: 22)
                .frame(maxWidth: .infinity)
                .background(tokens.controlFill, in: RoundedRectangle(cornerRadius: 8, style: .continuous))

                previewGroup {
                    Image(systemName: "square.on.square")
                    Image(systemName: "ellipsis")
                }
            }
            .padding(6)
            .background(tokens.chrome, in: RoundedRectangle(cornerRadius: 14, style: .continuous))

            HStack(spacing: 4) {
                Text(title)
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(tokens.primaryText)
                if isInEffect {
                    Image(systemName: "checkmark")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(tokens.accent)
                }
            }
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(tokens.surface, in: RoundedRectangle(cornerRadius: BrowserRadius.card, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: BrowserRadius.card, style: .continuous)
                .strokeBorder(
                    isInEffect ? tokens.accent : tokens.cardStroke,
                    lineWidth: isInEffect ? 1.5 : 0.5
                )
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(isInEffect ? "\(title)预览，当前生效" : "\(title)预览")
    }

    /// One flanking group of glyphs, as the bar's chevron pair and view pair
    /// are drawn.
    private func previewGroup(@ViewBuilder glyphs: () -> some View) -> some View {
        HStack(spacing: 5) {
            glyphs()
        }
        .font(.system(size: 9, weight: .medium))
        .foregroundStyle(tokens.primaryText)
        .padding(.horizontal, 6)
        .frame(height: 22)
        .background(tokens.controlFill, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
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
                Text("超过保留期的记录会在下次访问时清理。")
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

/// A user-agent preset the identifier screen offers.
///
/// `userAgent` is the literal string a page will receive; `nil` means the
/// default, which WebKit assembles from its own platform tokens and is the one
/// preset that never goes stale.
struct BrowserUserAgentPreset: Identifiable, Equatable {
    let id: String
    let title: String
    let userAgent: String?
    let isDesktop: Bool

    static let all: [BrowserUserAgentPreset] = [
        BrowserUserAgentPreset(id: "default", title: "Vela 默认", userAgent: nil, isDesktop: false),
        BrowserUserAgentPreset(
            id: "safari-iphone", title: "Safari iPhone",
            userAgent: "Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Mobile/15E148 Safari/604.1",
            isDesktop: false
        ),
        BrowserUserAgentPreset(
            id: "chrome-android", title: "Chrome Android",
            userAgent: "Mozilla/5.0 (Linux; Android 14; Pixel 8) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/130.0.0.0 Mobile Safari/537.36",
            isDesktop: false
        ),
        BrowserUserAgentPreset(
            id: "arkweb", title: "ArkWeb 原始标识",
            userAgent: "Mozilla/5.0 (Phone; OpenHarmony 5.0) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/114.0.0.0 Safari/537.36 ArkWeb/5.0.0.0 Mobile",
            isDesktop: false
        ),
        BrowserUserAgentPreset(
            id: "huawei", title: "华为浏览器",
            userAgent: "Mozilla/5.0 (Linux; Android 14; Pixel 8) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/114.0.0.0 Mobile Safari/537.36 HuaweiBrowser/15.0.5.300",
            isDesktop: false
        ),
        BrowserUserAgentPreset(
            id: "chrome-windows", title: "Chrome Windows",
            userAgent: "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/130.0.0.0 Safari/537.36",
            isDesktop: true
        ),
        BrowserUserAgentPreset(
            id: "edge-windows", title: "Microsoft Edge Windows",
            userAgent: "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/130.0.0.0 Safari/537.36 Edg/130.0.0.0",
            isDesktop: true
        ),
        BrowserUserAgentPreset(
            id: "safari-macos", title: "Safari macOS",
            userAgent: "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Safari/605.1.15",
            isDesktop: true
        ),
        BrowserUserAgentPreset(
            id: "firefox-windows", title: "Firefox Windows",
            userAgent: "Mozilla/5.0 (Windows NT 10.0; Win64; x64; rv:132.0) Gecko/20100101 Firefox/132.0",
            isDesktop: true
        )
    ]
}

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
                : BrowserUserAgent.mobileIdentifier)
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
                Text("选择后，之后打开的页面都会以它出现。")
            }

            Section("移动端网页") {
                ForEach(BrowserUserAgentPreset.all.filter { !$0.isDesktop }) { preset in
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
                    env.settings.update { $0.customUserAgent = "" }
                    apply(reload: true)
                }
            } header: {
                Text("自定义标识")
            } footer: {
                Text("填写后覆盖上面选择的预设。")
            }

            Section {
                VStack(alignment: .leading, spacing: BrowserSpacing.compact) {
                    identifierRow(
                        title: "页面实际收到",
                        value: identifierReportedByPage,
                        note: identifierReportedByPage == nil
                            ? "打开网页后显示实际发出的标识。"
                            : nil
                    )
                    Divider()
                    identifierRow(
                        title: "将要发出",
                        value: effectiveOutgoingIdentifier,
                        note: nil
                    )
                }
                Button {
                    UIPasteboard.general.string = identifierReportedByPage ?? effectiveOutgoingIdentifier
                } label: {
                    Label("复制标识", systemImage: "doc.on.doc")
                }
            } header: {
                Text("当前网页标识")
            } footer: {
                Text("「页面实际收到」从当前页面读回，网站报版本太低时对照它。")
            }
        }
        .navigationTitle("网页标识")
        .navigationBarTitleDisplayMode(.inline)
        .task(id: identityKey) {
            await readIdentifierFromPage()
        }
    }

    /// One preset row with the reference screen's radio affordance: an empty
    /// ring for the choices not taken, a filled check for the one in force.
    private func presetRow(_ preset: BrowserUserAgentPreset) -> some View {
        let isSelected = selectedPreset?.id == preset.id
        return Button {
            env.settings.update { $0.customUserAgent = preset.userAgent ?? "" }
            apply(reload: true)
        } label: {
            HStack {
                Text(preset.title)
                Spacer(minLength: 8)
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 20, weight: .light))
                    .foregroundStyle(isSelected ? Color.blue : Color.secondary.opacity(0.55))
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
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

/// The attribution line below is what the GPL-3.0 licence and the upstream
/// trademark policy require; everything else on the screen stays out of the
/// way of the icon, the name and the version.
struct AboutView: View {
    @Environment(AppEnvironment.self) private var env

    /// Read from the bundle rather than written down: a version typed into a
    /// string is the one fact in this screen guaranteed to drift from the
    /// build it describes.
    private static let marketingVersion = Bundle.main.object(
        forInfoDictionaryKey: "CFBundleShortVersionString"
    ) as? String ?? "?"

    private static let buildVersion = Bundle.main.object(
        forInfoDictionaryKey: "CFBundleVersion"
    ) as? String ?? "?"

    var body: some View {
        List {
            Section {
                VStack(spacing: 10) {
                    // The icon as installed — the same asset the home screen
                    // shows — rather than a glyph standing in for it.
                    Image("AppLogo")
                        .resizable()
                        .scaledToFit()
                        .frame(width: 76, height: 76)
                        .clipShape(RoundedRectangle(cornerRadius: 17, style: .continuous))
                        .overlay {
                            RoundedRectangle(cornerRadius: 17, style: .continuous)
                                .strokeBorder(Color.white.opacity(0.14), lineWidth: 0.5)
                        }
                    Text("Vela")
                        .font(.title2.weight(.semibold))
                    Text("版本 \(Self.marketingVersion) (\(Self.buildVersion))")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
                .listRowBackground(Color.clear)
            }

            Section {
                LabeledContent("规则总数") {
                    Text("\(env.adBlock.ruleCount)")
                        .monospacedDigit()
                }
            } header: {
                Text("状态")
            }

            Section {
                Text("Vela 是 Aira Browser（GPL-3.0）的 iOS 移植版，以自己的名称与视觉标识分发。")
                    .font(.footnote)
                Link("GNU General Public License v3.0", destination: URL(string: "https://www.gnu.org/licenses/gpl-3.0.html")!)
                Link("Aira Browser 上游仓库", destination: URL(string: "https://github.com/mason173/aira-browser")!)
            } header: {
                Text("许可与致谢")
            }
        }
        .navigationTitle("关于")
        .navigationBarTitleDisplayMode(.inline)
    }
}
