//
//  BrowserWebCoordinator.swift
//  Vela
//
//  Owns every `WKWebView` interaction: configuration, navigation policy,
//  window-open handling, permissions, downloads and script messages.
//
//  All of it is one object because WebKit asks for it that way. A web view's
//  delegates come as a small set of protocols — `WKNavigationDelegate`,
//  `WKUIDelegate`, `WKScriptMessageHandler` — and all of them need the same tab
//  registry and the same services, so splitting them would only mean passing
//  that state around.
//
//  The values the delegates produce go somewhere else. Anything the shell renders
//  and the user answers lives on `WebPageOverlays`, so a view showing a dialog
//  observes the dialog rather than the engine.
//
//  Concurrency note: the delegate methods are `nonisolated` and hop to the main
//  actor before touching state. WebKit calls them on the main thread anyway, but
//  saying so explicitly keeps the class correct under strict concurrency rather
//  than relying on an unstated guarantee.
//

import Foundation
import UIKit
import WebKit
import Observation

@MainActor
@Observable
public final class BrowserWebCoordinator: NSObject {
    // MARK: - Collaborators

    let settings: SettingsService
    let adBlock: AdBlockEngine
    let history: HistoryService
    let downloads: DownloadService
    let userScripts: UserScriptRepository
    weak var tabManager: TabManager?

    /// The structured record of what happened to each navigation. In memory
    /// only; see `NavigationLog`.
    public let navigationLog: NavigationLog

    /// The values the shell renders over a page. Owned by the environment and
    /// handed in, so a view can observe one dialog without observing the engine.
    public let overlays: WebPageOverlays

    /// Receives new text blocks from a translated page's mutation observer.
    ///
    /// The coordinator sees the script message; the translation service owns
    /// the provider and the target, so the two are connected by this closure
    /// rather than by the engine reaching into the service.
    public var dynamicTranslationHandler: ((String, String, WKWebView) -> Void)?

    /// Opens a tab a user script asked for with `GM_openInTab`. Set by the
    /// environment, because the tab manager lives there.
    public var userScriptOpenTabHandler: ((URL, Bool, BrowserSessionPrivacyMode) -> Void)?

    /// In-flight `GM_xmlhttpRequest` tasks, keyed by script and request id.
    var userScriptXHRTasks: [String: Task<Void, Never>] = [:]
    /// The per-tab object store behind `GM_getTab` / `GM_saveTab` / `GM_getTabs`.
    var userScriptTabStates: [String: String] = [:]

    /// What is known about the navigation each live web view is running.
    ///
    /// Keyed by web-view identity rather than by tab, because that is what WebKit
    /// identifies a callback by — the tab is only reachable through it. The
    /// `WKNavigation` object is the correlation the app needs and WebKit does
    /// hand out: it is passed to `didCommit`, `didFinish` and both failure
    /// callbacks, and it is the same object for all of them. Comparing it by
    /// identity is how a callback from a navigation that has been superseded is
    /// recognised as stale — which a URL comparison cannot do, because two
    /// navigations to the same URL are indistinguishable by URL and a redirect
    /// changes the URL mid-navigation.
    struct NavigationTrace {
        /// Held weakly and checked by identity on every lookup. The dictionary is
        /// keyed by `ObjectIdentifier`, and an identifier is only unique among
        /// live objects.
        weak var webView: WKWebView?
        var navigation: WKNavigation?
        /// The id assigned when this navigation started, recorded on the tab and
        /// in every log entry for it.
        var serial: Int
        var startedAt: Date
        /// The URL the navigation was for when it started.
        var url: String
    }

    var traces: [ObjectIdentifier: NavigationTrace] = [:]
    var nextNavigationSerial = 1

    /// The non-persistent data store every private tab in this window shares.
    ///
    /// Created on the first private web view and reused for the rest of the
    /// window's private session. `WKWebsiteDataStore.nonPersistent()` returns a
    /// new store on every call, so building one per configuration gave every
    /// private tab its own cookie jar: a link opened from a private tab arrived
    /// logged out, and the end-of-session cleanup had no store to clear. One
    /// store per window makes the window's private tabs one session; the window
    /// is also the unit whose tabs, `windowId` and end-of-session cleanup are
    /// already scoped together.
    private var sharedPrivateDataStore: WKWebsiteDataStore?

    /// The URLs this coordinator is re-issuing to strip their app-link
    /// permission.
    ///
    /// A navigation the web view starts itself carries no app-link permission;
    /// the set is how the re-issued load is recognised on its way back through
    /// the policy callback and allowed as the plain web navigation it is,
    /// rather than being rewritten again — which would loop forever.
    var pendingAppLinkReloads: Set<String> = []
    /// A navigation cancelled to re-issue it under the identifier its host
    /// needs (the video-site rule). One entry per navigation, so the
    /// re-issued load is allowed through.
    var pendingIdentityReloads: Set<String> = []

    public init(
        overlays: WebPageOverlays,
        settings: SettingsService,
        adBlock: AdBlockEngine,
        history: HistoryService,
        downloads: DownloadService,
        userScripts: UserScriptRepository,
        navigationLog: NavigationLog
    ) {
        self.overlays = overlays
        self.settings = settings
        self.adBlock = adBlock
        self.history = history
        self.downloads = downloads
        self.userScripts = userScripts
        self.navigationLog = navigationLog
        super.init()
    }

