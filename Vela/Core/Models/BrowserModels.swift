//
//  BrowserModels.swift
//  Vela
//
//  The shared browser vocabulary: profiles, data scopes, privacy modes, site
//  permissions, external-navigation policy, tracking protection, and the
//  preferences document these are read from.
//
//  Private browsing is a session privacy mode layered over an ephemeral
//  `WKWebsiteDataStore` rather than a second profile. The profile is fixed for
//  the life of the install; what changes is which data store a tab writes to,
//  and that is a property of the session, not of the identity.
//
//  Raw values are stable strings because they are persisted in the preferences
//  document and stored in the schema.
//

import Foundation

// MARK: - Profile and scope

public typealias BrowserProfileId = String
public let browserMainProfileId: BrowserProfileId = "profile-main"

public enum BrowserSessionPrivacyMode: String, Codable, Sendable, CaseIterable {
    case regular
    case `private`
}

public enum BrowserDataScope: String, Codable, Sendable, CaseIterable {
    case profilePersistent = "profile_persistent"
    case sessionEphemeral = "session_ephemeral"
}

public enum BrowserDataSource: String, Codable, Sendable, CaseIterable {
    case seed
    case local
    case chromeImport = "chrome_import"
    case chromeSync = "chrome_sync"
    case cloudSync = "cloud_sync"
}

public enum SyncState: String, Codable, Sendable, CaseIterable {
    case localOnly = "local_only"
    case pendingPush = "pending_push"
    case synced
    case conflict
}

// MARK: - Data boundary

/// One value decides whether a piece of browsing data is written to the durable
/// database or discarded with the session. Every write path in Vela takes a
/// boundary rather than reading privacy mode off a tab, so a private tab can
/// never leak a row into the persistent store.
public struct BrowserDataBoundary: Equatable, Sendable {
    public let profileId: BrowserProfileId
    public let dataScope: BrowserDataScope
    public let privacyMode: BrowserSessionPrivacyMode

    public init(
        profileId: BrowserProfileId = browserMainProfileId,
        dataScope: BrowserDataScope,
        privacyMode: BrowserSessionPrivacyMode
    ) {
        self.profileId = profileId
        self.dataScope = dataScope
        self.privacyMode = privacyMode
    }

    public static let persistent = BrowserDataBoundary(
        dataScope: .profilePersistent,
        privacyMode: .regular
    )

    public static let ephemeral = BrowserDataBoundary(
        dataScope: .sessionEphemeral,
        privacyMode: .private
    )

    /// True when this boundary may write to the durable database.
    public var persists: Bool { dataScope == .profilePersistent }

    public static func resolve(
        profileId: BrowserProfileId,
        privacyMode: BrowserSessionPrivacyMode
    ) -> BrowserDataBoundary {
        BrowserDataBoundary(
            profileId: normalizeBrowserProfileId(profileId),
            dataScope: privacyMode == .private ? .sessionEphemeral : .profilePersistent,
            privacyMode: privacyMode
        )
    }
}

public func normalizeBrowserProfileId(_ value: String) -> BrowserProfileId {
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? browserMainProfileId : trimmed
}

public func normalizeBrowserDataScope(_ value: String) -> BrowserDataScope {
    BrowserDataScope(rawValue: value) ?? .profilePersistent
}

public func normalizeBrowserSessionPrivacyMode(_ value: String) -> BrowserSessionPrivacyMode {
    BrowserSessionPrivacyMode(rawValue: value) ?? .regular
}

// MARK: - Site permissions

public enum SitePermissionKind: String, Codable, Sendable, CaseIterable, Identifiable {
    case camera
    case microphone
    case location
    case sensor
    case clipboard
    case notification

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .camera: return "相机"
        case .microphone: return "麦克风"
        case .location: return "位置"
        case .sensor: return "运动与方向"
        case .clipboard: return "剪贴板"
        case .notification: return "通知"
        }
    }

    public var symbolName: String {
        switch self {
        case .camera: return "camera"
        case .microphone: return "mic"
        case .location: return "location"
        case .sensor: return "gyroscope"
        case .clipboard: return "doc.on.clipboard"
        case .notification: return "bell"
        }
    }

    /// One sentence for the settings footer, saying how the gate is reached.
    public var requestSummary: String {
        switch self {
        case .camera: return "网页调用摄像头时询问。"
        case .microphone: return "网页录音时询问。"
        case .location: return "网页读取定位前询问；系统定位授权由 iOS 另外询问一次。"
        case .sensor: return "网页读取设备方向或运动数据时询问。"
        case .clipboard: return "网页读取剪贴板内容前询问。写入不受限制。"
        case .notification: return "网页请求通知权限时询问。iOS 的网页视图并不显示系统通知，答案只对网页自身可见。"
        }
    }
}

