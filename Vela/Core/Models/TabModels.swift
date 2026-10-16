//
//  TabModels.swift
//  Vela
//
//  A tab's observable state, its persisted record, and the enums describing how
//  it got there.
//
//  `BrowserTabState` is a reference type because it is the identity the web-view
//  host, the session store and the tab list all key off, and because the web
//  engine mutates it as a page loads.
//
//  Two state questions are asked about a tab and they are genuinely separate, so
//  they are two fields rather than one overloaded enum:
//
//    * `runtimeState` — does the tab have a live `WKWebView`, and is it the one
//      on screen? A `WKWebView` is an ordinary object and WebKit manages content
//      processes itself, so `cold` means exactly "no web view".
//    * `loadState` — where is the navigation that web view is running?
//
//  Collapsing them would lose one of the answers: a background tab that has
//  finished loading is `background` *and* `finished`, and a single enum cannot
//  say both. Failures and crashes belong to `loadState`, because they are
//  outcomes of a navigation rather than properties of the view.
//
//  The persisted record holds only what cannot be re-derived from the web view.
//  Writing progress and back/forward availability to disk is what makes a
//  restored session come back showing stale chrome.
//

import Foundation
import Observation

public enum TabRuntimeState: String, Codable, Sendable, CaseIterable {
    /// A live `WKWebView` exists and holds the page.
    case active
    /// A `WKWebView` exists but is not the visible tab.
    case background
    /// Never loaded, or its web view was discarded under memory pressure.
    case cold

    /// True when the tab has a live web view worth showing a snapshot for.
    public var isLive: Bool {
        self == .active || self == .background
    }
}

/// Where a tab's navigation has got to.
///
/// The phases are the ones WebKit actually reports, plus the two the app
/// generates itself: `requested` is the window between handing WebKit a
/// `URLRequest` and its first callback, and `cancelled` is a navigation the app
/// deliberately stopped — which is not a failure and must not be dressed up as
/// one.
public enum TabLoadState: String, Codable, Sendable, CaseIterable {
    /// Nothing has been asked for. Also the state a discarded tab returns to.
    case idle
    /// A request has been handed to WebKit; no callback has arrived yet.
    case requested
    /// `didStartProvisionalNavigation` — the connection is being established.
    case provisional
    /// `didCommit` — the main document has started arriving.
    case committed
    /// `didFinish` — the main document is complete.
    case finished
    /// The navigation was stopped, by the user or by the app.
    case cancelled
    /// The navigation failed. The tab shows the error surface.
    case failed
    /// The web content process died.
    case crashed

    /// True while a navigation is in flight. A failure may only downgrade one of
    /// these states; it can never blank a state that is already settled, which is
    /// what stops a superseded navigation from clearing the state of the one that
    /// replaced it.
    public var isInFlight: Bool {
        self == .requested || self == .provisional || self == .committed
    }

    /// True when the tab has an error to show the user.
    public var isFailure: Bool {
        self == .failed || self == .crashed
    }

    /// True once a document has been committed, which is what makes
    /// "back to the page that worked" a meaningful offer.
    public var hasCommittedDocument: Bool {
        self == .committed || self == .finished
    }
}

/// Why a navigation failed, in the shape the error surface needs.
///
/// Built once, at the point the failure is observed, rather than re-derived by
/// the view: the view then renders a value and does not have to know about
/// `NSError` domains, and the same value is what goes into the diagnostics log.
public struct TabNavigationFailure: Equatable, Sendable {
    public enum Kind: String, Codable, Sendable, CaseIterable {
        /// The failure is not a navigation failure at all — see
        /// `TabLoadState.cancelled`.
        case cancelled
        case offline
        case dns
        case timeout
        case refused
        case connectionLost
        case tls
        case httpStatus
        /// The navigation completed but delivered no document.
        ///
        /// WebKit does this without reporting an error at all: a connection it
        /// cannot make is sometimes answered with its own empty `about:blank`
        /// document, which then commits and finishes. Taking that at face value
        /// reports a page that was never received as a success, and leaves the
        /// user with a blank rectangle — the exact symptom that is
        /// indistinguishable from the browser being broken.
        case emptyResponse
        /// The platform refused a cleartext request before it was sent.
        case insecureConnection
        case crashed
        case invalidUrl
        case other
    }

