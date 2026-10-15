//
//  TabModels.swift
//  Vela
//
//  Swift port of `BrowserTabState`, `TabRecord` and the tab enums from
//  `AiraBrowser/entry/src/main/ets/core/tabs/TabManager.ets` and
//  `common/models/BrowserModels.ets` (Aira Browser 3.7.4, GPL-3.0).
//
//  Aira's tab model carries far more runtime bookkeeping than iOS needs because
//  ArkWeb tabs are hosted Web nodes that must be materialised, backgrounded and
//  torn down explicitly. iOS `WKWebView` instances are ordinary objects, so the
//  runtime-state machine collapses to the states Vela actually acts on. The
//  persisted record and the user-visible fields are kept identical.
//

import Foundation
import Observation

/// Ported from `TabRuntimeState`.
public enum TabRuntimeState: String, Codable, Sendable, CaseIterable {
    /// A live `WKWebView` exists and holds the page.
    case active
    /// A `WKWebView` exists but is not the visible tab.
    case background
    /// Never loaded, or its web view was discarded under memory pressure.
    case cold
    /// The web content process died.
    case crashed
    /// The tab failed to load and is showing an error surface.
    case failed

    /// True when the tab has a live web view worth showing a snapshot for.
    public var isLive: Bool {
        self == .active || self == .background
    }
}

/// Ported from `TabDiscardReason`.
public enum TabDiscardReason: String, Codable, Sendable, CaseIterable {
    case none
    case memoryPressure = "memory_pressure"
    case idleTimeout = "idle_timeout"
    case explicit
}

/// Ported from `TabCrashReason`.
public enum TabCrashReason: String, Codable, Sendable, CaseIterable {
    case none
    case webContentProcess = "web_content_process"
    case terminated
}

/// Ported from `TabRestoreReason`.
public enum TabRestoreReason: String, Codable, Sendable, CaseIterable {
    case none
    case coldStart = "cold_start"
    case sessionRestore = "session_restore"
    case userRequest = "user_request"
}

/// Ported from `BrowserTabOpenSource`.
public enum BrowserTabOpenSource: String, Codable, Sendable, CaseIterable {
    case user
    case bookmark
    case history
    case shortcut
    case externalShare = "external_share"
    case webTargetBlank = "web_target_blank"
    case webWindowOpen = "web_window_open"
    case restore
    case crossDevice = "cross_device"
    case download
}

/// Ported from `BrowserTabState`.
///
/// A class rather than a struct: the tab is the identity that the web-view host,
/// the session store and the SwiftUI list all key off, and reference semantics
/// match the ArkTS original where a tab is a mutated object, not a value.
@MainActor
@Observable
public final class BrowserTabState: Identifiable {
    public let id: String

    public var profileId: BrowserProfileId
    public var title: String
    public var url: String
    /// True while the tab shows the native new-tab surface rather than a document.
    public var isHome: Bool
    public var lastActiveAt: Date
    /// A navigation that has been requested but has not committed yet.
    public var pendingUrl: String
    public var runtimeState: TabRuntimeState
    public var lastError: String
    public var lastRestoreReason: TabRestoreReason
    public var lastDiscardReason: TabDiscardReason
    public var lastCrashReason: TabCrashReason
    public var lastLoadedAt: Date?
    public var scrollOffsetY: Double

    /// Ported from the `lastGood*` pair. A failed navigation keeps the last
    /// successfully rendered page so the error surface can offer "回到上一个正常页面"
    /// instead of dropping the user on a blank tab.
    public var lastGoodUrl: String
    public var lastGoodTitle: String

    public var privacyMode: BrowserSessionPrivacyMode
    public var dataScope: BrowserDataScope
    public var openerTabId: String
    public var openSource: BrowserTabOpenSource

    /// Ported from `pinned`. Persisted, and pins the tab to the leading edge of
    /// the tab strip.
    public var pinned: Bool
    /// Runtime-only web audio facts, driving the tab audio indicator.
    public var muted: Bool
    public var audible: Bool

    /// Loading progress in 0...1, surfaced by `BrowserLoadingProgressCoordinator`.
    public var estimatedProgress: Double
    public var isLoading: Bool
    public var canGoBack: Bool
    public var canGoForward: Bool
    /// Whether the page has a favicon the tab strip can show.
    public var faviconUrl: String