public enum SitePermissionRule: String, Codable, Sendable, CaseIterable {
    case ask
    case allow
    case block

    public var displayName: String {
        switch self {
        case .ask: return "询问"
        case .allow: return "允许"
        case .block: return "拒绝"
        }
    }
}

public struct SitePermissionDefaultSettings: Codable, Equatable, Sendable {
    public var camera: SitePermissionRule
    public var microphone: SitePermissionRule
    public var location: SitePermissionRule
    public var sensor: SitePermissionRule
    public var clipboard: SitePermissionRule
    /// Optional for decode compatibility: this struct lives inside the
    /// preferences document, which decodes as a whole, and a required key
    /// absent from an existing install would reset every setting with it.
    /// `nil` reads as 询问.
    public var notification: SitePermissionRule?

    public init(
        camera: SitePermissionRule = .ask,
        microphone: SitePermissionRule = .ask,
        location: SitePermissionRule = .ask,
        sensor: SitePermissionRule = .ask,
        clipboard: SitePermissionRule = .ask,
        notification: SitePermissionRule? = .ask
    ) {
        self.camera = camera
        self.microphone = microphone
        self.location = location
        self.sensor = sensor
        self.clipboard = clipboard
        self.notification = notification
    }

    public static let `default` = SitePermissionDefaultSettings()

    public subscript(kind: SitePermissionKind) -> SitePermissionRule {
        get {
            switch kind {
            case .camera: return camera
            case .microphone: return microphone
            case .location: return location
            case .sensor: return sensor
            case .clipboard: return clipboard
            case .notification: return notification ?? .ask
            }
        }
        set {
            switch kind {
            case .camera: camera = newValue
            case .microphone: microphone = newValue
            case .location: location = newValue
            case .sensor: sensor = newValue
            case .clipboard: clipboard = newValue
            case .notification: notification = newValue
            }
        }
    }
}

/// A decision the user made for one site and one kind of permission.
///
/// The site's request asks "以后对这个网站都这样"; this is where that answer
/// lives. A missing entry falls back to the session decision and then to the
/// kind's default, so a site the user never answered still follows the
/// default setting.
public struct SitePermissionSiteRule: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var host: String
    public var kind: SitePermissionKind
    public var rule: SitePermissionRule
    public var updatedAt: Date

    public init(
        id: String = UUID().uuidString,
        host: String,
        kind: SitePermissionKind,
        rule: SitePermissionRule,
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.host = host
        self.kind = kind
        self.rule = rule
        self.updatedAt = updatedAt
    }
}

// MARK: - External navigation

public enum ExternalNavigationAppOpenPolicy: String, Codable, Sendable, CaseIterable, Identifiable {
    case block
    case ask
    case allow

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .block: return "阻止"
        case .ask: return "询问"
        case .allow: return "允许"
        }
    }
}

public struct ExternalNavigationSiteRule: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var host: String
    public var policy: ExternalNavigationAppOpenPolicy
    public var updatedAt: Date

    public init(
        id: String = UUID().uuidString,
        host: String,
        policy: ExternalNavigationAppOpenPolicy,
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.host = host
        self.policy = policy
        self.updatedAt = updatedAt
    }
}

// MARK: - Tracking protection

/// `BrowserTrackingProtectionSettingsCoordinator`.
public enum TrackingProtectionLevel: String, Codable, Sendable, CaseIterable, Identifiable {
    /// No cross-site cookie blocking.
    case off
    /// Block third-party cookies only.
    case standard
    /// Block third-party cookies and known trackers.
    case strict

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .off: return "关闭"
        case .standard: return "标准"
        case .strict: return "严格"
        }
    }

    public var detail: String {
        switch self {
        case .off:
            return "允许所有 Cookie 与跨站跟踪。"
        case .standard:
            return "阻止第三方 Cookie，保留站点登录状态。"
        case .strict:
            return "阻止第三方 Cookie，并对已知跟踪脚本收紧。可能影响部分站点登录。"
        }
    }
}

public struct BrowserWebSecuritySettings: Codable, Equatable, Sendable {
    public var trackingProtection: TrackingProtectionLevel
    /// Send `Do Not Track: 1` on every navigation.
    public var sendDoNotTrack: Bool
    /// Upgrade `http://` navigations to `https://` when the host is known to serve TLS.
    public var httpsFirstNavigation: Bool
    /// Refuse navigations to hosts whose TLS chain failed, instead of offering a bypass.
    public var refuseInvalidCertificates: Bool

