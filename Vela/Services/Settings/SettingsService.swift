//
//  SettingsService.swift
//  Vela
//
//  Device-local settings.
//
//  `UserDefaults` holds one JSON document per settings domain, decoded as a whole
//  and republished as a single observable value. Keeping a domain in one document
//  is why a new field is only safe to add when it is optional: a required key
//  would make every existing install's document fail to decode, and the settings
//  would silently reset to defaults on the next launch.
//
//  Nothing here is synced by default. User scripts and ad-block subscriptions are
//  local-only, and that extends to the whole settings document — a user who wants
//  settings on their other devices opts into WebDAV explicitly.
//

import Foundation
import Observation

@MainActor
@Observable
public final class SettingsService {
    private enum Key {
        static let preferences = "org.vela.browser.preferences"
        static let userScripts = "org.vela.browser.userscripts"
        static let manualElementHide = "org.vela.browser.manual-element-hide"
        static let appearanceMode = "org.vela.browser.appearance-mode"
        static let navigationDiagnostics = "org.vela.browser.navigation-diagnostics"
    }

    public private(set) var preferences: BrowserPreferences {
        didSet { persistPreferences() }
    }

    /// Light, dark, or whatever the system says.
    ///
    /// A user-chosen appearance override, which is what makes "follow the system"
    /// something that can be departed from. It lives here rather than inside
    /// `BrowserPreferences` because that document is decoded as a whole: a new
    /// non-optional key would make every existing install's document fail to
    /// decode, and the settings would silently reset to defaults on the next
    /// launch.
    public private(set) var appearanceMode: AppearanceMode {
        didSet { defaults.set(appearanceMode.rawValue, forKey: Key.appearanceMode) }
    }

    public private(set) var downloadSettings: DownloadSettings {
        didSet { persist(downloadSettings, key: "org.vela.browser.download-settings") }
    }

    public private(set) var manualElementHide: ManualElementHideSettings {
        didSet { persist(manualElementHide, key: Key.manualElementHide) }
    }

    /// Whether the navigation log records anything.
    ///
    /// A document of its own rather than a field inside `BrowserPreferences`, for
    /// the reason given above: the preferences document decodes as a whole, so a
    /// new key in it would reset every existing install's settings.
    public private(set) var navigationDiagnostics: NavigationDiagnosticsSettings {
        didSet { persist(navigationDiagnostics, key: Key.navigationDiagnostics) }
    }

    private let defaults: UserDefaults
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.preferences = Self.load(BrowserPreferences.self, key: Key.preferences, from: defaults)
            ?? .default
        self.downloadSettings = Self.load(DownloadSettings.self, key: "org.vela.browser.download-settings", from: defaults)
            ?? .default
        self.manualElementHide = Self.load(ManualElementHideSettings.self, key: Key.manualElementHide, from: defaults)
            ?? .default
        self.navigationDiagnostics = Self.load(
            NavigationDiagnosticsSettings.self,
            key: Key.navigationDiagnostics,
            from: defaults
        ) ?? .default
        // An unknown or absent value follows the system, which is the only
        // default that cannot surprise someone who never opens the setting.
        self.appearanceMode = defaults.string(forKey: Key.appearanceMode)
            .flatMap(AppearanceMode.init(rawValue:)) ?? .system