    public var kind: Kind
    /// The headline the error surface shows.
    public var title: String
    /// One more sentence: what the user can do, or what specifically went wrong.
    public var detail: String
    /// The URL the navigation was for. Kept verbatim so "copy address" works.
    public var url: String
    /// The `NSError` that produced this, kept for the diagnostics log.
    public var errorDomain: String
    public var errorCode: Int

    /// True for outcomes that are a re-run of the same request rather than a
    /// dead end, which is what decides the error surface's primary button.
    public var isRetryable: Bool {
        switch kind {
        case .cancelled, .crashed, .invalidUrl:
            return false
        default:
            return true
        }
    }
}

extension TabNavigationFailure {
    /// WebKit's code for "the app declined this navigation".
    ///
    /// It arrives as `WebKitErrorFrameLoadInterruptedByPolicyChange` when the
    /// delegate answers `decisionHandler(.cancel)` — which Vela does for every
    /// `target="_blank"` link, every `window.open` and every external scheme. It
    /// is not in `NSURLErrorDomain`, so a check for `NSURLErrorCancelled` alone
    /// misses it, and missing it is what makes opening a link in a new tab look
    /// like the current page failing to load.
    public static let policyCancellationCode = 102
    public static let webKitErrorDomain = "WebKitErrorDomain"
    /// `WKError.webContentProcessTerminated`. Spelled out rather than referenced
    /// so this file stays free of a WebKit import; the number is part of
    /// WebKit's published error surface and has not moved.
    public static let webContentProcessTerminatedCode = 4

    /// True when an error means "this navigation was stopped on purpose".
    public static func isCancellation(_ error: NSError) -> Bool {
        if error.domain == NSURLErrorDomain, error.code == NSURLErrorCancelled {
            return true
        }
        return error.domain == webKitErrorDomain && error.code == policyCancellationCode
    }

    /// Classifies a WebKit error for the error surface.
    ///
    /// Returns nil for a cancellation: a cancelled navigation has no failure to
    /// describe, and giving it one is what puts an error page over a page the
    /// user is reading.
    public static func make(from error: NSError, url: String) -> TabNavigationFailure? {
        guard !isCancellation(error) else { return nil }

        let kind: Kind
        switch (error.domain, error.code) {
        case (NSURLErrorDomain, NSURLErrorNotConnectedToInternet):
            kind = .offline
        case (NSURLErrorDomain, NSURLErrorCannotFindHost),
             (NSURLErrorDomain, NSURLErrorDNSLookupFailed):
            kind = .dns
        case (NSURLErrorDomain, NSURLErrorTimedOut):
            kind = .timeout
        case (NSURLErrorDomain, NSURLErrorCannotConnectToHost):
            kind = .refused
        case (NSURLErrorDomain, NSURLErrorAppTransportSecurityRequiresSecureConnection):
            // The platform, not the site, refused this. It happens when the web
            // content exemption is not in force, and the system's own message for
            // it is an untranslated sentence about a policy the user has never
            // heard of.
            kind = .insecureConnection
        case (NSURLErrorDomain, NSURLErrorNetworkConnectionLost):
            kind = .connectionLost
        case (NSURLErrorDomain, NSURLErrorSecureConnectionFailed),
             (NSURLErrorDomain, NSURLErrorServerCertificateUntrusted),
             (NSURLErrorDomain, NSURLErrorServerCertificateHasBadDate),
             (NSURLErrorDomain, NSURLErrorServerCertificateNotYetValid),
             (NSURLErrorDomain, NSURLErrorServerCertificateHasUnknownRoot),
             (NSURLErrorDomain, NSURLErrorClientCertificateRejected),
             (NSURLErrorDomain, NSURLErrorClientCertificateRequired):
            kind = .tls
        case (NSURLErrorDomain, NSURLErrorUnsupportedURL),
             (NSURLErrorDomain, NSURLErrorBadURL):
            kind = .invalidUrl
        default:
            kind = .other
        }

        return TabNavigationFailure(
            kind: kind,
            title: Self.title(for: kind),
            detail: Self.detail(for: kind, error: error),
            url: url,
            errorDomain: error.domain,
            errorCode: error.code
        )
    }