    public init(
        trackingProtection: TrackingProtectionLevel = .standard,
        sendDoNotTrack: Bool = false,
        httpsFirstNavigation: Bool = true,
        refuseInvalidCertificates: Bool = false
    ) {
        self.trackingProtection = trackingProtection
        self.sendDoNotTrack = sendDoNotTrack
        self.httpsFirstNavigation = httpsFirstNavigation
        self.refuseInvalidCertificates = refuseInvalidCertificates
    }

    public static let `default` = BrowserWebSecuritySettings()
}

// MARK: - Secure DNS

public enum SecureDnsMode: String, Codable, Sendable, CaseIterable, Identifiable {
    case automatic
    case secure
    case off

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .automatic: return "自动"
        case .secure: return "使用自定义服务器"
        case .off: return "关闭"
        }
    }
}

public struct SecureDnsProfile: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var name: String
    /// A DoH template URL, e.g. `https://dns.alidns.com/dns-query`.
    public var template: String
    public var isBuiltIn: Bool

    public init(id: String, name: String, template: String, isBuiltIn: Bool = false) {
        self.id = id
        self.name = name
        self.template = template
        self.isBuiltIn = isBuiltIn
    }

    /// The built-in catalogue of DNS providers.
    public static let builtInProfiles: [SecureDnsProfile] = [
        SecureDnsProfile(
            id: "alidns",
            name: "阿里云公共 DNS",
            template: "https://dns.alidns.com/dns-query",
            isBuiltIn: true
        ),
        SecureDnsProfile(
            id: "tencent",
            name: "腾讯 DNSPod",
            template: "https://doh.pub/dns-query",
            isBuiltIn: true
        ),
        SecureDnsProfile(
            id: "cloudflare",
            name: "Cloudflare",
            template: "https://cloudflare-dns.com/dns-query",
            isBuiltIn: true
        ),
        SecureDnsProfile(
            id: "google",
            name: "Google Public DNS",
            template: "https://dns.google/dns-query",
            isBuiltIn: true
        ),
        SecureDnsProfile(
            id: "quad9",
            name: "Quad9",
            template: "https://dns.quad9.net/dns-query",
            isBuiltIn: true
        )
    ]
}

public struct SecureDnsSettings: Codable, Equatable, Sendable {
    public var mode: SecureDnsMode
    public var selectedProfileId: String
    public var customProfiles: [SecureDnsProfile]

    public init(
        mode: SecureDnsMode = .automatic,
        selectedProfileId: String = "alidns",
        customProfiles: [SecureDnsProfile] = []
    ) {
        self.mode = mode
        self.selectedProfileId = selectedProfileId
        self.customProfiles = customProfiles
    }

    public static let `default` = SecureDnsSettings()

    public var allProfiles: [SecureDnsProfile] {
        SecureDnsProfile.builtInProfiles + customProfiles
    }
}

// MARK: - Preferences bundle

