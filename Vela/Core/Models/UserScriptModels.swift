//
//  UserScriptModels.swift
//  Vela
//
//  Everything a user script declares: the metadata-block fields, the `@grant`
//  catalogue, the `@run-at` values and the parse result.
//
//  Scripts run through `WKUserScript`, which fixes the injection points to
//  document start and document end. Grants the userscript API defines but this
//  app cannot honour are still declared, so a script requesting them installs;
//  the ones that will not work are reported on the script's detail screen rather
//  than silently dropped.
//

import Foundation

public enum UserScriptRunAt: String, Codable, Sendable, CaseIterable {
    case documentStart = "document-start"
    /// Runs once `<body>` exists. WKWebView has no separate hook for it, so it
    /// is injected at document end, which is after the body is parsed.
    case documentBody = "document-body"
    case documentIdle = "document-idle"
    case documentEnd = "document-end"
    /// Menu-only values: the script registers commands rather than running on load.
    case mainMenu = "main-menu"
    case toolMenu = "tool-menu"
    case contextMenu = "context-menu"

    public var displayName: String {
        switch self {
        case .documentStart: return "文档开始前"
        case .documentBody: return "body 出现后"
        case .documentIdle: return "文档空闲时"
        case .documentEnd: return "文档加载完成后"
        case .mainMenu: return "仅主菜单"
        case .toolMenu: return "仅工具菜单"
        case .contextMenu: return "仅右键菜单"
        }
    }

    /// True when the script body should be injected into the page at all.
    /// Menu-only values are not injected on load.
    public var injectsOnLoad: Bool {
        switch self {
        case .documentStart, .documentBody, .documentIdle, .documentEnd: return true
        case .mainMenu, .toolMenu, .contextMenu: return false
        }
    }
}

public enum UserScriptGrant: String, Codable, Sendable, CaseIterable {
    case none
    case gmAddStyle = "GM_addStyle"
    case gmAddElement = "GM_addElement"
    case gmGetValue = "GM_getValue"
    case gmGetValues = "GM_getValues"
    case gmSetValue = "GM_setValue"
    case gmSetValues = "GM_setValues"
    case gmDeleteValue = "GM_deleteValue"
    case gmDeleteValues = "GM_deleteValues"
    case gmListValues = "GM_listValues"
    case gmGetResourceText = "GM_getResourceText"
    case gmGetResourceURL = "GM_getResourceURL"
    case gmXmlhttpRequest = "GM_xmlhttpRequest"
    case gmFetch = "GM_fetch"
    case gmDownload = "GM_download"
    case gmOpenInTab = "GM_openInTab"
    case gmGetTab = "GM_getTab"
    case gmSaveTab = "GM_saveTab"
    case gmGetTabs = "GM_getTabs"
    case gmSetClipboard = "GM_setClipboard"
    case gmCookie = "GM_cookie"
    case gmCookieSet = "GM_cookieSet"
    case gmCookieDelete = "GM_cookieDelete"
    case gmLog = "GM_log"
    case gmNotification = "GM_notification"
    case gmInfo = "GM_info"
    case gmRegisterMenuCommand = "GM_registerMenuCommand"
    case gmUnregisterMenuCommand = "GM_unregisterMenuCommand"
    case gmAddValueChangeListener = "GM_addValueChangeListener"
    case gmRemoveValueChangeListener = "GM_removeValueChangeListener"
    case gmExGetSearchEngines = "GM_EX_getSearchEngines"
    case gmExGetAppSearchEngineUrl = "GM_EX_getAppSearchEngineUrl"
    case gmExTTS = "GM_EX_TTS"
    case gmExShareTextToApp = "GM_EX_ShareTextToApp"
    case gmExSniffMedia = "GM_EX_sniffMedia"
    case windowOnUrlChange = "window.onurlchange"
    case windowClose = "window.close"
    case windowFocus = "window.focus"
    case unsafeWindow
    case unknown

    /// Decodes a grant token. Unknown tokens are kept as `.unknown` rather than
    /// failing the install: a script written for a newer manager should still
    /// install, with the unhonoured grant reported.
    public init(token: String) {
        self = UserScriptGrant(rawValue: token) ?? .unknown
    }