    /// The failure a dead web content process produces.
    ///
    /// Separate from `make(from:url:)` because WebKit reports a crash through
    /// `webViewWebContentProcessDidTerminate` and hands over no error at all —
    /// and because a crash is a different thing to tell the user about than a
    /// request that did not arrive.
    public static func crashed(url: String) -> TabNavigationFailure {
        TabNavigationFailure(
            kind: .crashed,
            title: "页面已停止响应",
            detail: "网页渲染进程意外退出。重新载入通常可以恢复。",
            url: url,
            errorDomain: webKitErrorDomain,
            errorCode: webContentProcessTerminatedCode
        )
    }

    /// The failure a completed navigation that delivered nothing produces.
    ///
    /// Raised by the coordinator when WebKit commits its own empty document over
    /// a tab that asked for a real page.
    public static func emptyDocument(url: String) -> TabNavigationFailure {
        TabNavigationFailure(
            kind: .emptyResponse,
            title: title(for: .emptyResponse),
            detail: detail(for: .emptyResponse, error: NSError(domain: "", code: 0)),
            url: url,
            errorDomain: "",
            errorCode: 0
        )
    }

    private static func title(for kind: Kind) -> String {
        switch kind {
        case .cancelled: return "已取消加载"
        case .offline: return "没有网络连接"
        case .dns: return "找不到该网站"
        case .timeout: return "连接超时"
        case .refused: return "无法连接到服务器"
        case .connectionLost: return "网络连接已断开"
        case .tls: return "安全连接失败"
        case .httpStatus: return "服务器返回错误"
        case .emptyResponse: return "服务器没有返回内容"
        case .insecureConnection: return "系统阻止了不安全的连接"
        case .crashed: return "页面已停止响应"
        case .invalidUrl: return "网址无法打开"
        case .other: return "无法载入页面"
        }
    }

    /// The second line. Prefers something the user can act on over WebKit's own
    /// wording, which names an internal error and no remedy.
    private static func detail(for kind: Kind, error: NSError) -> String {
        switch kind {
        case .offline:
            return "请检查 Wi-Fi 或蜂窝网络，然后重试。"
        case .dns:
            return "请检查网址是否拼写正确，或稍后再试。"
        case .timeout:
            return "服务器没有在限定时间内响应。"
        case .refused:
            return "服务器拒绝了连接，可能暂时不可用。"
        case .connectionLost:
            return "网络连接中断，请确认网络稳定后重试。"
        case .tls:
            return "该网站的证书存在问题，Vela 不会跳过证书校验。"
        case .emptyResponse:
            return "连接没有建立，或者服务器在应答前就关闭了连接。"
        case .insecureConnection:
            return "该站点只提供不加密的 HTTP 连接，而当前系统策略不允许。请尝试 HTTPS 地址。"
        case .invalidUrl:
            return "这个地址不是一个可以打开的网页地址。"
        case .other:
            let description = error.localizedDescription
            return description.isEmpty ? "发生未知错误。" : description
        case .cancelled, .httpStatus, .crashed:
            return ""
        }
    }
}

public enum TabDiscardReason: String, Codable, Sendable, CaseIterable {
    case none
    case memoryPressure = "memory_pressure"
    case idleTimeout = "idle_timeout"
    case explicit
}

public enum TabCrashReason: String, Codable, Sendable, CaseIterable {
    case none
    case webContentProcess = "web_content_process"
    case terminated
}

public enum TabRestoreReason: String, Codable, Sendable, CaseIterable {
    case none
    case coldStart = "cold_start"
    case sessionRestore = "session_restore"
    case userRequest = "user_request"
}

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