/// The full device-local settings document.
///
/// One `Codable` value rather than a key per setting, stored as a single
/// `UserDefaults` entry. Decoding it as a whole is why a new field has to be
/// optional: a required key would fail to decode on every existing install and
/// the settings would silently reset.
public struct BrowserPreferences: Codable, Equatable, Sendable {
    public var searchEngine: SearchEngineSettings
    public var webSecurity: BrowserWebSecuritySettings
    public var secureDns: SecureDnsSettings
    public var sitePermissions: SitePermissionDefaultSettings
    /// Per-site answers to 「以后对这个网站都这样」. Optional for the decode
    /// reason every optional field here carries.
    public var sitePermissionRules: [SitePermissionSiteRule]?
    public var externalNavigationDefault: ExternalNavigationAppOpenPolicy
    public var externalNavigationRules: [ExternalNavigationSiteRule]
    public var restoreTabsOnLaunch: Bool
    public var openNewTabsInBackground: Bool
    public var historyRetentionDays: Int
    public var lockPrivateTabs: Bool
    public var blurPrivateTabPreviews: Bool
    public var customUserAgent: String
    public var desktopSiteByDefault: Bool
    public var userScriptsEnabled: Bool
    public var homepageUrl: String
    public var themePaletteId: String
    /// The picture the retired 主页背景 feature saved, kept only so an
    /// existing install can be carried into `backgroundImageStamp`.
    ///
    /// Optional rather than defaulted because the preferences document decodes
    /// as a whole: a required key absent from an existing install's document
    /// would fail the decode and reset every setting with it.
    public var homeBackgroundStamp: Double?
    /// 全局背景图片，保存的是图片文件的时间戳；`nil` 表示使用全局背景样式。
    ///
    /// Optional for the same decode reason. The image itself lives on disk
    /// (`BackgroundImageStore`), not in this document, and a stamp of nil means
    /// the chosen `backgroundStyle` is what the shell draws.
    public var backgroundImageStamp: Double?
    /// 无痕模式的路由开关：开启后，所有没有指名隐私模式的新页面都以无痕
    /// 打开。Optional for the same decode reason as the two fields above —
    /// an absent key decodes to the default, which is off.
    public var privateBrowsingMode: Bool?
    /// 主页收藏的自定义：图标大小、磁贴形状、磁贴间距。三者都 optional，
    /// 缺省时走代码里的原值 — 解码原因同上，老安装的文档里没有这些键。
    public var homeTileIconSize: Double?
    public var homeTileShape: String?
    public var homeTileSpacing: Double?
    /// 全局顶部保护：页面内容只从系统状态栏下方开始，不滚动到时钟底下。
    ///
    /// Optional for the same reason `homeBackgroundStamp` is — the preferences
    /// document decodes as a whole, and a required key absent from an existing
    /// install's document would fail the decode and reset every setting with
    /// it. `nil` decodes to the default, which is protection on.
    public var topProtection: Bool?
    /// 全局背景样式：纯净、曜黑、暖阳、晚霞、青柠、极光、冰川、紫雾、缤纷。
    /// `nil` 是纯净。
    public var backgroundStyle: String?
    /// 底部工具栏两侧的控件，按用户拖拽的顺序保存。
    ///
    /// The omnibox stays in the middle and is not part of either list; only the
    /// clusters around it are user-ordered. `nil` means the shipped layout —
    /// back on the left, tabs and menu on the right.
    public var toolbarLeadingItems: [String]?
    public var toolbarTrailingItems: [String]?
    /// 小说阅读器的字号与外观偏好。Optional for the decode reason
    /// above: an absent key must not reset the rest of the document.
    public var readerFontSize: Double?
    public var readerAppearance: String?
    /// 保险箱是否要求面容/触控 ID（设备密码可作为回退）。默认开启。
    public var vaultRequireBiometrics: Bool?
    /// 菜单面板的排列：全部条目 id、隐藏的 id、自定义网址快捷方式。
    /// Optional for the same decode reason as every other new preference.
    public var menuOrder: [String]?
    public var menuHiddenItems: [String]?
    public var menuShortcuts: [MenuShortcut]?
    /// WebRTC 防泄露策略的原始值，见 `WebRTCProtectionMode`。
    public var webRTCProtection: String?
    /// 是否启用 WebRTC 防护。`nil` 时视为启用，与旧的默认行为一致。
    public var webRTCProtectionEnabled: Bool?
    /// 界面形态：跟随设备、手机布局或 iPad 布局。
    public var interfaceLayout: String?
    /// iPad 顶部工具栏两侧的可自定义控件；侧边栏按钮和菜单是固定的。
    public var padToolbarLeadingItems: [String]?
    public var padToolbarTrailingItems: [String]?
    /// 不保留历史记录：开启后新的访问不再写入历史。
    public var historyNotRetained: Bool?
    /// 不保留标签页：开启后浏览器不保留任何标签页痕迹——不写会话、不记录
    /// 「最近关闭」、不保存预览图片。当前打开的标签页不受影响。
    public var tabsNotRetained: Bool?
    /// 小说阅读的翻页方式：scroll 或 paged。
    public var novelPageMode: String?
    /// 强制网页缩放：允许用双指手势缩放每一页，包括声明了
    /// `user-scalable=no` 的页面。Optional for decode compatibility — an
    /// absent key must not reset the rest of the document.
    public var forcedZoomEnabled: Bool?