    public func attach(tabManager: TabManager) {
        self.tabManager = tabManager
    }

    /// Releases the per-tab work a user script left behind.
    ///
    /// Called from `TabManager.onWillCloseTab`. XHR tasks are keyed by tab so
    /// a closed tab's requests stop instead of holding its web view until a
    /// timeout; the GM tab state and menu commands belong to the document and
    /// are meaningless without it.
    func cleanupClosedTab(_ tab: BrowserTabState) {
        let prefix = "\(tab.id)|"
        for key in Array(userScriptXHRTasks.keys) where key.hasPrefix(prefix) {
            userScriptXHRTasks.removeValue(forKey: key)?.cancel()
        }
        userScriptTabStates.removeValue(forKey: tab.id)
        history.clearTabChain(tabId: tab.id)
        overlays.userScriptMenuCommands.removeAll { $0.tabId == tab.id }
        if overlays.mediaFullscreen?.tabId == tab.id {
            overlays.mediaFullscreen = nil
        }
        if let webView = tabManager?.webView(for: tab.id) {
            traces.removeValue(forKey: ObjectIdentifier(webView))
        }
    }

    // MARK: - Element picker

    /// Arms the picker on the page already on screen.
    ///
    /// Evaluating the script here instead of reloading the page keeps the
    /// user's scroll position and the document they were reading; the reload
    /// was only ever a way to get the script injected, and a direct evaluation
    /// does the same job. The script is also added to the next navigation's
    /// configuration while the picker stays armed.
    public func armElementPicker(in webView: WKWebView?) {
        overlays.isElementPickerArmed = true
        webView?.evaluateJavaScript(WebPageScripts.elementPickerScript)
    }

    public func disarmElementPicker(in webView: WKWebView?) {
        overlays.isElementPickerArmed = false
        webView?.evaluateJavaScript(WebPageScripts.stopElementPickerScript)
    }

    // MARK: - Script message dispatch

    /// Routes a page message. One `switch` over the handler name, which is why
    /// the handlers are registered separately rather than multiplexed.
    fileprivate func handle(message: WKScriptMessage, from webView: WKWebView) {
        guard let tab = tabManager?.tabs.first(where: { tabManager?.webView(for: $0.id) === webView }) else {
            return
        }

        switch WebPageScripts.Handler(rawValue: message.name) {
        case .historyApi:
            handleHistoryApiMessage(message, tab: tab)
        case .scroll:
            handleScrollMessage(message, tab: tab, webView: webView)
        case .pageMetrics:
            handlePageMetricsMessage(message)
        case .elementPick:
            handleElementPickMessage(message, tab: tab)
        case .adBlockReport:
            handleAdBlockReport(message, webView: webView)
        case .translation:
            handleTranslationMessage(message, from: webView)
        case .userScript:
            handleUserScriptMessage(message, tab: tab, webView: webView)
        case .console:
            handleConsoleMessage(message, tab: tab)
        case .mediaFullscreen:
            handleMediaFullscreenMessage(message, tab: tab, webView: webView)
        case .none:
            break
        }
    }

    /// A single-page app changed its URL without navigating, so the tab's URL and
    /// the history both have to be updated, and the change recorded as a visit.
    func handleHistoryApiMessage(_ message: WKScriptMessage, tab: BrowserTabState) {
        guard let payload = message.body as? [String: Any],
              let kind = payload["kind"] as? String,
              let newUrl = payload["newUrl"] as? String,
              let url = URL(string: newUrl) else { return }

        // `init` fires before the document is committed and carries no real
        // change; treating it as a navigation would double-count the first page.
        guard kind != "init" else { return }

        tab.url = newUrl
        // A single-page app changed the address of the document it is showing,
        // so the displayed document's URL changed with it.
        tab.committedUrl = newUrl
        tab.isHome = false
        if !tab.lastGoodUrl.isEmpty {
            tab.lastGoodUrl = newUrl
        }

        let transition: HistoryTransition = kind == "pushState" ? .link : .reload
        history.recordVisit(
            url: url,
            title: tab.title,
            tabId: tab.id,
            boundary: tab.dataBoundary,
            transition: transition
        )

        // A history-API navigation changes the back/forward list without ever
        // producing a `didFinish`, so the toolbar would keep showing whatever
        // the last full load left there — which for a single-page app is "back
        // disabled" on a page that can in fact go back.
        syncNavigationAvailability(tab: tab, webView: webView(for: tab.id))
    }

    /// Copies WebKit's back/forward availability onto the tab.
    ///
    /// The single place that answers "can this tab go back", called from every
    /// event that can change the answer. WebKit owns the list; the tab only ever
    /// mirrors it, because the toolbar has to be able to read it as plain state.
    func syncNavigationAvailability(tab: BrowserTabState, webView: WKWebView?) {
        guard let webView else {
            // No live web view means no history: a discarded tab's back/forward
            // list went with it, so leaving the old flags set would offer a
            // button that does nothing.
            tab.canGoBack = false
            tab.canGoForward = false
            return
        }
        tab.canGoBack = webView.canGoBack
        tab.canGoForward = webView.canGoForward
    }

    // MARK: - Fullscreen player

