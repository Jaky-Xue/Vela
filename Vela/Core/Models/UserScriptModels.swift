//
//  UserScriptModels.swift
//  Vela
//
//  Swift port of `AiraBrowser/entry/src/main/ets/features/userscripts/UserScriptMetadataModels.ets`
//  (Aira Browser 3.7.4, GPL-3.0).
//
//  The `@grant` catalogue, the `@run-at` values, the metadata-block fields and
//  the parse-result shape are copied from the ArkTS originals. Vela executes
//  scripts with `WKUserScript`, which fixes the injection points to document
//  start and document end; grants that Aira implements through its native bridge
//  (`GM_xmlhttpRequest`, `GM_download`, `GM_cookie`) are declared here so a
//  script that requests them is still installable, and the ones Vela cannot
//  honour are reported on the script detail screen rather than silently dropped.
//

import Foundation

/// Ported from `UserScriptRunAt`.
public enum UserScriptRunAt: String, Codable, Sendable, CaseIterable {
    case documentStart = "document-start"
    case documentIdle = "document-idle"
    case documentEnd = "document-end"
    /// Menu-only values: the script registers commands rather than running on load.
    case mainMenu = "main-menu"
    case toolMenu = "tool-menu"
    case contextMenu = "context-menu"

    public var displayName: String {
        switch self {
        case .documentStart: return "文档开始前"
        case .documentIdle: return "文档空闲时"
        case .documentEnd: return "文档加载完成后"
        case .mainMenu: return "仅主菜单"
        case .toolMenu: return "仅工具菜单"
        case .contextMenu: return "仅右键菜单"
        }
    }

    /// True when the script body should be injected into the page at all.
    /// Menu-only values are not injected on load, matching Aira's behaviour.
    public var injectsOnLoad: Bool {
        switch self {
        case .documentStart, .documentIdle, .documentEnd: return true
        case .mainMenu, .toolMenu, .contextMenu: return false
        }
    }
}

/// Ported from `UserScriptGrant`.
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
    /// The value store, styling, logging, clipboard and `unsafeWindow` are all
    /// reachable from an injected script. Cross-origin XHR, cookie access and
    /// the download/open-tab commands are not: WebKit gives an injected script
    /// no privileged network or cookie API, and `GM_openInTab` would have to be
    /// routed through the app rather than the page.
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
             .windowOnUrlChange, .unsafeWindow, .unknown:
            return true
        case .gmXmlhttpRequest, .gmFetch, .gmDownload, .gmOpenInTab,
             .gmGetTab, .gmSaveTab, .gmGetTabs,
             .gmCookie, .gmCookieSet, .gmCookieDelete,
             .gmExGetSearchEngines, .gmExGetAppSearchEngineUrl,
             .gmExTTS, .gmExShareTextToApp, .gmExSniffMedia,
             .windowClose, .windowFocus:
            return false
        }
    }
}

/// Ported from `UserScriptPackageSource`.
public enum UserScriptPackageSource: String, Codable, Sendable, CaseIterable {
    case paste
    case url
    case file
}

/// Ported from `UserScriptInstallSource`.
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

/// Ported from `UserScriptResourceDeclaration` / `UserScriptResourceRecord`.
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

/// Ported from `UserScriptPackageCandidate` — the result of parsing a metadata
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

/// Ported from `UserScriptMetadataParseResult`.
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

/// Ported from `InstalledUserScriptState`, flattened onto the `user_scripts`
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

    /// Ported from the guard in `UserScriptRuntimeCoordinator`: private browsing
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
            connectRules: candidate.connectRules,
            noframes: candidate.noframes,
            runAt: candidate.runAt,
            installSource: UserScriptInstallSource(rawValue: candidate.installSource.rawValue) ?? .paste
        )
    }
}

/// Ported from `UserScriptSettings`.
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

/// Ported from `UserScriptRuntimeEligibility`.
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

/// Ported from `UserScriptInjectionSummary`.
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