    /// Whether Vela can honour this grant in a `WKWebView`.
    ///
    /// Most grants are implemented in the injected bridge. The ones that need
    /// a capability the page world does not have — cross-origin requests,
    /// cookies, downloads, opening a tab, a per-tab store — are routed through
    /// the app with an asynchronous resolver, which is why they can be honoured
    /// here at all. The Huawei extension APIs and native window control remain
    /// unsupported.
    public var isSupportedByVela: Bool {
        switch self {
        case .none,
             .gmAddStyle, .gmAddElement,
             .gmGetValue, .gmGetValues, .gmSetValue, .gmSetValues,
             .gmDeleteValue, .gmDeleteValues, .gmListValues,
             .gmGetResourceText, .gmGetResourceURL,
             .gmLog, .gmInfo, .gmNotification, .gmSetClipboard,
             .gmRegisterMenuCommand, .gmUnregisterMenuCommand,
             .gmAddValueChangeListener, .gmRemoveValueChangeListener,
             .gmXmlhttpRequest, .gmFetch, .gmDownload, .gmOpenInTab,
             .gmGetTab, .gmSaveTab, .gmGetTabs,
             .gmCookie, .gmCookieSet, .gmCookieDelete,
             .windowOnUrlChange, .unsafeWindow, .unknown:
            return true
        case .gmExGetSearchEngines, .gmExGetAppSearchEngineUrl,
             .gmExTTS, .gmExShareTextToApp, .gmExSniffMedia,
             .windowClose, .windowFocus:
            return false
        }
    }
}

public enum UserScriptPackageSource: String, Codable, Sendable, CaseIterable {
    case paste
    case url
    case file
}

public enum UserScriptInstallSource: String, Codable, Sendable, CaseIterable {
    case paste
    case url
    case file
    case gallery

    public var packageSource: UserScriptPackageSource {
        switch self {
        case .file: return .file
        case .url, .gallery: return .url
        case .paste: return .paste
        }
    }
}

public struct UserScriptResourceDeclaration: Codable, Equatable, Sendable {
    public var name: String
    public var url: String

    public init(name: String, url: String) {
        self.name = name
        self.url = url
    }
}

public struct UserScriptResourceRecord: Codable, Equatable, Sendable {
    public var name: String
    public var url: String
    public var text: String
    public var mimeType: String
    /// Base64 for a binary resource such as an image.
    public var contentBase64: String?

    public init(
        name: String,
        url: String,
        text: String = "",
        mimeType: String = "text/plain",
        contentBase64: String? = nil
    ) {
        self.name = name
        self.url = url
        self.text = text
        self.mimeType = mimeType
        self.contentBase64 = contentBase64
    }
}

/// block, before the script is installed.
public struct UserScriptPackageCandidate: Codable, Equatable, Sendable {
    public var name: String
    public var namespace: String
    public var version: String
    public var description: String
    public var iconUrl: String
    public var source: String
    public var sourceUrl: String
    public var updateUrl: String
    public var downloadUrl: String
    public var matches: [String]
    public var includes: [String]
    public var excludeMatches: [String]
    public var excludes: [String]
    public var grants: [UserScriptGrant]
    public var requireUrls: [String]
    public var resourceDeclarations: [UserScriptResourceDeclaration]
    public var connectRules: [String]
    public var noframes: Bool
    public var runAt: UserScriptRunAt
    public var installSource: UserScriptPackageSource

    public init(
        name: String = "",
        namespace: String = "",
        version: String = "",
        description: String = "",
        iconUrl: String = "",
        source: String = "",
        sourceUrl: String = "",
        updateUrl: String = "",
        downloadUrl: String = "",
        matches: [String] = [],
        includes: [String] = [],
        excludeMatches: [String] = [],
        excludes: [String] = [],
        grants: [UserScriptGrant] = [],
        requireUrls: [String] = [],
        resourceDeclarations: [UserScriptResourceDeclaration] = [],
        connectRules: [String] = [],
        noframes: Bool = false,
        runAt: UserScriptRunAt = .documentIdle,
        installSource: UserScriptPackageSource = .paste
    ) {
        self.name = name
        self.namespace = namespace
        self.version = version
        self.description = description
        self.iconUrl = iconUrl
        self.source = source
        self.sourceUrl = sourceUrl
        self.updateUrl = updateUrl
        self.downloadUrl = downloadUrl
        self.matches = matches
        self.includes = includes
        self.excludeMatches = excludeMatches
        self.excludes = excludes
        self.grants = grants
        self.requireUrls = requireUrls
        self.resourceDeclarations = resourceDeclarations
        self.connectRules = connectRules
        self.noframes = noframes
        self.runAt = runAt
        self.installSource = installSource
    }
}