    public init(
        id: String = UUID().uuidString,
        profileId: BrowserProfileId = browserMainProfileId,
        title: String = "",
        url: String = "",
        isHome: Bool = true,
        lastActiveAt: Date = Date(),
        pendingUrl: String = "",
        runtimeState: TabRuntimeState = .cold,
        lastError: String = "",
        lastRestoreReason: TabRestoreReason = .none,
        lastDiscardReason: TabDiscardReason = .none,
        lastCrashReason: TabCrashReason = .none,
        lastLoadedAt: Date? = nil,
        scrollOffsetY: Double = 0,
        lastGoodUrl: String = "",
        lastGoodTitle: String = "",
        privacyMode: BrowserSessionPrivacyMode = .regular,
        dataScope: BrowserDataScope = .profilePersistent,
        openerTabId: String = "",
        openSource: BrowserTabOpenSource = .user,
        pinned: Bool = false,
        muted: Bool = false,
        audible: Bool = false,
        estimatedProgress: Double = 0,
        isLoading: Bool = false,
        canGoBack: Bool = false,
        canGoForward: Bool = false,
        faviconUrl: String = ""
    ) {
        self.id = id
        self.profileId = profileId
        self.title = title
        self.url = url
        self.isHome = isHome
        self.lastActiveAt = lastActiveAt
        self.pendingUrl = pendingUrl
        self.runtimeState = runtimeState
        self.lastError = lastError
        self.lastRestoreReason = lastRestoreReason
        self.lastDiscardReason = lastDiscardReason
        self.lastCrashReason = lastCrashReason
        self.lastLoadedAt = lastLoadedAt
        self.scrollOffsetY = scrollOffsetY
        self.lastGoodUrl = lastGoodUrl
        self.lastGoodTitle = lastGoodTitle
        self.privacyMode = privacyMode
        self.dataScope = dataScope
        self.openerTabId = openerTabId
        self.openSource = openSource
        self.pinned = pinned
        self.muted = muted
        self.audible = audible
        self.estimatedProgress = estimatedProgress
        self.isLoading = isLoading
        self.canGoBack = canGoBack
        self.canGoForward = canGoForward
        self.faviconUrl = faviconUrl
    }

    /// Ported from `isBrowserTabTerminalBackAvailable`.
    public var isTerminalBackAvailable: Bool { !isHome }

    /// The data boundary this tab writes under.
    public var dataBoundary: BrowserDataBoundary {
        BrowserDataBoundary(profileId: profileId, dataScope: dataScope, privacyMode: privacyMode)
    }

    /// The label the tab strip and tab overview show.
    public var displayTitle: String {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { return trimmed }
        if isHome { return "新标签页" }
        if !url.isEmpty, let host = URL(string: url)?.host { return host }
        return "新标签页"
    }

    /// Ported from `BrowserDisplayTitlePolicy`.
    public var displayHost: String {
        guard !url.isEmpty, let parsed = URL(string: url), let host = parsed.host else { return "" }
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }

    /// A snapshot for the tab overview, taken without touching the live web view.
    public var record: TabRecord {
        TabRecord(
            id: id,
            profileId: profileId,
            title: title,
            url: url,
            isHome: isHome,
            lastActiveAt: lastActiveAt,
            pinned: pinned,
            privacyMode: privacyMode,
            dataScope: dataScope,
            openSource: openSource,
            lastGoodUrl: lastGoodUrl,
            lastGoodTitle: lastGoodTitle,
            scrollOffsetY: scrollOffsetY
        )
    }

    /// Re-applies a restored record. Ported from `BrowserTabSessionRestoreService`.
    public func apply(_ record: TabRecord, restoreReason: TabRestoreReason) {
        title = record.title
        url = record.url
        isHome = record.isHome
        pinned = record.pinned
        privacyMode = record.privacyMode
        dataScope = record.dataScope
        openSource = record.openSource
        lastGoodUrl = record.lastGoodUrl
        lastGoodTitle = record.lastGoodTitle
        scrollOffsetY = record.scrollOffsetY
        lastRestoreReason = restoreReason
        runtimeState = record.isHome ? .active : .cold
        lastError = ""
        pendingUrl = ""
    }
}

/// Ported from `TabRecord` — the persisted form of a tab.
///
/// Deliberately excludes runtime fields (progress, back/forward availability,
/// audio state): those are re-derived from the web view on restore, and
/// persisting them is what makes a restored session show stale chrome.
public struct TabRecord: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var profileId: BrowserProfileId
    public var title: String
    public var url: String
    public var isHome: Bool
    public var lastActiveAt: Date
    public var pinned: Bool
    public var privacyMode: BrowserSessionPrivacyMode
    public var dataScope: BrowserDataScope
    public var openSource: BrowserTabOpenSource
    public var lastGoodUrl: String
    public var lastGoodTitle: String
    public var scrollOffsetY: Double
}

/// Ported from the `BrowserTabMutationResult` bundle.
public struct BrowserTabMutationResult: Sendable {
    public var tabs: [TabRecord]
    public var activeTabId: String
    public var tabSequence: Int
}

/// The persisted browsing session. Ported from the shape written by
/// `BrowserTabSessionPersistenceCoordinator`.
///
/// Private tabs are persisted too, but only with their URL and title — the
/// session file lives in the app container and the point of private mode is to
/// leave no browsing data behind after the session ends, which
/// `BrowserPrivateSessionCleanupCoordinator` enforces on quit.
public struct BrowserSessionSnapshot: Codable, Equatable, Sendable {
    public var tabs: [TabRecord]
    public var activeTabId: String
    public var tabSequence: Int
    public var savedAt: Date

    public init(tabs: [TabRecord], activeTabId: String, tabSequence: Int, savedAt: Date = Date()) {
        self.tabs = tabs
        self.activeTabId = activeTabId
        self.tabSequence = tabSequence
        self.savedAt = savedAt
    }
}

/// Ported from `BrowserRecentlyClosedTabsService`.
public struct RecentlyClosedTabRecord: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var title: String
    public var url: String
    public var closedAt: Date
    public var privacyMode: BrowserSessionPrivacyMode

    public init(
        id: String = UUID().uuidString,
        title: String,
        url: String,
        closedAt: Date = Date(),
        privacyMode: BrowserSessionPrivacyMode = .regular
    ) {
        self.id = id
        self.title = title
        self.url = url
        self.closedAt = closedAt
        self.privacyMode = privacyMode
    }
}