/// One open tab.
///
/// A class rather than a struct: the tab is the identity the web-view host, the
/// session store and the SwiftUI list all key off, and the web engine mutates it
/// in place as a page loads.
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
    /// Where the current navigation has got to. The error surface keys off this.
    public var loadState: TabLoadState
    /// The identifier of the most recent navigation, assigned by the web
    /// coordinator as each one starts.
    ///
    /// WebKit does not hand out a correlation id, and a URL is not one — two
    /// navigations to the same URL are still two navigations, and a redirect
    /// makes the URL the navigation started with differ from the one it ends on.
    /// This is the id the diagnostics log records, so a page's failure can be
    /// traced back to the navigation that produced it. Staleness is decided
    /// separately, from the `WKNavigation` object identity.
    public var navigationSerial: Int
    /// Why the last navigation failed, when one did.
    ///
    /// A value rather than a string: the error surface needs the kind to choose
    /// its copy and its buttons, and the diagnostics log needs the raw
    /// `NSError` domain and code.
    public var lastFailure: TabNavigationFailure?
    /// The HTTP status of the main document, once the response has been seen.
    ///
    /// Non-2xx is recorded rather than treated as a failure. WebKit commits and
    /// renders a server's own 404 page, which is a *successful* navigation to a
    /// page that says "not found" — conflating the two is what makes a browser
    /// show a network-error page over a working page.
    public var serverStatus: Int
    /// The URL of the document this tab has actually committed and is showing.
    ///
    /// Written in exactly one place — `didCommit` — because that is the only
    /// event that means a document arrived. It exists because neither of the two
    /// obvious answers to "is a page on screen" is usable:
    ///
    /// * `WKWebView.url` reports the navigation *in flight*, not the document
    ///   being displayed. Measured: after a navigation to `/slow` was stopped
    ///   while `/one` was still on screen, `webView.url` read `/slow`.
    /// * `url` above is written optimistically by `TabManager.load`, so it names
    ///   the page that was *asked for* from the moment the request is issued.
    ///
    /// Without it, a tab whose secondary navigation was cancelled looked like a
    /// tab with nothing on screen, and activating it re-fetched the page — which
    /// is how a cancelled click-tracking beacon cost a user their place in a
    /// search results page.
    public var committedUrl: String

    public var lastRestoreReason: TabRestoreReason
    public var lastDiscardReason: TabDiscardReason
    public var lastCrashReason: TabCrashReason
    public var lastLoadedAt: Date?
    public var scrollOffsetY: Double

    /// A failed navigation keeps the last
    /// successfully rendered page so the error surface can offer "回到上一个正常页面"
    /// instead of dropping the user on a blank tab.
    public var lastGoodUrl: String
    public var lastGoodTitle: String

    public var privacyMode: BrowserSessionPrivacyMode
    public var dataScope: BrowserDataScope
    public var openerTabId: String
    public var openSource: BrowserTabOpenSource

    /// Persisted, and pins the tab to the leading edge of
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
        loadState: TabLoadState = .idle,
        navigationSerial: Int = 0,
        lastFailure: TabNavigationFailure? = nil,
        serverStatus: Int = 0,
        committedUrl: String = "",
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
        self.loadState = loadState
        self.navigationSerial = navigationSerial
        self.lastFailure = lastFailure
        self.serverStatus = serverStatus
        self.committedUrl = committedUrl
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

    /// Re-applies a restored record.
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
        loadState = .idle
        lastFailure = nil
        serverStatus = 0
        committedUrl = ""
        pendingUrl = ""
    }

    /// True when this tab's page is not settled and may need fetching again.
    ///
    /// This is the half of "does this tab need its page fetched" that is a
    /// property of the tab: it has a URL, nothing is in flight, and no failure is
    /// waiting for the user to acknowledge one. The other half — is a document
    /// already on screen — belongs to the web view and is not knowable from here,
    /// so `TabManager` pairs the two. See `TabManager.shouldFetchPage`.
    ///
    /// A cancelled tab answers yes, deliberately: a stopped load leaves no
    /// document, and refusing to fetch would mean a tab that shows a blank
    /// rectangle for the rest of the session. It is the web view's URL check that
    /// keeps a page which *is* displayed — one whose secondary navigation was
    /// cancelled — from being fetched over.
    public var needsPageFetch: Bool {
        guard !isHome, !url.isEmpty else { return false }
        guard !loadState.isInFlight, !loadState.isFailure else { return false }
        return !loadState.hasCommittedDocument
    }
}

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

public struct BrowserTabMutationResult: Sendable {
    public var tabs: [TabRecord]
    public var activeTabId: String
    public var tabSequence: Int
}

/// The persisted browsing session.
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