    /// The page's own fullscreen player reporting in.
    ///
    /// `enter` opens the host's layer, `state` keeps its controls honest, and
    /// `exit` closes it. The page remains the owner of the media element
    /// throughout; nothing here reaches into the video, and the commands in
    /// `sendMediaPlayerCommand` go back as calls to `window.__velaPlayer`.
    func handleMediaFullscreenMessage(_ message: WKScriptMessage, tab: BrowserTabState, webView: WKWebView) {
        guard let payload = message.body as? [String: Any],
              let event = payload["event"] as? String else { return }

        switch event {
        case "enter":
            guard let session = MediaFullscreenSession(
                tabId: tab.id,
                payload: payload,
                fallbackTitle: tab.displayTitle,
                isMainFrame: message.frameInfo.isMainFrame
            ) else { return }
            overlays.mediaFullscreen = session

            // A frame can only promote itself inside its own viewport, which
            // is still its old box on the page. The top document promotes the
            // frame element; the frame has already promoted the video inside.
            if !message.frameInfo.isMainFrame {
                let frameUrl = message.frameInfo.request.url?.absoluteString ?? ""
                let encoded = Self.javaScriptString(frameUrl)
                webView.evaluateJavaScript(
                    "window.__velaPlayer && window.__velaPlayer.promoteFrame(\(encoded));",
                    completionHandler: nil
                )
            }
        case "state":
            guard var session = overlays.mediaFullscreen, session.tabId == tab.id else { return }
            guard session.applyState(payload) else { return }
            overlays.mediaFullscreen = session
        case "exit":
            if let session = overlays.mediaFullscreen, session.tabId == tab.id {
                overlays.mediaFullscreen = nil
                // The frame put its own video back. The top document is still
                // holding the frame element at full screen, so it has to let
                // go as well.
                if !session.isMainFrame {
                    webView.evaluateJavaScript(
                        "window.__velaPlayer && window.__velaPlayer.releaseFrame();",
                        completionHandler: nil
                    )
                }
            }
        default:
            break
        }
    }

    /// Sends a playback command to the page's player.
    ///
    /// Evaluated in the main frame. The player in a cross-origin frame is
    /// reached by the main frame forwarding the same command over
    /// `postMessage`, which the injected script does when it has no player of
    /// its own.
    public func sendMediaPlayerCommand(_ command: MediaPlayerCommand) {
        guard let session = overlays.mediaFullscreen,
              let webView = tabManager?.webView(for: session.tabId) else { return }

        let call: String
        switch command {
        case .play:
            call = "command('play')"
        case .pause:
            call = "command('pause')"
        case .togglePlay:
            call = "command('toggle')"
        case .seek(let time):
            call = "command('seek', \(Self.javaScriptNumber(time)))"
        case .skip(let delta):
            call = "command('skip', \(Self.javaScriptNumber(delta)))"
        case .setMuted(let muted):
            call = "command('mute', \(muted ? "true" : "false"))"
        case .setVolume(let volume):
            call = "command('volume', \(Self.javaScriptNumber(volume)))"
        case .exit:
            call = "command('exit')"
        }
        webView.evaluateJavaScript(
            "window.__velaPlayer && window.__velaPlayer.\(call);",
            completionHandler: nil
        )
    }

    /// Closes the host layer and tells the page to put its player back.
    public func dismissMediaFullscreen() {
        guard let session = overlays.mediaFullscreen else { return }
        overlays.mediaFullscreen = nil
        guard let webView = tabManager?.webView(for: session.tabId) else { return }
        webView.evaluateJavaScript(
            """
            if (window.__velaPlayer) {
              window.__velaPlayer.command('exit');
              window.__velaPlayer.releaseFrame();
            }
            """,
            completionHandler: nil
        )
    }

    private static func javaScriptNumber(_ value: Double) -> String {
        let safe = value.isFinite ? value : 0
        // `String(_:)` is locale-independent, which is what a JavaScript
        // literal needs: a decimal comma from a localized format would turn
        // the argument into two.
        return String(safe)
    }

    private static func javaScriptString(_ value: String) -> String {
        guard let data = try? JSONEncoder().encode(value),
              let encoded = String(data: data, encoding: .utf8) else { return "\"\"" }
        return encoded
    }

    func handleScrollMessage(_ message: WKScriptMessage, tab: BrowserTabState, webView: WKWebView) {
        // The reporter runs in every frame. A scrolling iframe reports its own
        // `window.scrollY`, which has nothing to do with the tab's document and
        // would overwrite the position the tab is supposed to restore.
        guard message.frameInfo.isMainFrame else { return }
        guard let payload = message.body as? [String: Any],
              let offset = payload["offsetY"] as? Double else { return }
        tab.scrollOffsetY = offset
    }

    func handlePageMetricsMessage(_ message: WKScriptMessage) {
        guard let payload = message.body as? [String: Any] else { return }
        if let find = payload["findResult"] as? [String: Any] {
            overlays.findResult = FindResult(
                count: find["count"] as? Int ?? 0,
                index: find["index"] as? Int ?? -1
            )
        }
    }

