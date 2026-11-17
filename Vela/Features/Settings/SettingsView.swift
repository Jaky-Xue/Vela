//
//  SettingsView.swift
//  Vela
//
//  The settings centre and the sub-pages that hang off it.
//
//  The root is grouped by *what the setting acts on*, not by where the feature
//  was implemented: 浏览器 is the browser itself (startup, tabs, its own chrome
//  and look), 网页与内容 is what happens inside a page, 隐私与安全 is what the
//  app keeps or shows about its owner, and 关于 stays out of the way at
//  the end. The rows are deliberately wordless beyond their names and current
//  values — the section already says the context, and the screen behind the
//  row is where the detail belongs.
//
//  Two things make the map navigable: every destination owns a coloured icon,
//  so a row is recognised before it is read, and the search field above the
//  list filters by the row's name and by what the feature is called elsewhere
//  ("UA", "广告", "无痕"), rather than by the screen's title alone.
//
//  Only destinations with a backing implementation are listed, and the About
//  page records which of the remaining ones are absent rather than shipping
//  rows that lead nowhere. A settings row that opens an empty screen is worse
//  than an absent row.
//

import SwiftUI
import UIKit

struct SettingsView: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.browserPalette) private var palette
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    /// A page to open above the root. Any context that names a specific
    /// screen pushes it directly instead of landing the user on a list of
    /// nouns to hunt through.
    @State private var pushedDestination: SettingsDestination?
    /// What the search field holds. Empty means the whole map.
    @State private var searchText = ""

    init(initialDestination: SettingsDestination? = nil) {
        _pushedDestination = State(initialValue: initialDestination)
    }

    var body: some View {
        List {
            ForEach(visibleSections) { section in
                Section {
                    ForEach(section.rows) { row in
                        NavigationLink {
                            row.destination.view
                        } label: {
                            settingsRow(row)
                        }
                    }
                } header: {
                    Text(section.title)
                }
            }

            if visibleSections.isEmpty {
                Section {
                    VStack(spacing: 8) {
                        Image(systemName: "magnifyingglass")
                            .font(.title3)
                            .foregroundStyle(palette.secondaryText)
                        Text("没有找到匹配的设置项")
                            .font(.footnote)
                            .foregroundStyle(palette.secondaryText)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, BrowserSpacing.loose)
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                }
            }
        }
        .settingsList()
        .scrollDismissesKeyboard(.immediately)
        // A safe-area inset rather than a sibling above the list: the bar then
        // shares the list's own background instead of stacking a second veil
        // over the sheet, and it stays put while the rows scroll under it.
        .safeAreaInset(edge: .top, spacing: 0) {
            searchField
                .padding(.horizontal, BrowserSpacing.regular)
                .padding(.top, 8)
                .padding(.bottom, 10)
                // Rows scroll under the bar; the fill keeps them from reading
                // through it.
                .background { AmbientSurfaceFill(opacity: 0.58) }
        }
        .navigationDestination(item: $pushedDestination) { destination in
            destination.view
        }
        // The appearance is applied to the window and to the presented view
        // controllers (`AppearanceMode.applyToAllWindows`), so this sheet —
        // including the Appearance screen pushed from it — re-resolves its
        // colours without a per-sheet preference pin.
        .navigationTitle("设置")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("完成") { dismiss() }
            }
        }
    }

    // MARK: - Search

    /// The field above the list. It stays put while the rows scroll: the
    /// search is how a long list is avoided, so it should not be the first
    /// thing to scroll away.
    private var searchField: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(palette.secondaryText)
                .accessibilityHidden(true)

            TextField("搜索设置项", text: $searchText)
                .textFieldStyle(.plain)
                .font(.body)
                .foregroundStyle(palette.primaryText)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .submitLabel(.search)

            if !searchText.isEmpty {
                Button {
                    searchText = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(palette.secondaryText)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("清除搜索")
            }
        }
        .padding(.horizontal, 14)
        .frame(height: 46)
        .background(palette.controlFill, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(palette.cardStroke, lineWidth: 0.5)
                .allowsHitTesting(false)
        }
    }

    // MARK: - The map

    /// Every row, in the order the root shows them. The details are the values
    /// in force and are read from the environment at body time.
    private var allSections: [SettingsSectionSpec] {
        [
            SettingsSectionSpec(title: "账号", rows: [
                SettingsRowSpec(destination: .googleAccounts, detail: googleAccountsDetail)
            ]),
            SettingsSectionSpec(title: "浏览器", rows: [
                SettingsRowSpec(destination: .general),
                SettingsRowSpec(destination: .appearance, detail: appearanceDetail),
                SettingsRowSpec(destination: .toolbar),
                SettingsRowSpec(destination: .menuPanel),
                SettingsRowSpec(
                    destination: .downloads,
                    detail: env.downloads.activeCount > 0
                        ? "\(env.downloads.activeCount) 个进行中"
                        : ""
                )
            ]),
            SettingsSectionSpec(title: "网页与内容", rows: [
                SettingsRowSpec(
                    destination: .searchEngine,
                    detail: env.settings.preferences.searchEngine.activeEngine.name
                ),
                SettingsRowSpec(destination: .userAgent, detail: userAgentDetail),
                SettingsRowSpec(
                    destination: .userScripts,
                    detail: env.settings.preferences.userScriptsEnabled ? "" : "已关闭"
                ),
                SettingsRowSpec(destination: .contentBlocker, detail: contentBlockerDetail),
                SettingsRowSpec(
                    destination: .elementHide,
                    detail: env.settings.manualElementHide.sites.isEmpty
                        ? ""
                        : "\(env.settings.manualElementHide.sites.count) 个网站"
                )
            ]),
            SettingsSectionSpec(title: "隐私与安全", rows: [
                SettingsRowSpec(
                    destination: .passwords,
                    detail: env.passwords.credentials.isEmpty ? "" : "\(env.passwords.credentials.count) 条"
                ),
                SettingsRowSpec(
                    destination: .privateBrowsing,
                    detail: env.settings.preferences.lockPrivateTabs ? "需验证" : "无需验证"
                ),
                SettingsRowSpec(destination: .sitePermissions),
                SettingsRowSpec(
                    destination: .externalNavigation,
                    detail: env.settings.preferences.externalNavigationDefault.displayName
                ),
                SettingsRowSpec(
                    destination: .webrtc,
                    detail: env.settings.webRTCProtectionEnabled
                        ? env.settings.webRTCProtectionSelection.displayName
                        : "已关闭"
                ),
                SettingsRowSpec(destination: .clearData)
            ]),
            SettingsSectionSpec(title: "数据", rows: [
                SettingsRowSpec(destination: .dataTransfer)
            ]),
            SettingsSectionSpec(title: "关于", rows: [
                SettingsRowSpec(destination: .about)
            ])
        ]
    }

    /// The sections the search leaves standing. A section disappears with its
    /// last matching row, so the result is the answer rather than a set of
    /// empty headings.
    private var visibleSections: [SettingsSectionSpec] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return allSections }
        return allSections.compactMap { section in
            let rows = section.rows.filter { $0.matches(query) }
            return rows.isEmpty ? nil : SettingsSectionSpec(title: section.title, rows: rows)
        }
    }

    /// What the 外观 row says is in force: the palette by name and the
    /// appearance the app is actually using. The mode reads 跟随系统 in that
    /// case rather than naming a colour, because the row's job is to say what
    /// the user chose, not what the system decided for them.
    private var appearanceDetail: String {
        let paletteName = BrowserPalette.all
            .first { $0.id == env.settings.preferences.themePaletteId }?
            .displayName ?? BrowserPalette.default.displayName
        return "\(paletteName) · \(env.settings.appearanceMode.displayName)"
    }

    /// What the Google 账号 row says: how many addresses are listed, and
    /// whether the browser itself is signed in.
    private var googleAccountsDetail: String {
        let count = env.services.googleAccounts.accounts.count
        let listed = count == 0 ? "" : "\(count) 个账号"
        switch env.services.googleAccounts.browserSession {
        case .signedIn:
            return listed.isEmpty ? "已登录" : "\(listed) · 已登录"
        case .signedOut, .unknown:
            return listed
        }
    }

    /// What the 广告拦截 row says is in force.
    private var contentBlockerDetail: String {
        guard env.settings.contentBlocker.enabled else { return "已关闭" }
        let blocker = env.services.contentBlocker
        if blocker.isReady { return "\(blocker.ruleCount) 条规则" }
        return blocker.isCompiling ? "编译中" : "未就绪"
    }

    /// What the 网页标识 row says is in force: a chosen preset by its name, a
    /// hand-typed string as 自定义, or 自动. The page layout follows the
    /// identifier, so this one row answers both questions.
    private var userAgentDetail: String {
        let stored = env.settings.preferences.customUserAgent
        if !stored.isEmpty {
            return BrowserUserAgentPreset.all.first { $0.userAgent == stored }?.title ?? "自定义"
        }
        return "自动"
    }

    // MARK: - Rows

    /// One settings row: the destination's coloured tile, the name, and the
    /// value in force.
    ///
    /// The value is the only secondary line. It answers "what is set" — a
    /// palette name, a count, a mode — without the row restating what its
    /// screen contains; the root is a map, and opening a row is how a screen's
    /// scope becomes known.
    private func settingsRow(_ row: SettingsRowSpec) -> some View {
        HStack(spacing: 12) {
            SettingsRowIcon(
                symbolName: row.destination.symbolName,
                topHex: row.destination.iconTopHex,
                bottomHex: row.destination.iconBottomHex,
                filled: palette.visualStyle.icons == .filled
            )

            VStack(alignment: .leading, spacing: 4) {
                Text(row.title)
                    .foregroundStyle(palette.primaryText)
                if dynamicTypeSize.isAccessibilitySize && !row.detail.isEmpty {
                    Text(row.detail)
                        .font(.caption)
                        .foregroundStyle(palette.secondaryText)
                }
            }
            Spacer(minLength: 8)
            if !dynamicTypeSize.isAccessibilitySize && !row.detail.isEmpty {
                Text(row.detail)
                    .font(.caption)
                    .foregroundStyle(palette.secondaryText)
                    .lineLimit(1)
            }
        }
        .padding(.vertical, 3)
    }
}