public struct UserScriptMetadataParseResult: Sendable {
    public var valid: Bool
    public var candidate: UserScriptPackageCandidate?
    public var warnings: [String]
    public var errorMessage: String

    public init(
        valid: Bool,
        candidate: UserScriptPackageCandidate? = nil,
        warnings: [String] = [],
        errorMessage: String = ""
    ) {
        self.valid = valid
        self.candidate = candidate
        self.warnings = warnings
        self.errorMessage = errorMessage
    }

    public static func failure(_ message: String, warnings: [String] = []) -> UserScriptMetadataParseResult {
        UserScriptMetadataParseResult(valid: false, candidate: nil, warnings: warnings, errorMessage: message)
    }
}

/// table.
public struct InstalledUserScriptState: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var name: String
    public var namespace: String
    public var version: String
    public var description: String
    public var iconUrl: String
    public var source: String
    public var sourceUrl: String
    public var updateUrl: String
    public var downloadUrl: String
    public var enabled: Bool
    public var matches: [String]
    public var includes: [String]
    public var excludeMatches: [String]
    public var excludes: [String]
    public var grants: [UserScriptGrant]
    public var requireUrls: [String]
    public var requireSources: [String]
    /// The `@resource` declarations, kept even when a download failed, so a
    /// later refresh can retry them.
    public var resourceDeclarations: [UserScriptResourceDeclaration]
    public var resources: [UserScriptResourceRecord]
    public var connectRules: [String]
    public var noframes: Bool
    public var runAt: UserScriptRunAt
    public var installSource: UserScriptInstallSource
    public var createdAt: Date
    public var updatedAt: Date
    public var lastCheckedAt: Date?

    public init(
        id: String = UUID().uuidString,
        name: String,
        namespace: String = "",
        version: String = "",
        description: String = "",
        iconUrl: String = "",
        source: String,
        sourceUrl: String = "",
        updateUrl: String = "",
        downloadUrl: String = "",
        enabled: Bool = true,
        matches: [String] = [],
        includes: [String] = [],
        excludeMatches: [String] = [],
        excludes: [String] = [],
        grants: [UserScriptGrant] = [],
        requireUrls: [String] = [],
        requireSources: [String] = [],
        resourceDeclarations: [UserScriptResourceDeclaration] = [],
        resources: [UserScriptResourceRecord] = [],
        connectRules: [String] = [],
        noframes: Bool = false,
        runAt: UserScriptRunAt = .documentIdle,
        installSource: UserScriptInstallSource = .paste,
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        lastCheckedAt: Date? = nil
    ) {
        self.id = id
        self.name = name
        self.namespace = namespace
        self.version = version
        self.description = description
        self.iconUrl = iconUrl
        self.source = source
        self.sourceUrl = sourceUrl
        self.updateUrl = updateUrl
        self.downloadUrl = downloadUrl
        self.enabled = enabled
        self.matches = matches
        self.includes = includes
        self.excludeMatches = excludeMatches
        self.excludes = excludes
        self.grants = grants
        self.requireUrls = requireUrls
        self.requireSources = requireSources
        self.resourceDeclarations = resourceDeclarations
        self.resources = resources
        self.connectRules = connectRules
        self.noframes = noframes
        self.runAt = runAt
        self.installSource = installSource
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.lastCheckedAt = lastCheckedAt
    }

    public var displayName: String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "未命名脚本" : trimmed
    }

    /// blocks user-script execution entirely, because a script runs with the
    /// page and would defeat the point of the private session.
    public var grantsUnsupportedByVela: [UserScriptGrant] {
        grants.filter { !$0.isSupportedByVela }
    }

    public var hasUnsupportedGrants: Bool {
        !grantsUnsupportedByVela.isEmpty
    }

    /// Builds an installable script from a parsed candidate.
    public init(candidate: UserScriptPackageCandidate) {
        self.init(
            name: candidate.name,
            namespace: candidate.namespace,
            version: candidate.version,
            description: candidate.description,
            iconUrl: candidate.iconUrl,
            source: candidate.source,
            sourceUrl: candidate.sourceUrl,
            updateUrl: candidate.updateUrl,
            downloadUrl: candidate.downloadUrl,
            matches: candidate.matches,
            includes: candidate.includes,
            excludeMatches: candidate.excludeMatches,
            excludes: candidate.excludes,
            grants: candidate.grants,
            requireUrls: candidate.requireUrls,
            resourceDeclarations: candidate.resourceDeclarations,
            connectRules: candidate.connectRules,
            noframes: candidate.noframes,
            runAt: candidate.runAt,
            installSource: UserScriptInstallSource(rawValue: candidate.installSource.rawValue) ?? .paste
        )
    }
}