    func handleElementPickMessage(_ message: WKScriptMessage, tab: BrowserTabState) {
        guard overlays.isElementPickerArmed,
              let payload = message.body as? [String: Any],
              let selector = payload["selector"] as? String,
              !selector.isEmpty else { return }

        overlays.isElementPickerArmed = false
        guard let host = URL(string: tab.url)?.host else { return }
        let count = payload["elementCount"] as? Int ?? 0
        overlays.elementPick = ElementPickResult(
            selector: selector,
            host: host,
            matchedElementCount: count,
            tagName: payload["tag"] as? String ?? "",
            textPreview: payload["text"] as? String ?? ""
        )
    }

    /// New blocks found by a translated page's observer.
    ///
    /// Only the main frame is accepted: an iframe's content is its own
    /// document and was never part of the page translation.
    func handleTranslationMessage(_ message: WKScriptMessage, from webView: WKWebView) {
        guard message.frameInfo.isMainFrame,
              let tab = tab(for: webView),
              let payload = message.body as? [String: Any],
              let units = payload["units"] as? [[String: Any]], !units.isEmpty,
              let data = try? JSONSerialization.data(withJSONObject: payload),
              let json = String(data: data, encoding: .utf8) else { return }
        dynamicTranslationHandler?(json, tab.id, webView)
    }

    func handleAdBlockReport(_ message: WKScriptMessage, webView: WKWebView) {
        guard let payload = message.body as? [String: Any],
              let count = payload["hiddenCount"] as? Int else { return }
        adBlock.applyReport(hiddenCount: count)
    }

    /// Writes from a script come back as messages. The store is the authority, so
    /// an inbound write is applied and the page's own copy is already up to date.


    func handleConsoleMessage(_ message: WKScriptMessage, tab: BrowserTabState) {
        // Console output is intentionally dropped. There is no element inspector
        // to read it, and buffering every console line of every page is a memory
        // cost with no reader.
    }

    // MARK: - External navigation

    /// Schemes whose only job is to leave the browser.
    ///
    /// A `tel:` or `mailto:` link that quietly did nothing would itself be a
    /// broken link, so these keep whatever policy the user configured.
    static let handoffSchemes: Set<String> = [
        "tel", "mailto", "sms", "facetime", "itms-apps", "maps", "applemaps"
    ]

    /// Decides whether a non-`http(s)` navigation should leave the browser.
    ///
    /// Called only for a scheme Vela does not load itself, so there is no
    /// internal scheme to filter out here.
    ///
    /// The prompt is only shown when the policy is `ask`; `block` silently drops
    /// and `allow` opens directly.
    func handleExternalScheme(_ url: URL, from webView: WKWebView, tab: BrowserTabState) {
        guard let scheme = url.scheme?.lowercased() else { return }

        let host = URL(string: tab.url)?.host ?? ""

        switch resolvedExternalPolicy(scheme: scheme, host: host) {
        case .allow:
            UIApplication.shared.open(url)
        case .block:
            break
        case .ask:
            overlays.externalNavigation = ExternalNavigationRequest(
                url: url,
                sourceHost: host,
                tabId: tab.id
            )
        }
    }

    /// The policy that actually applies to a non-`http(s)` navigation.
    ///
    /// An app deep link — `bilibili://`, `zhihu://`, `taobao://` and the rest —
    /// is what a page uses to pull someone out of the browser mid-read, usually
    /// from an "open in app" overlay the user did not ask for. Prompting still
    /// interrupts them, every single time, so those are blocked unless the user
    /// has ruled on this site themselves.
    ///
    /// A global default is not consent for every site on the web, which is why
    /// the check is for an explicit rule rather than for the default. The
    /// handoff schemes above are the exception: they exist to leave the browser,
    /// so they follow the configured default.
    func resolvedExternalPolicy(scheme: String, host: String) -> ExternalNavigationAppOpenPolicy {
        if Self.handoffSchemes.contains(scheme) {
            return settings.externalNavigationPolicy(for: host)
        }
        if settings.hasExplicitExternalNavigationRule(for: host) {
            return settings.externalNavigationPolicy(for: host)
        }
        return .block
    }

    // MARK: - Universal links

    /// Hosts whose page URLs double as another app's universal links.
    ///
    /// These are the sites where tapping any link makes WebKit hand the
    /// navigation to an installed app instead of loading the web page: the
    /// domains register their own page URLs in the system's app-site
    /// association, and WebKit follows a user-tapped link to them straight
    /// into the app — 抖音, 哔哩哔哩, 微博 and the rest of the majors whose
    /// web version the user is asking to stay on. The custom-scheme deep
    /// links such pages also fire are already blocked by
    /// `resolvedExternalPolicy`; this list closes the universal-link road,
    /// which has no policy prompt of its own to decline.
    ///
    /// Matching is domain-or-subdomain: `douyin.com` covers `www.douyin.com`
    /// and `v.douyin.com`. A host not on the list keeps WebKit's own
    /// behaviour, which is the correct one for sites nobody has complained
    /// about — the association check needs a server round trip the app
    /// cannot make for the whole web, so a curated list is what "the sites
    /// where this happens" can honestly mean.
    static let registeredAppLinkDomains: [String] = [
        // 抖音 / 头条 / 西瓜
        "douyin.com", "iesdouyin.com", "snssdk.com", "toutiao.com", "ixigua.com",
        // 哔哩哔哩（b23.tv 是它的短链域）
        "bilibili.com", "b23.tv",
        // 微博 / 知乎 / 小红书
        "weibo.com", "weibo.cn", "t.cn", "zhihu.com", "xiaohongshu.com", "xhslink.com",
        // 淘宝 / 京东 / 拼多多
        "taobao.com", "tmall.com", "tb.cn", "jd.com", "3.cn",
        "pinduoduo.com", "yangkeduo.com",
        // 快手 / 美团 / 大众点评 / 网易
        "kuaishou.com", "chenzhongtech.com", "meituan.com", "dianping.com", "163.com",
    ]