    public init(
        searchEngine: SearchEngineSettings = .default,
        webSecurity: BrowserWebSecuritySettings = .default,
        secureDns: SecureDnsSettings = .default,
        sitePermissions: SitePermissionDefaultSettings = .default,
        sitePermissionRules: [SitePermissionSiteRule]? = nil,
        externalNavigationDefault: ExternalNavigationAppOpenPolicy = .ask,
        externalNavigationRules: [ExternalNavigationSiteRule] = [],
        restoreTabsOnLaunch: Bool = true,
        openNewTabsInBackground: Bool = false,
        historyRetentionDays: Int = 90,
        lockPrivateTabs: Bool = false,
        blurPrivateTabPreviews: Bool = true,
        customUserAgent: String = "",
        desktopSiteByDefault: Bool = false,
        userScriptsEnabled: Bool = true,
        homepageUrl: String = "about:home",
        themePaletteId: String = "default",
        homeBackgroundStamp: Double? = nil,
        backgroundImageStamp: Double? = nil,
        topProtection: Bool? = true,
        privateBrowsingMode: Bool? = false,
        homeTileIconSize: Double? = nil,
        homeTileShape: String? = nil,
        homeTileSpacing: Double? = nil,
        backgroundStyle: String? = nil,
        toolbarLeadingItems: [String]? = nil,
        toolbarTrailingItems: [String]? = nil,
        readerFontSize: Double? = nil,
        readerAppearance: String? = nil,
        vaultRequireBiometrics: Bool? = nil,
        menuOrder: [String]? = nil,
        menuHiddenItems: [String]? = nil,
        menuShortcuts: [MenuShortcut]? = nil,
        webRTCProtection: String? = nil,
        webRTCProtectionEnabled: Bool? = nil,
        interfaceLayout: String? = nil,
        padToolbarLeadingItems: [String]? = nil,
        padToolbarTrailingItems: [String]? = nil,
        historyNotRetained: Bool? = nil,
        tabsNotRetained: Bool? = nil,
        novelPageMode: String? = nil,
        forcedZoomEnabled: Bool? = nil
    ) {
        self.searchEngine = searchEngine
        self.webSecurity = webSecurity
        self.secureDns = secureDns
        self.sitePermissions = sitePermissions
        self.sitePermissionRules = sitePermissionRules
        self.externalNavigationDefault = externalNavigationDefault
        self.externalNavigationRules = externalNavigationRules
        self.restoreTabsOnLaunch = restoreTabsOnLaunch
        self.openNewTabsInBackground = openNewTabsInBackground
        self.historyRetentionDays = historyRetentionDays
        self.lockPrivateTabs = lockPrivateTabs
        self.blurPrivateTabPreviews = blurPrivateTabPreviews
        self.customUserAgent = customUserAgent
        self.desktopSiteByDefault = desktopSiteByDefault
        self.userScriptsEnabled = userScriptsEnabled
        self.homepageUrl = homepageUrl
        self.themePaletteId = themePaletteId
        self.homeBackgroundStamp = homeBackgroundStamp
        self.backgroundImageStamp = backgroundImageStamp
        self.topProtection = topProtection
        self.privateBrowsingMode = privateBrowsingMode
        self.homeTileIconSize = homeTileIconSize
        self.homeTileShape = homeTileShape
        self.homeTileSpacing = homeTileSpacing
        self.backgroundStyle = backgroundStyle
        self.toolbarLeadingItems = toolbarLeadingItems
        self.toolbarTrailingItems = toolbarTrailingItems
        self.readerFontSize = readerFontSize
        self.readerAppearance = readerAppearance
        self.vaultRequireBiometrics = vaultRequireBiometrics
        self.menuOrder = menuOrder
        self.menuHiddenItems = menuHiddenItems
        self.menuShortcuts = menuShortcuts
        self.webRTCProtection = webRTCProtection
        self.webRTCProtectionEnabled = webRTCProtectionEnabled
        self.interfaceLayout = interfaceLayout
        self.padToolbarLeadingItems = padToolbarLeadingItems
        self.padToolbarTrailingItems = padToolbarTrailingItems
        self.historyNotRetained = historyNotRetained
        self.tabsNotRetained = tabsNotRetained
        self.novelPageMode = novelPageMode
        self.forcedZoomEnabled = forcedZoomEnabled
    }

    /// The resolved switch: protection is on unless explicitly turned off.
    public var topProtectionEnabled: Bool { topProtection ?? true }

    /// The most specific stored answer for a site and permission kind.
    ///
    /// A rule stored for `example.com` applies to `www.example.com` as well;
    /// an exact host match wins over a parent, and the longest parent wins
    /// over a shorter one. `nil` means the user has not answered for this site.
    public func sitePermissionRule(host: String, kind: SitePermissionKind) -> SitePermissionRule? {
        let normalized = host.lowercased()
        guard let rules = sitePermissionRules else { return nil }
        let matches = rules.filter { rule in
            rule.kind == kind
                && (normalized == rule.host || normalized.hasSuffix("." + rule.host))
        }
        return matches.max { lhs, rhs in lhs.host.count < rhs.host.count }?.rule
    }

    public static let `default` = BrowserPreferences()
}