public struct UserScriptSettings: Codable, Equatable, Sendable {
    public var scripts: [InstalledUserScriptState]
    public var autoUpdateEnabled: Bool
    public var updatedAt: Date

    public init(
        scripts: [InstalledUserScriptState] = [],
        autoUpdateEnabled: Bool = false,
        updatedAt: Date = Date()
    ) {
        self.scripts = scripts
        self.autoUpdateEnabled = autoUpdateEnabled
        self.updatedAt = updatedAt
    }

    public static let `default` = UserScriptSettings()
}

/// A command a running script registered for the current page.
///
/// `GM_registerMenuCommand` has no browser chrome of its own; the menu panel
/// lists the commands the active page's scripts registered, which is the only
/// place a user can reach them.
public struct UserScriptMenuCommand: Identifiable, Equatable, Sendable {
    public var tabId: String
    public var scriptId: String
    public var scriptName: String
    public var commandId: String
    public var name: String
    public var accessKey: String

    public var id: String { "\(tabId)|\(scriptId)|\(commandId)" }

    public init(
        tabId: String,
        scriptId: String,
        scriptName: String,
        commandId: String,
        name: String,
        accessKey: String = ""
    ) {
        self.tabId = tabId
        self.scriptId = scriptId
        self.scriptName = scriptName
        self.commandId = commandId
        self.name = name
        self.accessKey = accessKey
    }
}

/// What happened when one script's update URL was checked.
public enum UserScriptUpdateResult: Equatable, Sendable {
    case updated(from: String, to: String)
    case upToDate
    case noUpdateUrl
    case failed(String)

    public var displayName: String {
        switch self {
        case let .updated(from, to):
            let old = from.isEmpty ? "无版本号" : "v\(from)"
            let new = to.isEmpty ? "无版本号" : "v\(to)"
            return "已从 \(old) 更新到 \(new)"
        case .upToDate:
            return "已是最新版本"
        case .noUpdateUrl:
            return "没有更新地址"
        case let .failed(message):
            return "检查失败：\(message)"
        }
    }
}

/// The result of an install or edit, including the non-fatal problems that
/// should be shown to the user.
public struct UserScriptInstallOutcome: Sendable {
    public var script: InstalledUserScriptState
    public var warnings: [String]

    public init(script: InstalledUserScriptState, warnings: [String] = []) {
        self.script = script
        self.warnings = warnings
    }
}

public enum UserScriptRuntimeBlockReason: String, Codable, Sendable {
    case none
    case privateMode = "private_mode"
    case disabled
    case noMatch = "no_match"
}

public struct UserScriptRuntimeEligibility: Sendable {
    public var executionAllowed: Bool
    public var blockReason: UserScriptRuntimeBlockReason
    public var matchingScripts: [InstalledUserScriptState]

    public init(
        executionAllowed: Bool,
        blockReason: UserScriptRuntimeBlockReason,
        matchingScripts: [InstalledUserScriptState]
    ) {
        self.executionAllowed = executionAllowed
        self.blockReason = blockReason
        self.matchingScripts = matchingScripts
    }
}

public struct UserScriptInjectionSummary: Sendable {
    public var injectedScriptCount: Int
    public var failedScriptNames: [String]
    public var url: String
    public var skipReason: String

    public init(
        injectedScriptCount: Int = 0,
        failedScriptNames: [String] = [],
        url: String = "",
        skipReason: String = ""
    ) {
        self.injectedScriptCount = injectedScriptCount
        self.failedScriptNames = failedScriptNames
        self.url = url
        self.skipReason = skipReason
    }
}