    /// True when the host is, or belongs to, a registered app-link domain.
    ///
    /// Pure on a string, so it carries no isolation: the policy callback runs
    /// on the main actor and the tests run off it, and neither should have to
    /// care about the other.
    nonisolated static func isRegisteredAppLinkHost(_ host: String?) -> Bool {
        guard let host, !host.isEmpty else { return false }
        let lowered = host.lowercased()
        return registeredAppLinkDomains.contains { domain in
            lowered == domain || lowered.hasSuffix(".\(domain)")
        }
    }

    /// Rewrites a navigation so it lands on the web page instead of in an app.
    ///
    /// WebKit opens an app for a user-tapped universal link only when the
    /// navigation it was allowed to make may open app links — a load the web
    /// view starts itself carries no such permission. So the tap's navigation
    /// is cancelled before WebKit consults the association and the same URL is
    /// requested again through `load`, which arrives as the plain web page.
    /// The cancellation happens before any request goes out, so the rewrite
    /// costs no second fetch.
    func rewriteAppLink(_ url: URL, in webView: WKWebView, tab: BrowserTabState, type: String) {
        if pendingAppLinkReloads.count > 16 {
            // The re-issued load normally removes its own entry within one
            // policy round. A web view torn down between the two leaves the
            // string behind, and this is what stops them accumulating.
            pendingAppLinkReloads.removeAll()
        }
        pendingAppLinkReloads.insert(url.absoluteString)
        log(
            tab: tab,
            event: .appLink,
            url: url.absoluteString,
            type: type,
            outcome: .cancelled
        )
        let request = URLRequest(url: url)
        // Off the policy callback's own turn: the decision to cancel has to be
        // delivered before a new load starts on the same web view.
        Task { @MainActor in
            webView.load(request)
        }
    }

    /// Opens an external URL, optionally remembering the decision.
    public func confirmExternalNavigation(allow: Bool, remember: Bool) {
        guard let request = overlays.externalNavigation else { return }
        defer { overlays.externalNavigation = nil }

        if remember, !request.sourceHost.isEmpty {
            settings.setExternalNavigationRule(
                host: request.sourceHost,
                policy: allow ? .allow : .block
            )
        }
        if allow {
            UIApplication.shared.open(request.url)
        }
    }

    public func dismissExternalNavigation() {
        overlays.externalNavigation = nil
    }

    // MARK: - Find in page

    /// Highlights `query` in the active page and steps through its matches.
    ///
    /// The match list and the position live on the page; this only carries the
    /// query and the direction, so a step cannot disagree with the count the
    /// find bar is showing. `reset` is what a changed query passes: start at
    /// its first match instead of continuing from the previous query's
    /// position.
    public func findInPage(_ query: String, forward: Bool = true, reset: Bool = false) {
        guard let tab = tabManager?.activeTab,
              let webView = tabManager?.webView(for: tab.id) else { return }
        webView.evaluateJavaScript(
            WebPageScripts.findInPageScript(query: query, forward: forward, reset: reset)
        )
    }

    public func clearFindInPage() {
        guard let tab = tabManager?.activeTab,
              let webView = tabManager?.webView(for: tab.id) else { return }
        webView.evaluateJavaScript(WebPageScripts.clearFindInPageScript)
        overlays.findResult = FindResult(count: 0, index: -1)
    }

    /// Recomputes the user scripts attached to a web view for the page it is
    /// about to load.
    ///
    /// WebKit copies the content controller's scripts when the document starts
    /// loading, and the navigation policy callback runs before that, so this is
    /// the last point at which the set can be corrected for the page being
    /// visited. It runs for every main-frame navigation — including a reload —
    /// which is what lets a script installed a moment ago take effect without
    /// rebuilding the web view.
    @MainActor
    func refreshUserScripts(webView: WKWebView, tab: BrowserTabState, url: URL) {
        let controller = webView.configuration.userContentController
        controller.removeAllUserScripts()
        attachPageScripts(to: controller, tab: tab, url: url)
    }

}

// MARK: - Configuration providing