// MARK: - Search models

/// One row of the settings map: the destination the row opens, and the value
/// the row states for it. The name, symbol, colour and search words all come
/// from the destination, so a row cannot drift away from its screen.
private struct SettingsRowSpec: Identifiable {
    var destination: SettingsDestination
    var detail: String = ""

    var id: String { destination.rawValue }
    var title: String { destination.title }

    func matches(_ query: String) -> Bool {
        title.localizedCaseInsensitiveContains(query)
            || destination.searchKeywords.localizedCaseInsensitiveContains(query)
    }
}

private struct SettingsSectionSpec: Identifiable {
    var title: String
    var rows: [SettingsRowSpec]

    var id: String { title }
}

// MARK: - Deep links

/// A settings screen a context can ask for by name.
///
/// The settings sheet is one NavigationStack; a context that says "网页标识"
/// should land on that screen rather than on the root. Every case here has a
/// row in `SettingsView`, so a deep link and the list cannot describe
/// different screens.
enum SettingsDestination: String, Identifiable, Hashable, CaseIterable {
    case googleAccounts
    case general
    case appearance
    case toolbar
    case menuPanel
    case downloads
    case searchEngine
    case userAgent
    case userScripts
    case contentBlocker
    case elementHide
    case passwords
    case privateBrowsing
    case sitePermissions
    case externalNavigation
    case webrtc
    case clearData
    case dataTransfer
    case about

    var id: String { rawValue }

    @MainActor
    @ViewBuilder
    var view: some View {
        switch self {
        case .googleAccounts: GoogleAccountsSettingsView()
        case .general: GeneralSettingsView()
        case .appearance: AppearanceSettingsView()
        case .toolbar: ToolbarSettingsView()
        case .menuPanel: MenuSettingsView()
        case .downloads: DownloadSettingsView()
        case .searchEngine: SearchEngineSettingsView()
        case .userAgent: UserAgentSettingsView()
        case .userScripts: UserScriptsView()
        case .contentBlocker: ContentBlockerSettingsView()
        case .elementHide: ElementHideSettingsView()
        case .passwords: PasswordVaultView()
        case .privateBrowsing: PrivateBrowsingSettingsView()
        case .sitePermissions: SitePermissionsSettingsView()
        case .externalNavigation: ExternalNavigationSettingsView()
        case .webrtc: WebRTCProtectionSettingsView()
        case .clearData: ClearDataView()
        case .dataTransfer: DataTransferSettingsView()
        case .about: AboutView()
        }
    }
}