        // The history repository reads this key directly during its prune pass,
        // so the retention window is mirrored where the write path can see it.
        defaults.set(preferences.historyRetentionDays, forKey: "org.vela.browser.history-retention-days")
    }

    private static func load<T: Decodable>(_ type: T.Type, key: String, from defaults: UserDefaults) -> T? {
        guard let data = defaults.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }

    private func persist<T: Encodable>(_ value: T, key: String) {
        guard let data = try? encoder.encode(value) else { return }
        defaults.set(data, forKey: key)
    }

    private func persistPreferences() {
        persist(preferences, key: Key.preferences)
        defaults.set(preferences.historyRetentionDays, forKey: "org.vela.browser.history-retention-days")
    }

    // MARK: - Mutation

    /// Applies a change and persists in one step.
    ///
    /// A single `update` entry point rather than a setter per field, so that
    /// every settings screen goes through the same persist path and no screen
    /// can forget to write.
    public func update(_ mutate: (inout BrowserPreferences) -> Void) {
        var copy = preferences
        mutate(&copy)
        preferences = copy
    }

    public func updateDownloadSettings(_ mutate: (inout DownloadSettings) -> Void) {
        var copy = downloadSettings
        mutate(&copy)
        downloadSettings = copy
    }

    public func updateManualElementHide(_ mutate: (inout ManualElementHideSettings) -> Void) {
        var copy = manualElementHide
        mutate(&copy)
        manualElementHide = copy
    }

    public func updateNavigationDiagnostics(_ mutate: (inout NavigationDiagnosticsSettings) -> Void) {
        var copy = navigationDiagnostics
        mutate(&copy)
        navigationDiagnostics = copy
    }

    // MARK: - Appearance

    public func setAppearanceMode(_ mode: AppearanceMode) {
        guard mode != appearanceMode else { return }
        appearanceMode = mode
    }

    /// The global background style, resolved from its stored raw value.
    public var backgroundStyle: BrowserBackgroundStyle {
        get { BrowserBackgroundStyle.resolve(preferences.backgroundStyle) }
        set { update { $0.backgroundStyle = newValue.rawValue } }
    }

    // MARK: - Bottom toolbar

    /// The order of the two clusters around the omnibox.
    var toolbarLayout: ToolbarLayout {
        get {
            ToolbarLayout(
                storedLeading: preferences.toolbarLeadingItems,
                storedTrailing: preferences.toolbarTrailingItems
            )
        }
        set {
            update { preferences in
                preferences.toolbarLeadingItems = newValue.leading.map(\.rawValue)
                preferences.toolbarTrailingItems = newValue.trailing.map(\.rawValue)
            }
        }
    }

    // MARK: - Interface

    /// Which chrome the shell draws. `跟随设备` is the default.
    public var interfaceLayout: InterfaceLayoutMode {
        get { InterfaceLayoutMode.resolve(preferences.interfaceLayout) }
        set { update { $0.interfaceLayout = newValue.rawValue } }
    }

    /// The iPad top bar's user-controlled clusters.
    var padToolbarLayout: ToolbarLayout {
        get {
            var value = ToolbarLayout(
                storedLeading: preferences.padToolbarLeadingItems,
                storedTrailing: preferences.padToolbarTrailingItems,
                defaultLeading: ToolbarLayout.defaultPadLeading,
                defaultTrailing: ToolbarLayout.defaultPadTrailing
            )
            // The top bar draws the menu button itself; a stored copy would
            // appear twice.
            value.leading.removeAll { $0 == .menu }
            value.trailing.removeAll { $0 == .menu }
            return value
        }
        set {
            update { preferences in
                preferences.padToolbarLeadingItems = newValue.leading.map(\.rawValue)
                preferences.padToolbarTrailingItems = newValue.trailing.map(\.rawValue)
            }
        }
    }

    // MARK: - Menu panel

    /// The panel's order, hidden built-ins and custom shortcuts.
    var menuLayout: MenuLayout {
        get {
            MenuLayout(
                orderRaw: preferences.menuOrder,
                hiddenRaw: preferences.menuHiddenItems,
                shortcutsRaw: preferences.menuShortcuts
            )
        }
        set {
            update { preferences in
                preferences.menuOrder = newValue.order
                preferences.menuHiddenItems = newValue.hidden.sorted()
                preferences.menuShortcuts = newValue.shortcuts
            }
        }
    }

    // MARK: - WebRTC

    /// Whether the WebRTC guard runs at all. Defaults to on.
    public var webRTCProtectionEnabled: Bool {
        get { preferences.webRTCProtectionEnabled ?? true }
        set { update { $0.webRTCProtectionEnabled = newValue } }
    }

    /// The protection mode the user picked, regardless of the on/off switch.
    /// Selecting a mode also turns protection on.
    public var webRTCProtectionSelection: WebRTCProtectionMode {
        get { WebRTCProtectionMode.resolve(preferences.webRTCProtection) }
        set {
            update { preferences in
                preferences.webRTCProtection = newValue.rawValue
                preferences.webRTCProtectionEnabled = true
            }
        }
    }

    /// The mode in force for the page scripts: `允许` when the switch is off.
    public var webRTCProtection: WebRTCProtectionMode {
        get { webRTCProtectionEnabled ? webRTCProtectionSelection : .allow }
        set {
            update { preferences in
                preferences.webRTCProtection = newValue.rawValue
                preferences.webRTCProtectionEnabled = newValue != .allow
            }
        }
    }

    // MARK: - Reading

    /// The font size shared by reader mode and novel mode, in points.
    public var readingFontSize: Double {
        get {
            guard let stored = preferences.readerFontSize, stored >= 12, stored <= 40 else {
                return 19
            }
            return stored
        }
        set { update { $0.readerFontSize = newValue } }
    }

    // MARK: - Search

    public var searchEngineSettings: SearchEngineSettings {
        get { preferences.searchEngine }
        set { update { $0.searchEngine = newValue } }
    }

    public func setDefaultSearchEngine(id: SearchEngineId) {
        update { $0.searchEngine.defaultSearchEngineId = id }
    }

    public func setSearchEngineEnabled(_ enabled: Bool, id: BuiltInSearchEngineId) {
        update { preferences in
            var ids = preferences.searchEngine.enabledBuiltInEngineIds
            if enabled {
                guard !ids.contains(id.rawValue) else { return }
                ids.append(id.rawValue)
            } else {
                ids.removeAll { $0 == id.rawValue }
            }
            // The last enabled engine cannot be turned off, or the omnibox has
            // nothing to search with.
            guard !ids.isEmpty else { return }
            preferences.searchEngine.enabledBuiltInEngineIds = ids
            if !ids.contains(preferences.searchEngine.defaultSearchEngineId) {
                preferences.searchEngine.defaultSearchEngineId = ids[0]
            }
        }
    }

    public func addCustomSearchEngine(_ engine: SearchEngineRecord) {
        update { preferences in
            var record = engine
            record.position = preferences.searchEngine.customEngines.count
            preferences.searchEngine.customEngines.append(record)
        }
    }

    public func removeCustomSearchEngine(id: SearchEngineId) {
        update { preferences in
            preferences.searchEngine.customEngines.removeAll { $0.id == id }
            // Deleting the engine currently in use falls back to the shipped
            // default rather than leaving a dangling id.
            if preferences.searchEngine.defaultSearchEngineId == id {
                preferences.searchEngine.defaultSearchEngineId = defaultSearchEngineId
            }
        }
    }

    // MARK: - Ad block

    public var adBlockSettings: AdBlockSettings {
        get { preferences.adBlock }
        set { update { $0.adBlock = newValue } }
    }

    public func setAdBlockEnabled(_ enabled: Bool) {
        update { $0.adBlock.preferences.enabled = enabled }
    }

    public func setRuleSourceEnabled(_ enabled: Bool, sourceId: String) {
        update { preferences in
            if let index = preferences.adBlock.ruleSources.firstIndex(where: { $0.id == sourceId }) {
                preferences.adBlock.ruleSources[index].enabled = enabled
            } else {
                preferences.adBlock.ruleSources.append(
                    AdBlockCustomRuleSource(id: sourceId, name: sourceId, sourceType: .remote, enabled: enabled)
                )
            }
        }
    }

    public func addAdBlockSiteException(host: String) {
        update { preferences in
            let normalized = host.lowercased()
            guard !preferences.adBlock.preferences.siteExceptions.contains(where: { $0.host == normalized })
            else { return }
            preferences.adBlock.preferences.siteExceptions.append(
                AdBlockSiteException(host: normalized)
            )
        }
    }

    public func removeAdBlockSiteException(host: String) {
        update { preferences in
            preferences.adBlock.preferences.siteExceptions.removeAll { $0.host == host.lowercased() }
        }
    }

    public func setLocalAdBlockRules(_ rules: [String]) {
        update { $0.adBlock.preferences.localRules = rules }
    }

    // MARK: - Manual element hide

    public func addManualElementHide(selector: String, host: String) {
        updateManualElementHide { settings in
            let normalized = host.lowercased()
            if let index = settings.sites.firstIndex(where: { $0.host == normalized }) {
                guard !settings.sites[index].rules.contains(where: { $0.selector == selector }) else { return }
                settings.sites[index].rules.append(ManualElementHideRule(selector: selector))
            } else {
                settings.sites.append(
                    ManualElementHideSiteRules(
                        host: normalized,
                        rules: [ManualElementHideRule(selector: selector)]
                    )
                )
            }
        }
    }

    public func removeManualElementHide(ruleId: String, host: String) {
        updateManualElementHide { settings in
            guard let index = settings.sites.firstIndex(where: { $0.host == host.lowercased() }) else { return }
            settings.sites[index].rules.removeAll { $0.id == ruleId }
            if settings.sites[index].rules.isEmpty {
                settings.sites.remove(at: index)
            }
        }
    }

    // MARK: - Web security

    public var webSecurity: BrowserWebSecuritySettings {
        get { preferences.webSecurity }
        set { update { $0.webSecurity = newValue } }
    }

    public var secureDns: SecureDnsSettings {
        get { preferences.secureDns }
        set { update { $0.secureDns = newValue } }
    }

    // MARK: - Site permissions

    public func setSitePermissionDefault(_ rule: SitePermissionRule, kind: SitePermissionKind) {
        update { preferences in
            preferences.sitePermissions[kind] = rule
        }
    }

    // MARK: - External navigation

    public func setExternalNavigationDefault(_ policy: ExternalNavigationAppOpenPolicy) {
        update { $0.externalNavigationDefault = policy }
    }

    public func setExternalNavigationRule(host: String, policy: ExternalNavigationAppOpenPolicy) {
        update { preferences in
            let normalized = host.lowercased()
            if let index = preferences.externalNavigationRules.firstIndex(where: { $0.host == normalized }) {
                preferences.externalNavigationRules[index].policy = policy
                preferences.externalNavigationRules[index].updatedAt = Date()
            } else {
                preferences.externalNavigationRules.append(
                    ExternalNavigationSiteRule(host: normalized, policy: policy)
                )
            }
        }
    }

    /// Resolves the policy for a host: an explicit rule wins, otherwise the
    /// default applies.
    public func externalNavigationPolicy(for host: String) -> ExternalNavigationAppOpenPolicy {
        explicitExternalNavigationRule(for: host)?.policy ?? preferences.externalNavigationDefault
    }

    /// Whether the user has decided this host's policy themselves.
    ///
    /// The distinction matters for app deep links. A scheme like `bilibili://`
    /// asks to leave the browser, and the app refuses that unless the user has
    /// said otherwise *for that site* — a global default set once is not consent
    /// for every site on the web to pull the user out of the browser.
    public func hasExplicitExternalNavigationRule(for host: String) -> Bool {
        explicitExternalNavigationRule(for: host) != nil
    }

    /// The most specific rule for a host, or `nil` when none applies.
    private func explicitExternalNavigationRule(for host: String) -> ExternalNavigationSiteRule? {
        let normalized = host.lowercased()
        if let rule = preferences.externalNavigationRules.first(where: { $0.host == normalized }) {
            return rule
        }
        return preferences.externalNavigationRules.first(where: {
            normalized.hasSuffix("." + $0.host)
        })
    }

    // MARK: - Reset

    /// Clears every settings domain. The database is cleared separately by
    /// `BrowserDatabase.eraseAllData`.
    public func resetAll() {
        for key in defaults.dictionaryRepresentation().keys
        where key.hasPrefix("org.vela.browser.") {
            // The device id and the download destination bookmark survive a
            // reset: the first is identity rather than a preference, and losing
            // the second would silently strand the user's download folder.
            if key == "org.vela.browser.device-id" { continue }
            if key == "org.vela.browser.download-destination-bookmark" { continue }
            defaults.removeObject(forKey: key)
        }
        preferences = .default
        downloadSettings = .default
        manualElementHide = .default
        appearanceMode = .system
    }
}