extension BrowserWebCoordinator: BrowserWebViewConfigurationProviding {
    /// Attaches every page script a navigation needs: the browser's own
    /// bridges, the cosmetic filter for this host, and the user scripts that
    /// match this URL.
    ///
    /// The whole set is rebuilt per navigation because WebKit has no way to
    /// remove one user script — `removeAllUserScripts` is the only removal —
    /// and because the cosmetic filter and the user-script match belong to the
    /// page being loaded, not to the URL the web view happened to have when it
    /// was built.
    @MainActor
    private func attachPageScripts(
        to controller: WKUserContentController,
        tab: BrowserTabState,
        url: URL?
    ) {
        // Document-start scripts. Order matters: the history bridge has to be in
        // place before the page's own scripts can call pushState.
        //
        // The WebRTC guard goes first and into every frame. A page can open a
        // peer connection from an iframe, so a main-frame-only guard would
        // leave exactly the case an ad or tracking frame exploits covered.
        if let rtcGuard = WebRTCGuard.script(for: settings.webRTCProtection) {
            controller.addUserScript(
                WKUserScript(
                    source: rtcGuard,
                    injectionTime: .atDocumentStart,
                    forMainFrameOnly: false
                )
            )
        }

        let startScripts: [String] = [
            WebPageScripts.historyApiBridge,
            WebPageScripts.mediaPlayerScript,
            WebPageScripts.inlineVideoControlsScript,
            WebPageScripts.youtubeTapControlsScript,
            WebPageScripts.youtubeQualityScript
        ]

        for source in startScripts {
            controller.addUserScript(
                WKUserScript(source: source, injectionTime: .atDocumentStart, forMainFrameOnly: false)
            )
        }


        // A hand-picked identifier makes a claim the rest of the page surface
        // has to agree with — vendor, userAgentData, window.chrome. The
        // default path sends no script: WebKit's own identity is consistent
        // by construction. Main frame only, because the checks a site's risk
        // control runs happen on the page itself, and per-frame injection
        // would multiply the cost for no page that reads it in a subframe.
        if let customAgent = webIdentity(for: tab).customUserAgent,
           let consistency = WebPageScripts.identityConsistencyScript(userAgent: customAgent) {
            controller.addUserScript(
                WKUserScript(source: consistency, injectionTime: .atDocumentStart, forMainFrameOnly: true)
            )
        }

        if settings.preferences.forcedZoomEnabled ?? false {
            // Remove the page's own zoom lock before and after its markup is
            // parsed: the viewport meta usually arrives with the document.
            for time in [WKUserScriptInjectionTime.atDocumentStart, .atDocumentEnd] {
                controller.addUserScript(
                    WKUserScript(
                        source: WebPageScripts.gestureZoomViewportScript(enabled: true),
                        injectionTime: time,
                        forMainFrameOnly: true
                    )
                )
            }
        }
        controller.addUserScript(
            WKUserScript(
                source: WebPageScripts.scrollReporter,
                injectionTime: .atDocumentEnd,
                forMainFrameOnly: false
            )
        )
        controller.addUserScript(
            WKUserScript(
                source: AdBlockEngine.cosmeticCountingScript,
                injectionTime: .atDocumentEnd,
                forMainFrameOnly: false
            )
        )

        // Cosmetic filtering. Injected as a style element rather than through
        // the rule list because a rule list can only hide by selector if the
        // selector is known at compile time, and the manual element hides are
        // per-host.
        if let host = url?.host,
           let css = adBlock.cosmeticStyle(
               for: host,
               manualSelectors: settings.manualElementHide.effectiveSelectors(for: host)
           ) {
            let combined = """
            (function () {
              var style = document.createElement('style');
              style.id = '\(AdBlockEngine.cosmeticStyleIdentifier)';
              style.textContent = \(jsonLiteral(css));
              (document.head || document.documentElement).appendChild(style);
            })();
            """
            controller.addUserScript(
                WKUserScript(source: combined, injectionTime: .atDocumentStart, forMainFrameOnly: false)
            )
        }

        if overlays.isElementPickerArmed {
            controller.addUserScript(
                WKUserScript(
                    source: WebPageScripts.elementPickerScript,
                    injectionTime: .atDocumentEnd,
                    forMainFrameOnly: true
                )
            )
        }

        // User scripts belong to this page, so the match is recomputed here,
        // for this URL, on every navigation.
        if settings.preferences.userScriptsEnabled,
           tab.privacyMode != .private,
           let pageURL = url {
            let installed = (try? userScripts.enabledScripts()) ?? []
            let matching = UserScriptMatcher.matchingScripts(in: installed, url: pageURL)
            if !matching.isEmpty {
                var values: [String: [String: String]] = [:]
                for script in matching {
                    values[script.id] = (try? userScripts.allValues(scriptId: script.id)) ?? [:]
                }
                let built = UserScriptInjector.makeUserScripts(
                    for: matching,
                    url: pageURL,
                    valuesByScriptId: values,
                    tabId: tab.id
                )
                for script in built.scripts {
                    controller.addUserScript(script)
                }
            }
        }
    }

    // MARK: - Private browsing data

    /// The store private tabs in this window share, created on first use.
    ///
    /// The store belongs to one private session: `takePrivateWebsiteDataStoreForCleanup`
    /// removes it when that session ends or the next one begins, so the next
    /// private page creates a fresh instance. A web view from the ended session
    /// keeps its own reference to the old store, which is why the cleanup
    /// targets the taken instance rather than whatever the property points at
    /// next.
    func privateWebsiteDataStore() -> WKWebsiteDataStore {
        if let sharedPrivateDataStore { return sharedPrivateDataStore }
        let store = WKWebsiteDataStore.nonPersistent()
        sharedPrivateDataStore = store
        return store
    }

    /// Removes the current private store from service and returns it.
    ///
    /// Rotation happens before the store is emptied, not after: a private tab
    /// created while the old store is still being cleared must never be handed
    /// the store that is being emptied. The returned instance is the exact
    /// object the previous session's web views used, so the caller clears the
    /// right one even though `sharedPrivateDataStore` is already nil.
    ///
    /// A nil answer means no private web view was materialised in this window,
    /// or a concurrent end has already taken the store; in both cases there is
    /// nothing for this caller to clear.
    func takePrivateWebsiteDataStoreForCleanup() -> WKWebsiteDataStore? {
        let store = sharedPrivateDataStore
        sharedPrivateDataStore = nil
        return store
    }

    /// Removes every kind of data from a store taken by
    /// `takePrivateWebsiteDataStoreForCleanup`.
    ///
    /// The private tabs must already be closed (`TabManager.endPrivateSession`)
    /// before this runs: this is the store those web views used, and clearing it
    /// while they were still loading would cancel their requests.
    func clearPrivateWebsiteData(_ store: WKWebsiteDataStore) async {
        let types = WKWebsiteDataStore.allWebsiteDataTypes()
        await withCheckedContinuation { continuation in
            store.removeData(
                ofTypes: types,
                modifiedSince: Date(timeIntervalSince1970: 0)
            ) {
                continuation.resume()
            }
        }
    }

    /// Ends the current private session's storage: the store is taken out of
    /// service first, then emptied.
    ///
    /// Lifecycle constraint: the retired store is unreachable from new sessions
    /// but its `removeData` may still be in flight when this returns to the
    /// caller's Task. If the process is suspended or killed before WebKit calls
    /// the completion handler, the retired store's memory is released with the
    /// process and no new session can read it. A strict wipe before process
    /// death would need a background task or a cleanup gate, which this method
    /// deliberately does not add.
    func clearPrivateWebsiteData() async {
        guard let store = takePrivateWebsiteDataStoreForCleanup() else { return }
        await clearPrivateWebsiteData(store)
    }

    /// Starts a new private session's storage.
    ///
    /// The current store, if any, is taken out of service and emptied; the next
    /// private web view creates a fresh one. The old store is unreachable from
    /// the new session even while its clear is still running.
    func beginNewPrivateSession() {
        guard let store = takePrivateWebsiteDataStoreForCleanup() else { return }
        Task { await clearPrivateWebsiteData(store) }
    }

    /// Builds the configuration for a tab.
    ///
    /// The two decisions that matter:
    ///
    /// * Data store. Private tabs share this window's non-persistent store,
    ///   which is what makes private mode real on iOS: cookies, cache and local
    ///   storage live in a store that is emptied when the session ends. An
    ///   ordinary tab keeps the default store.
    /// * Content rules. The compiled `WKContentRuleList` is attached here, per
    ///   navigation, because a list compiled after a web view existed is not
    ///   picked up retroactively.
    public func makeConfiguration(for tab: BrowserTabState) -> WKWebViewConfiguration {
        let configuration = WKWebViewConfiguration()

        configuration.websiteDataStore = tab.privacyMode == .private
            ? privateWebsiteDataStore()
            : WKWebsiteDataStore.default()

        let controller = WKUserContentController()
        configuration.userContentController = controller

        // Message handlers. The coordinator is the handler for all of them; the
        // name on the message decides the branch.
        for handler in WebPageScripts.Handler.allCases {
            controller.add(MessageBridge(coordinator: self), name: handler.rawValue)
        }

        attachPageScripts(to: controller, tab: tab, url: URL(string: tab.url))

        // Attach the compiled rule list synchronously from the last load. The
        // engine keeps the compiled `WKContentRuleList` in memory after it loads
        // it, so a navigation does not have to await a lookup.
        for list in adBlock.attachedRuleLists() {
            controller.add(list)
        }

        // Preferences. `javaScriptCanOpenWindowsAutomatically` stays false: a
        // page that opens a window without a user gesture is a popup, and popups
        // are routed through the new-tab path instead.
        let preferences = configuration.preferences
        preferences.javaScriptCanOpenWindowsAutomatically = false
        preferences.isFraudulentWebsiteWarningEnabled = true
        // `allowsAirPlayForMediaPlayback` is a macOS-only member of
        // `WKPreferences`; on iOS media playback is routed through the system
        // player, so there is no equivalent to set here.

        // Element fullscreen stays enabled for non-video content — an image
        // viewer, a document, a canvas — and picture-in-picture stays opt-in.
        // Video never reaches either: `mediaPlayerScript` takes video-bearing
        // elements over and presents them in the app's own player layer, so
        // the system's media presentation is not the fallback for a film.
        if #available(iOS 15.4, *) {
            preferences.isElementFullscreenEnabled = true
        }

        // The tail of the identifier, appended to the one WebKit builds for
        // itself. Set here rather than as a whole `customUserAgent` so the
        // platform token and the WebKit version token come from the system that
        // is actually running — which is what keeps the identifier correct on a
        // new iOS without a change to this project.
        configuration.applicationNameForUserAgent = webIdentity(for: tab).applicationNameForUserAgent

        configuration.allowsInlineMediaPlayback = true
        configuration.allowsPictureInPictureMediaPlayback = true
        // Audible playback starts from a gesture; silent media may autoplay.
        // This is Safari's own policy, and it is what YouTube's player is
        // built against — a webview that permits everything lets the player
        // initialise paths Safari never runs, which is one of the shapes its
        // generic "出了点问题" error takes.
        configuration.mediaTypesRequiringUserActionForPlayback = .audio

        // A description is what a `target="_blank"` popup inherits; without it
        // WebKit refuses to create the configuration at all.
        return configuration
    }

    /// How this tab identifies itself to sites.
    ///
    /// Read through the protocol rather than from the settings service at the
    /// web-view site, so there is exactly one place that answers "what does a tab
    /// look like to a site" and the per-tab and global paths cannot disagree.
    public func webIdentity(for tab: BrowserTabState) -> BrowserWebIdentity {
        BrowserUserAgent.identity(
            custom: settings.preferences.customUserAgent,
            prefersDesktop: settings.preferences.desktopSiteByDefault,
            // The host the tab is on or heading to — `load` writes the URL
            // before the web view exists, and `didCommit` keeps it current, so
            // a site that branches on the identifier is read from here.
            host: URL(string: tab.url)?.host
        )
    }

    /// Applies 强制网页缩放 to a page that has just loaded or is on screen.
    ///
    /// The switch has no fixed factor: it removes the page's `user-scalable`
    /// and `maximum-scale` lock so the standard pinch gesture works. The
    /// scroll view's limits are configured by the host when the page is
    /// displayed; this only updates the document, for a live toggle.
    public func applyForcedZoom(to webView: WKWebView) {
        // The document side only: the host owns the scroll view's limits and
        // re-establishes them when the page changes.
        webView.evaluateJavaScript(
            WebPageScripts.gestureZoomViewportScript(
                enabled: settings.preferences.forcedZoomEnabled ?? false
            ),
            completionHandler: nil
        )
    }

    /// The coordinator is both of these; WebKit holds them weakly, and the app
    /// environment is what keeps it alive.
    public var navigationDelegate: WKNavigationDelegate? { self }
    public var uiDelegate: WKUIDelegate? { self }

    /// A JSON literal for embedding a Swift string inside injected JavaScript.
    func jsonLiteral(_ value: String) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: [value]),
              let array = String(data: data, encoding: .utf8), array.count >= 2 else {
            return "\"\""
        }
        return String(array.dropFirst().dropLast())
    }
}

// MARK: - History navigation

@MainActor
extension BrowserWebCoordinator {
    /// Goes back in the active tab's history.
    ///
    /// Returns false when there is nothing to go back to, which is the signal
    /// the shell uses to fall back to the home surface. Asking WebKit and then
    /// acting — rather than reading a flag the toolbar also reads — keeps the
    /// two from disagreeing: the button's enabled state is a hint, and this is
    /// the authority.
    ///
    /// A load still in flight is stopped first. WebKit's own step can be
    /// dropped while the navigation machinery is busy with a provisional
    /// request — the exact condition a slow, ad-heavy page is in when the user
    /// gives up on it and taps back — and a step that is silently swallowed
    /// reads as a dead button. The page being left is one the user asked to
    /// leave.
    @discardableResult
    public func goBack() -> Bool {
        guard let tab = tabManager?.activeTab,
              let webView = tabManager?.webView(for: tab.id),
              webView.canGoBack else { return false }
        if webView.isLoading { webView.stopLoading() }
        webView.goBack()
        return true
    }

    /// Goes forward in the active tab's history, under the same rule.
    @discardableResult
    public func goForward() -> Bool {
        guard let tab = tabManager?.activeTab,
              let webView = tabManager?.webView(for: tab.id),
              webView.canGoForward else { return false }
        if webView.isLoading { webView.stopLoading() }
        webView.goForward()
        return true
    }

    /// Re-reads the active tab's back/forward availability from WebKit.
    ///
    /// Called by the shell when the visible tab changes: the flags on a
    /// background tab were written whenever it last finished loading, and a tab
    /// whose web view was rebuilt in between would otherwise show the state of
    /// the web view that no longer exists.
    public func refreshNavigationAvailability() {
        guard let tab = tabManager?.activeTab else { return }
        syncNavigationAvailability(tab: tab, webView: tabManager?.webView(for: tab.id))
    }
}

// MARK: - Script message bridge

/// Bridges a `WKScriptMessageHandler` back to the coordinator.
///
/// A separate object because `WKUserContentController` retains its handlers and
/// the coordinator is the one retained by the environment; routing through a
/// weak proxy would drop messages during startup.
private final class MessageBridge: NSObject, WKScriptMessageHandler {
    private weak var coordinator: BrowserWebCoordinator?

    init(coordinator: BrowserWebCoordinator) {
        self.coordinator = coordinator
        super.init()
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let webView = message.webView else { return }
        // Script delivery is documented main-thread, and `assumeIsolated`
        // exploits that for strict-concurrency correctness — but it traps the
        // process the moment the assumption breaks. Routing the off-main case
        // through a hop instead costs one Task on a path that never happens,
        // and turns a would-be crash into a slightly late message.
        if Thread.isMainThread {
            MainActor.assumeIsolated {
                coordinator?.handle(message: message, from: webView)
            }
        } else {
            let webView = webView
            Task { @MainActor in
                coordinator?.handle(message: message, from: webView)
            }
        }
    }
}
