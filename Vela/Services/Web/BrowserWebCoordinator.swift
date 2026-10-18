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

    private let settings: SettingsService
    private let adBlock: AdBlockEngine
    private let history: HistoryService
    private let downloads: DownloadService
    private let bookmarks: BookmarkService
    private let userScripts: UserScriptRepository
    private let searchHistory: SearchHistoryRepository
    private let sessionRepository: TabSessionRepository
    private weak var tabManager: TabManager?

    /// The structured record of what happened to each navigation. In memory
    /// only; see `NavigationLog`.
    public let navigationLog: NavigationLog

    /// The values the shell renders over a page. Owned by the environment and
    /// handed in, so a view can observe one dialog without observing the engine.
    public let overlays: WebPageOverlays

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
    private struct NavigationTrace {
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

    private var traces: [ObjectIdentifier: NavigationTrace] = [:]
    private var nextNavigationSerial = 1

    /// The URLs this coordinator is re-issuing to strip their app-link
    /// permission.
    ///
    /// A navigation the web view starts itself carries no app-link permission;
    /// the set is how the re-issued load is recognised on its way back through
    /// the policy callback and allowed as the plain web navigation it is,
    /// rather than being rewritten again — which would loop forever.
    private var pendingAppLinkReloads: Set<String> = []

    public init(
        overlays: WebPageOverlays,
        settings: SettingsService,
        adBlock: AdBlockEngine,
        history: HistoryService,
        downloads: DownloadService,
        bookmarks: BookmarkService,
        userScripts: UserScriptRepository,
        searchHistory: SearchHistoryRepository,
        sessionRepository: TabSessionRepository,
        navigationLog: NavigationLog
    ) {
        self.overlays = overlays
        self.settings = settings
        self.adBlock = adBlock
        self.history = history
        self.downloads = downloads
        self.bookmarks = bookmarks
        self.userScripts = userScripts
        self.searchHistory = searchHistory
        self.sessionRepository = sessionRepository
        self.navigationLog = navigationLog
        super.init()
    }

    public func attach(tabManager: TabManager) {
        self.tabManager = tabManager
    }

    // MARK: - Element picker

    public func armElementPicker() {
        overlays.isElementPickerArmed = true
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
        case .userScript:
            handleUserScriptMessage(message, tab: tab, webView: webView)
        case .console:
            handleConsoleMessage(message, tab: tab)
        case .none:
            break
        }
    }

    /// A single-page app changed its URL without navigating, so the tab's URL and
    /// the history both have to be updated, and the change recorded as a visit.
    private func handleHistoryApiMessage(_ message: WKScriptMessage, tab: BrowserTabState) {
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

    private func handleScrollMessage(_ message: WKScriptMessage, tab: BrowserTabState, webView: WKWebView) {
        guard let payload = message.body as? [String: Any],
              let offset = payload["offsetY"] as? Double else { return }
        tab.scrollOffsetY = offset
    }

    private func handlePageMetricsMessage(_ message: WKScriptMessage) {
        guard let payload = message.body as? [String: Any] else { return }
        if let find = payload["findResult"] as? [String: Any] {
            overlays.findResult = FindResult(
                count: find["count"] as? Int ?? 0,
                index: find["index"] as? Int ?? -1
            )
        }
    }

    private func handleElementPickMessage(_ message: WKScriptMessage, tab: BrowserTabState) {
        guard overlays.isElementPickerArmed,
              let payload = message.body as? [String: Any],
              let selector = payload["selector"] as? String,
              !selector.isEmpty else { return }

        overlays.isElementPickerArmed = false
        guard let host = URL(string: tab.url)?.host else { return }
        let count = payload["elementCount"] as? Int ?? 0
        overlays.elementPick = ElementPickResult(selector: selector, host: host, matchedElementCount: count)
    }

    private func handleAdBlockReport(_ message: WKScriptMessage, webView: WKWebView) {
        guard let payload = message.body as? [String: Any],
              let count = payload["hiddenCount"] as? Int else { return }
        adBlock.applyReport(hiddenCount: count)
    }

    /// Writes from a script come back as messages. The store is the authority, so
    /// an inbound write is applied and the page's own copy is already up to date.
    private func handleUserScriptMessage(_ message: WKScriptMessage, tab: BrowserTabState, webView: WKWebView) {
        guard let payload = message.body as? [String: Any],
              let type = payload["type"] as? String,
              let scriptId = payload["scriptId"] as? String else { return }

        switch type {
        case "setValue":
            guard let key = payload["key"] as? String,
                  let value = payload["value"] as? String else { return }
            try? userScripts.setValue(value, key: key, scriptId: scriptId)

        case "deleteValue":
            guard let key = payload["key"] as? String else { return }
            try? userScripts.removeValue(key: key, scriptId: scriptId)

        case "setClipboard":
            guard let text = payload["text"] as? String else { return }
            UIPasteboard.general.string = text

        case "notification":
            // A script notification is surfaced through the app's own banner
            // rather than a page-level alert, so a script cannot block the page.
            if let text = payload["text"] as? String {
                retirePendingDialog()
                overlays.javascriptDialog = JavaScriptDialog(
                    kind: .alert,
                    message: text,
                    defaultText: "",
                    fromUserScript: true,
                    tabId: tab.id
                )
            }

        case "executionError":
            // Recorded rather than surfaced: a script error is the script
            // author's problem, and interrupting browsing with it would be
            // worse than the failure.
            break

        default:
            break
        }
    }

    private func handleConsoleMessage(_ message: WKScriptMessage, tab: BrowserTabState) {
        // Console output is intentionally dropped. There is no element inspector
        // to read it, and buffering every console line of every page is a memory
        // cost with no reader.
    }

    // MARK: - External navigation

    /// Schemes whose only job is to leave the browser.
    ///
    /// A `tel:` or `mailto:` link that quietly did nothing would itself be a
    /// broken link, so these keep whatever policy the user configured.
    private static let handoffSchemes: Set<String> = [
        "tel", "mailto", "sms", "facetime", "itms-apps", "maps", "applemaps"
    ]

    /// Decides whether a non-`http(s)` navigation should leave the browser.
    ///
    /// Called only for a scheme Vela does not load itself, so there is no
    /// internal scheme to filter out here.
    ///
    /// The prompt is only shown when the policy is `ask`; `block` silently drops
    /// and `allow` opens directly.
    private func handleExternalScheme(_ url: URL, from webView: WKWebView, tab: BrowserTabState) {
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
    private func resolvedExternalPolicy(scheme: String, host: String) -> ExternalNavigationAppOpenPolicy {
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
    private func rewriteAppLink(_ url: URL, in webView: WKWebView, tab: BrowserTabState, type: String) {
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

    public func findInPage(_ query: String, forward: Bool = true, reset: Bool = false) {
        guard let tab = tabManager?.activeTab,
              let webView = tabManager?.webView(for: tab.id) else { return }
        let index = reset ? 0 : overlays.findResult.index + (forward ? 1 : -1)
        webView.evaluateJavaScript(WebPageScripts.findInPageScript(query: query, forward: forward, focusIndex: index))
    }

    public func clearFindInPage() {
        guard let tab = tabManager?.activeTab,
              let webView = tabManager?.webView(for: tab.id) else { return }
        webView.evaluateJavaScript(WebPageScripts.clearFindInPageScript)
        overlays.findResult = FindResult(count: 0, index: -1)
    }
}

// MARK: - Configuration providing

extension BrowserWebCoordinator: BrowserWebViewConfigurationProviding {
    /// Builds the configuration for a tab.
    ///
    /// The two decisions that matter:
    ///
    /// * Data store. A private tab gets `WKWebsiteDataStore.nonPersistent()`,
    ///   which is what makes private mode real on iOS: cookies, cache and local
    ///   storage live in a store that is discarded with the session.
    /// * Content rules. The compiled `WKContentRuleList` is attached here, per
    ///   navigation, because a list compiled after a web view existed is not
    ///   picked up retroactively.
    public func makeConfiguration(for tab: BrowserTabState) -> WKWebViewConfiguration {
        let configuration = WKWebViewConfiguration()

        configuration.websiteDataStore = tab.privacyMode == .private
            ? WKWebsiteDataStore.nonPersistent()
            : WKWebsiteDataStore.default()

        let controller = WKUserContentController()
        configuration.userContentController = controller

        // Message handlers. The coordinator is the handler for all of them; the
        // name on the message decides the branch.
        for handler in WebPageScripts.Handler.allCases {
            controller.add(MessageBridge(coordinator: self), name: handler.rawValue)
        }

        // Document-start scripts. Order matters: the history bridge has to be in
        // place before the page's own scripts can call pushState.
        let startScripts: [String] = [
            WebPageScripts.historyApiBridge,
            WebPageScripts.fullscreenBridge,
            WebPageScripts.inlineVideoControlsScript,
            WebPageScripts.youtubeTapControlsScript,
            WebPageScripts.colorSchemeScript(prefersDark: tab.privacyMode == .private)
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

        controller.addUserScript(
            WKUserScript(
                source: WebPageScripts.pageMetricsReporter,
                injectionTime: .atDocumentEnd,
                forMainFrameOnly: false
            )
        )
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
        if let host = URL(string: tab.url)?.host,
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

        // Attach the compiled rule list synchronously from the last load. The
        // engine keeps the compiled `WKContentRuleList` in memory after it loads
        // it, so a navigation does not have to await a lookup.
        for list in adBlock.attachedRuleLists() {
            controller.add(list)
        }

        // User scripts for this URL.
        if settings.preferences.userScriptsEnabled, tab.privacyMode != .private,
           let url = URL(string: tab.url) {
            let installed = (try? userScripts.enabledScripts()) ?? []
            let matching = UserScriptMatcher.matchingScripts(in: installed, url: url)
            if !matching.isEmpty {
                var values: [String: [String: String]] = [:]
                for script in matching {
                    values[script.id] = (try? userScripts.allValues(scriptId: script.id)) ?? [:]
                }
                let built = UserScriptInjector.makeUserScripts(
                    for: matching,
                    url: url,
                    valuesByScriptId: values
                )
                for script in built.scripts {
                    controller.addUserScript(script)
                }
            }
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

        // Preferences. `javaScriptCanOpenWindowsAutomatically` stays false: a
        // page that opens a window without a user gesture is a popup, and popups
        // are routed through the new-tab path instead.
        let preferences = configuration.preferences
        preferences.javaScriptCanOpenWindowsAutomatically = false
        preferences.isFraudulentWebsiteWarningEnabled = true
        // `allowsAirPlayForMediaPlayback` is a macOS-only member of
        // `WKPreferences`; on iOS media playback is routed through the system
        // player, so there is no equivalent to set here.

        // Element fullscreen — the Fullscreen API a page calls from script, and
        // the path a custom video player's fullscreen button takes — and
        // picture-in-picture are both opt-in on iOS. (The other half of the
        // fullscreen story is `UIRequiresFullScreen` in Info.plist: an iPad app
        // that supports multitasking cannot host the system's fullscreen video
        // presentation at all.)
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

    /// The coordinator is both of these; WebKit holds them weakly, and the app
    /// environment is what keeps it alive.
    public var navigationDelegate: WKNavigationDelegate? { self }
    public var uiDelegate: WKUIDelegate? { self }

    /// A JSON literal for embedding a Swift string inside injected JavaScript.
    private func jsonLiteral(_ value: String) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: [value]),
              let array = String(data: data, encoding: .utf8), array.count >= 2 else {
            return "\"\""
        }
        return String(array.dropFirst().dropLast())
    }
}

// MARK: - Navigation delegate

extension BrowserWebCoordinator: WKNavigationDelegate {
    /// The schemes Vela loads in its own web view.
    ///
    /// Anything absent from this set is a URL that belongs to another app or to
    /// the system, so the delegate hands it over — or declines it — instead of
    /// letting WebKit try to render something it cannot. `data`, `blob` and
    /// `javascript` are internal on purpose: a page may legitimately use all
    /// three, and treating them as handoffs breaks the page rather than
    /// protecting the user.
    static let internalSchemes: Set<String> = [
        "http", "https", "about", "file", "blob", "data", "javascript", "ws", "wss"
    ]

    public nonisolated func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
    ) {
        // The decision itself is taken on the main actor, because it reads the
        // tab registry and writes history. WebKit holds the navigation until the
        // handler is called and accepts an asynchronous answer for this
        // callback, which is what makes the hop safe.
        Task { @MainActor in
            decisionHandler(self.resolvePolicy(for: navigationAction, in: webView))
        }
    }

    @MainActor
    private func resolvePolicy(
        for navigationAction: WKNavigationAction,
        in webView: WKWebView
    ) -> WKNavigationActionPolicy {
        guard let tab = tab(for: webView) else { return .allow }
        guard let url = navigationAction.request.url else { return .cancel }

        let scheme = url.scheme?.lowercased() ?? ""
        let typeName = Self.name(for: navigationAction.navigationType)

        // 1. A scheme Vela cannot load leaves the browser when the policy allows
        //    it, and is dropped when it does not.
        guard Self.internalSchemes.contains(scheme) else {
            handleExternalScheme(url, from: webView, tab: tab)
            log(
                tab: tab,
                event: .externalScheme,
                url: url.absoluteString,
                type: typeName,
                outcome: .cancelled
            )
            return .cancel
        }

        // 2. A `target="_blank"` link or a `window.open` becomes a tab of Vela's
        //    own, created here rather than by WebKit, so the tab registry stays
        //    the only thing that knows which web views exist. Answering `.cancel`
        //    is what stops WebKit from building a second web view; it also means
        //    WebKit reports this navigation as interrupted by a policy change,
        //    which the failure path has to recognise as deliberate rather than
        //    as the current page failing — see
        //    `TabNavigationFailure.isCancellation`.
        //
        //    The tab itself is opened *after* the callback returns. Building a
        //    web view synchronously inside WebKit's own policy callback is
        //    reentrant — the callback is on the stack of the web view the new
        //    one is being created beside — and on a tap of a `target="_blank"`
        //    link, which is most links on the web, that reentrancy is the
        //    difference between a new tab and a dead process.
        if navigationAction.targetFrame == nil {
            let url = url
            let sourceTabId = tab.id
            let privacyMode = tab.privacyMode
            let activate = !settings.preferences.openNewTabsInBackground
            Task { @MainActor in
                // A private opener's popups stay private — the mode's store
                // is where their page lives. A regular opener's follow
                // 无痕模式's routing, like every other new page.
                let resolvedPrivacy: BrowserSessionPrivacyMode =
                    privacyMode == .private
                        ? .private
                        : (tabManager?.newPagePrivacyMode ?? privacyMode)
                tabManager?.openTab(
                    url: url,
                    privacyMode: resolvedPrivacy,
                    openerTabId: sourceTabId,
                    openSource: .webTargetBlank,
                    activate: activate
                )
            }
            log(
                tab: tab,
                event: .newTab,
                url: url.absoluteString,
                type: typeName,
                outcome: .ok
            )
            return .cancel
        }

        // 3. Only a main-frame navigation is a page view. A subframe — an ad
        //    iframe, an embedded player, a comment widget — is not a page the
        //    user visited, and recording it would both flood history and put the
        //    iframe's URL in the address bar while the real page was still
        //    loading. `targetFrame` is non-nil here because the
        //    `target="_blank"` case above already returned.
        guard navigationAction.targetFrame?.isMainFrame != false else {
            return .allow
        }

        // 4. A tapped universal link on a registered app-link domain is
        //    rewritten onto the web page instead of into the installed app —
        //    抖音, 哔哩哔哩 and the rest register their page URLs, and WebKit
        //    follows a user tap on them straight out of the browser. A load
        //    the web view starts itself carries no app-link permission, which
        //    is why the cancel-and-reissue lands as the web version.
        //
        //    The re-issued load comes back through here as `.other` with its
        //    URL in `pendingAppLinkReloads`; the removal below is what lets
        //    exactly one rewrite per navigation through. `.other` also covers
        //    loads Vela and page scripts start — an address-bar entry to one
        //    of these hosts takes the same one-round rewrite, and no request
        //    is sent twice by it. Form posts keep their bodies and
        //    back-forward and reload re-display what is already loaded, so
        //    neither is rewritten.
        if navigationAction.navigationType == .linkActivated
            || navigationAction.navigationType == .other,
           Self.isRegisteredAppLinkHost(url.host),
           pendingAppLinkReloads.remove(url.absoluteString) == nil {
            rewriteAppLink(url, in: webView, tab: tab, type: typeName)
            return .cancel
        }

        // 5. A user-typed or link navigation updates the pending URL so the
        //    address bar shows it immediately, before the page commits. iOS
        //    reports an address-bar load as `.other` — there is no `.typed` case
        //    on `WKNavigationType`, unlike macOS.
        if navigationAction.navigationType == .other
            || navigationAction.navigationType == .linkActivated {
            tab.pendingUrl = url.absoluteString
        }

        // 6. Going back, going forward and reloading are re-displays of a page
        //    already in the history, not new visits. Recording them would
        //    inflate every visit count — which is what the new-tab shortcut grid
        //    ranks by — and fill the history list with the same URL over and
        //    over.
        switch navigationAction.navigationType {
        case .backForward, .reload, .formResubmitted:
            return .allow
        default:
            break
        }

        history.recordVisit(
            url: url,
            title: tab.title,
            tabId: tab.id,
            boundary: tab.dataBoundary,
            transition: Self.transition(for: navigationAction.navigationType)
        )
        return .allow
    }

    /// Maps WebKit's navigation type onto the history transition taxonomy, so a
    /// typed URL and a clicked link stay distinguishable in the history list.
    static func transition(for type: WKNavigationType) -> HistoryTransition {
        switch type {
        case .linkActivated: return .link
        case .formSubmitted: return .formSubmit
        case .backForward: return .link
        case .reload: return .reload
        case .formResubmitted: return .formSubmit
        case .other: return .generated
        @unknown default: return .link
        }
    }

    /// The name of a navigation type, for the diagnostics log.
    ///
    /// `WKNavigationType` is not `Codable` and has no `String` raw value, so the
    /// log carries this instead of trying to serialise the enum.
    static func name(for type: WKNavigationType) -> String {
        switch type {
        case .linkActivated: return "linkActivated"
        case .formSubmitted: return "formSubmitted"
        case .backForward: return "backForward"
        case .reload: return "reload"
        case .formResubmitted: return "formResubmitted"
        case .other: return "other"
        @unknown default: return "unknown"
        }
    }

    public nonisolated func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationResponse: WKNavigationResponse,
        decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void
    ) {
        Task { @MainActor in
            guard let tab = self.tab(for: webView) else {
                decisionHandler(.allow)
                return
            }

            // A response WebKit cannot render is a download. This is the only
            // signal iOS gives for "the user asked for a file": there is no
            // separate download API to opt into.
            if !navigationResponse.canShowMIMEType {
                if self.settings.downloadSettings.confirmBeforeDownload {
                    let task = DownloadTask(
                        profileId: tab.dataBoundary.profileId,
                        privacyMode: tab.dataBoundary.privacyMode,
                        dataScope: tab.dataBoundary.dataScope,
                        requestUrl: navigationResponse.response.url?.absoluteString ?? tab.url,
                        suggestedFileName: navigationResponse.response.suggestedFilename ?? "download",
                        mimeType: navigationResponse.response.mimeType ?? "",
                        status: .pending,
                        totalBytes: navigationResponse.response.expectedContentLength
                    )
                    self.downloads.pendingPrompt = task
                }
                decisionHandler(.download)
                return
            }

            // An HTTP response is not a failure just because it is not 2xx.
            // WebKit commits and renders whatever the server sent, including a
            // server-authored 404 or 500 page, and replacing a document that
            // loaded perfectly well with a network-error surface is the mistake
            // this records instead of making.
            if navigationResponse.isForMainFrame,
               let http = navigationResponse.response as? HTTPURLResponse {
                tab.serverStatus = http.statusCode
                if http.statusCode >= 400 {
                    self.log(
                        tab: tab,
                        event: .httpStatus,
                        url: http.url?.absoluteString ?? tab.pendingUrl,
                        outcome: .failure
                    )
                }
            }

            decisionHandler(.allow)
        }
    }

    public nonisolated func webView(
        _ webView: WKWebView,
        navigationResponse: WKNavigationResponse,
        didBecome download: WKDownload
    ) {
        Task { @MainActor in
            // Assigning the delegate inside the main-actor hop rather than in
            // the non-isolated body keeps the access to `downloads` on its own
            // actor under strict concurrency checking.
            download.delegate = self.downloads
            guard let tab = self.tab(for: webView) else { return }
            self.downloads.register(
                download: download,
                request: URLRequest(url: navigationResponse.response.url ?? URL(string: "about:blank")!),
                boundary: tab.dataBoundary,
                suggestedFileName: navigationResponse.response.suggestedFilename ?? "download"
            )
        }
    }

    public nonisolated func webView(
        _ webView: WKWebView,
        navigationAction: WKNavigationAction,
        didBecome download: WKDownload
    ) {
        Task { @MainActor in
            download.delegate = self.downloads
            guard let tab = self.tab(for: webView) else { return }
            self.downloads.register(
                download: download,
                request: navigationAction.request,
                boundary: tab.dataBoundary,
                suggestedFileName: ""
            )
        }
    }

    public nonisolated func webView(
        _ webView: WKWebView,
        didReceiveServerRedirectForProvisionalNavigation navigation: WKNavigation!
    ) {
        Task { @MainActor in
            guard let tab = self.tab(for: webView) else { return }
            let destination = webView.url?.absoluteString ?? tab.pendingUrl

            // A redirect chain can end on a universal link even when the
            // navigation it began as carried no app-link permission: the
            // association check runs on the URL each hop lands on. Stopping
            // and re-issuing the destination — the same rewrite the tap path
            // makes — strips the handoff from the hop that would have taken
            // it, and the re-issued load passes policy through
            // `pendingAppLinkReloads` exactly once.
            if let url = webView.url,
               Self.isRegisteredAppLinkHost(url.host) {
                if self.pendingAppLinkReloads.remove(url.absoluteString) == nil {
                    self.rewriteAppLink(url, in: webView, tab: tab, type: "redirect")
                    return
                }
            }

            // The address bar follows the redirect as soon as it happens rather
            // than waiting for the document to commit, so a chain that stalls
            // does not leave the user looking at the address they typed while
            // the browser is somewhere else entirely.
            tab.pendingUrl = destination
            self.log(
                tab: tab,
                event: .redirect,
                url: self.trace(for: webView)?.url ?? tab.url,
                finalUrl: destination
            )
        }
    }

    public nonisolated func webView(
        _ webView: WKWebView,
        didStartProvisionalNavigation navigation: WKNavigation!
    ) {
        Task { @MainActor in
            self.beginNavigation(navigation, in: webView)
        }
    }

    /// Records a navigation starting and makes it the tab's current one.
    ///
    /// A start always wins. Whatever the tab held before — a settled page, a
    /// failure the user has not acknowledged, a navigation that was cancelled —
    /// is no longer what this web view is doing, and leaving any of it in place
    /// is what makes the chrome describe a page that is not on screen. Every
    /// other callback is a *downgrade* of this state, and `isStale` is what
    /// stops one belonging to a replaced navigation from applying.
    @MainActor
    private func beginNavigation(_ navigation: WKNavigation?, in webView: WKWebView) {
        guard let tab = tab(for: webView) else { return }
        pruneTraces()

        let serial = nextNavigationSerial
        nextNavigationSerial += 1
        let url = webView.url?.absoluteString ?? tab.pendingUrl
        traces[ObjectIdentifier(webView)] = NavigationTrace(
            webView: webView,
            navigation: navigation,
            serial: serial,
            startedAt: Date(),
            url: url
        )

        tab.navigationSerial = serial
        tab.loadState = .provisional
        tab.isLoading = true
        tab.estimatedProgress = 0
        tab.lastFailure = nil
        tab.serverStatus = 0
        tab.runtimeState = tab.id == tabManager?.activeTabId ? .active : .background
        adBlock.resetPageReport()

        log(tab: tab, serial: serial, event: .start, url: url)
    }

    public nonisolated func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        Task { @MainActor in
            guard let tab = self.tab(for: webView),
                  !self.isStale(navigation, in: webView) else { return }
            // WebKit commits its own empty document when it cannot make a
            // connection and has no error to report. Adopting that URL would
            // replace the address the user typed with `about:blank` and then
            // call the navigation a success; `didFinish` turns it into a failure
            // instead, so nothing is written here.
            guard !self.isPlaceholderDocument(in: webView, tab: tab) else { return }

            tab.isHome = false
            tab.loadState = .committed
            if let url = webView.url {
                tab.url = url.absoluteString
                // The one write of `committedUrl`: a document arrived, and this
                // is it. Everything else that changes `tab.url` is a request or a
                // hope, not a document.
                tab.committedUrl = url.absoluteString
                tab.pendingUrl = ""
            }
            // The back/forward list is already settled at commit time — a
            // pushState SPA never reaches `didFinish` for the new entry — so the
            // toolbar is refreshed here as well as at finish.
            self.syncNavigationAvailability(tab: tab, webView: webView)
            self.log(
                tab: tab,
                event: .commit,
                url: tab.url,
                duration: self.elapsedMilliseconds(for: webView)
            )
        }
    }

    public nonisolated func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        Task { @MainActor in
            guard let tab = self.tab(for: webView),
                  !self.isStale(navigation, in: webView) else { return }

            if self.isPlaceholderDocument(in: webView, tab: tab) {
                // A finished navigation that produced an empty document is not a
                // page. Reporting it as one is what leaves a blank rectangle on
                // screen and no explanation anywhere.
                let url = tab.pendingUrl.isEmpty ? tab.url : tab.pendingUrl
                tab.loadState = .failed
                tab.isLoading = false
                tab.estimatedProgress = 0
                tab.url = url
                tab.pendingUrl = ""
                tab.lastFailure = TabNavigationFailure.emptyDocument(url: url)
                tab.canGoBack = webView.canGoBack
                tab.canGoForward = webView.canGoForward
                self.log(
                    tab: tab,
                    event: .fail,
                    url: url,
                    duration: self.elapsedMilliseconds(for: webView),
                    outcome: .failure
                )
                return
            }

            tab.loadState = .finished
            tab.isLoading = false
            tab.estimatedProgress = 1
            tab.lastLoadedAt = Date()
            // A page that loaded is not a page that failed, however recently it
            // did. Leaving the old message behind is what puts an error surface
            // over a working page after a successful retry.
            tab.lastFailure = nil
            tab.runtimeState = tab.id == self.tabManager?.activeTabId ? .active : .background
            if let url = webView.url {
                tab.url = url.absoluteString
                tab.pendingUrl = ""
                // The last-good pair is what the error surface offers as "go
                // back to the page that worked".
                tab.lastGoodUrl = url.absoluteString
                tab.lastGoodTitle = webView.title ?? tab.title
            }
            if let title = webView.title, !title.isEmpty {
                self.apply(title: title, to: tab, in: webView)
            } else {
                // `WKWebView.title` can still be empty when `didFinish` arrives.
                // The property is updated by an observer that runs alongside the
                // parser, and a small document over a fast link finishes inside
                // that window — which leaves the tab strip, the history list and
                // the address bar showing only the host of a page that has a
                // perfectly good title. Asking the document is authoritative, so
                // it is asked rather than the title being accepted as absent.
                self.readTitleFromDocument(of: webView, tab: tab, navigation: navigation)
            }
            tab.canGoBack = webView.canGoBack
            tab.canGoForward = webView.canGoForward
            self.log(
                tab: tab,
                event: .finish,
                url: webView.url?.absoluteString ?? tab.url,
                duration: self.elapsedMilliseconds(for: webView),
                finalUrl: webView.url?.absoluteString
            )
            // A finished page is worth a card. The overview draws every tab,
            // and the cold ones — the tabs the live pool has let go — have no
            // view to ask for a picture. This is the one moment the page is
            // certainly loaded and laid out, so the print is taken here and
            // kept for the overview to find later.
            self.tabManager?.capturePreview(for: tab.id)
            self.tabManager?.persistSession()
        }
    }

    /// Records a page title on the tab and in the history.
    @MainActor
    private func apply(title: String, to tab: BrowserTabState, in webView: WKWebView) {
        tab.title = title
        guard let url = webView.url else { return }
        history.updateTitle(
            url: url,
            title: title,
            tabId: tab.id,
            boundary: tab.dataBoundary
        )
    }

    /// Asks the document for its title, for the case where `WKWebView.title` had
    /// not caught up by `didFinish`.
    ///
    /// The answer arrives after the fact, so it is applied only if the tab is
    /// still showing the navigation that asked: a page whose title was empty
    /// must not have it filled in by a page the user has already left.
    ///
    /// The ask is repeated, on a short leash. The reply is delivered by WebKit's
    /// content process, and when that process is frozen or torn down mid
    /// round-trip the reply is simply dropped — the `await` never resumes and
    /// one lost message would strand the tab on its host name forever. Each ask
    /// therefore runs as its own task, so a hung one blocks only its own
    /// attempt, and a later ask — a fresh message over a fresh connection —
    /// is what usually lands.
    @MainActor
    private func readTitleFromDocument(
        of webView: WKWebView,
        tab: BrowserTabState,
        navigation: WKNavigation?
    ) {
        Task { @MainActor in
            for attempt in 1...4 {
                guard !self.isStale(navigation, in: webView),
                      // Nothing is overwritten: if a title arrived by another
                      // route in the meantime, that one wins.
                      tab.title.isEmpty,
                      self.tab(for: webView) === tab,
                      tab.loadState == .finished else { return }

                Task { @MainActor in
                    guard let value = try? await webView.evaluateJavaScript("document.title"),
                          let title = value as? String,
                          !title.isEmpty,
                          self.tab(for: webView) === tab,
                          tab.title.isEmpty,
                          tab.loadState == .finished else { return }
                    self.apply(title: title, to: tab, in: webView)
                }

                if attempt < 4 {
                    try? await Task.sleep(nanoseconds: 700_000_000)
                }
            }
        }
    }

    public nonisolated func webView(
        _ webView: WKWebView,
        didFailProvisionalNavigation navigation: WKNavigation!,
        withError error: Error
    ) {
        Task { @MainActor in
            self.handleLoadFailure(webView: webView, navigation: navigation, error: error)
        }
    }

    public nonisolated func webView(
        _ webView: WKWebView,
        didFail navigation: WKNavigation!,
        withError error: Error
    ) {
        Task { @MainActor in
            self.handleLoadFailure(webView: webView, navigation: navigation, error: error)
        }
    }

    public nonisolated func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        Task { @MainActor in
            guard let tab = self.tab(for: webView) else { return }
            // A dead content process is not a network failure and is not
            // reported as one: the request succeeded and the renderer died. It
            // is also the one failure the app cannot paper over — the page's own
            // state is gone — so rather than reloading silently the tab is put
            // into the crash state and the error surface offers the reload.
            //
            // Reloading here would additionally be a no-op for a tab that never
            // committed: `reload()` on a web view with no document does nothing,
            // which left the tab marked `crashed` with a blank page and no way
            // out of it.
            tab.loadState = .crashed
            tab.isLoading = false
            tab.estimatedProgress = 0
            tab.pendingUrl = ""
            tab.lastCrashReason = .webContentProcess
            tab.lastFailure = TabNavigationFailure.crashed(url: tab.url)
            // The back/forward list lived in the process that died.
            tab.canGoBack = false
            tab.canGoForward = false
            log(tab: tab, event: .crash, url: tab.url, outcome: .failure)
        }
    }

    /// Settles a tab after a navigation that failed.
    ///
    /// The two guards are the whole point of the correlation:
    ///
    /// * `isStale` rejects a callback for a navigation this web view has already
    ///   replaced. Without it, a superseded navigation's failure is written onto
    ///   the tab as if it belonged to the navigation that replaced it.
    /// * A cancellation is only recorded when the tab was actually waiting on
    ///   something, and never while the web view is still loading: a
    ///   cancellation with a load still in flight is the *other* navigation
    ///   being superseded, and clearing the live one's loading state is what
    ///   makes a spinner disappear from a page that has not arrived yet.
    @MainActor
    private func handleLoadFailure(webView: WKWebView, navigation: WKNavigation?, error: Error) {
        guard let tab = tab(for: webView) else { return }
        let nsError = error as NSError

        // A callback for a navigation this web view has moved past says nothing
        // about what it is doing now — *but only while it is doing something*.
        // WebKit does not always hand over the same `WKNavigation` object it
        // announced the navigation with, so a failure that arrives with an
        // unexpected identity while nothing else is in flight is the failure of
        // the request the tab actually made. Dropping it there is what leaves a
        // tab stuck on a page that never loads with nothing to show for it.
        if isStale(navigation, in: webView), webView.isLoading { return }

        if TabNavigationFailure.isCancellation(nsError) {
            // A page that already committed is still on screen and is not
            // cancelled, whatever WebKit says about a navigation that never
            // became the document.
            guard tab.loadState.isInFlight, !webView.isLoading else { return }
            tab.loadState = .cancelled
            tab.isLoading = false
            tab.pendingUrl = ""
            syncNavigationAvailability(tab: tab, webView: webView)
            log(
                tab: tab,
                event: .cancel,
                url: trace(for: webView)?.url ?? tab.url,
                error: nsError,
                outcome: .cancelled
            )
            return
        }

        tab.loadState = .failed
        tab.isLoading = false
        tab.estimatedProgress = 0
        tab.pendingUrl = ""
        tab.lastFailure = TabNavigationFailure.make(from: nsError, url: tab.url)
        tab.canGoBack = webView.canGoBack
        tab.canGoForward = webView.canGoForward
        log(
            tab: tab,
            event: .fail,
            url: trace(for: webView)?.url ?? tab.url,
            duration: elapsedMilliseconds(for: webView),
            error: nsError,
            outcome: .failure
        )
    }

    /// True when WebKit is showing its own empty document to a tab that asked
    /// for a real page.
    ///
    /// A brand-new web view's initial document is `about:blank`, and WebKit also
    /// commits one when it cannot make a connection and has no error to report.
    /// The two are indistinguishable here, and both mean the same thing for a tab
    /// whose `pendingUrl` is an `http(s)` address: the document on screen is not
    /// the one that was asked for. The pending URL is what tells them apart from
    /// a page that legitimately *is* `about:blank`, which the address bar accepts
    /// and which is only ever loaded with no pending request behind it.
    @MainActor
    private func isPlaceholderDocument(in webView: WKWebView, tab: BrowserTabState) -> Bool {
        let document = webView.url?.absoluteString.lowercased() ?? ""
        guard document.hasPrefix("about:") else { return false }
        let pending = tab.pendingUrl.lowercased()
        return pending.hasPrefix("http://") || pending.hasPrefix("https://")
    }

    // MARK: - Traces

    /// What is known about the navigation a web view is running, if it is the
    /// one this trace was written for.
    ///
    /// The identity check on the view is not paranoia: traces are keyed by
    /// `ObjectIdentifier`, and an identifier is only unique among live objects,
    /// so a released web view could otherwise hand its trace to the next
    /// allocation.
    @MainActor
    private func trace(for webView: WKWebView) -> NavigationTrace? {
        guard let trace = traces[ObjectIdentifier(webView)], trace.webView === webView else {
            return nil
        }
        return trace
    }

    /// True when a callback belongs to a navigation the web view has moved past.
    @MainActor
    private func isStale(_ navigation: WKNavigation?, in webView: WKWebView) -> Bool {
        guard let navigation, let current = trace(for: webView)?.navigation else {
            // Nothing recorded, or WebKit handed over no navigation object.
            // There is nothing to compare against, so the callback is taken at
            // face value rather than dropped.
            return false
        }
        return current !== navigation
    }

    /// Milliseconds since the current navigation started.
    @MainActor
    private func elapsedMilliseconds(for webView: WKWebView) -> Int? {
        guard let trace = trace(for: webView) else { return nil }
        return Int(Date().timeIntervalSince(trace.startedAt) * 1000)
    }

    /// Drops traces for web views the pool no longer owns.
    @MainActor
    private func pruneTraces() {
        guard traces.count > TabManager.maximumLiveWebViews else { return }
        let live = (tabManager?.tabs ?? []).compactMap { tabManager?.webView(for: $0.id) }
        traces = traces.filter { entry in
            guard let webView = entry.value.webView else { return false }
            return live.contains { $0 === webView }
        }
    }

    /// Writes one structured entry to the navigation log.
    ///
    /// Every call site goes through here rather than reaching for the log
    /// directly, so the two facts that belong on every entry — what the tab's
    /// state became, and whether the two features that can change a page's
    /// behaviour were switched on — cannot be forgotten at one of them.
    @MainActor
    private func log(
        tab: BrowserTabState,
        serial: Int? = nil,
        event: NavigationEvent,
        url: String,
        type: String = "",
        duration: Int? = nil,
        finalUrl: String? = nil,
        error: NSError? = nil,
        outcome: NavigationOutcome = .info
    ) {
        navigationLog.record(
            tabId: tab.id,
            navigationSerial: serial ?? tab.navigationSerial,
            event: event,
            phase: tab.loadState,
            url: url,
            navigationType: type,
            durationMs: duration,
            finalUrl: finalUrl,
            errorDomain: error?.domain ?? "",
            errorCode: error?.code ?? 0,
            errorMessage: error?.localizedDescription ?? "",
            outcome: outcome,
            adBlockActive: adBlock.isReady && settings.adBlockSettings.preferences.enabled,
            userScriptsActive: settings.preferences.userScriptsEnabled
        )
    }

    @MainActor
    private func tab(for webView: WKWebView) -> BrowserTabState? {
        guard let tabManager else { return nil }
        return tabManager.tabs.first { tabManager.webView(for: $0.id) === webView }
    }

    /// The live web view for a tab id, or nil when the tab is cold.
    @MainActor
    func webView(for tabId: String) -> WKWebView? {
        tabManager?.webView(for: tabId)
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

// MARK: - UI delegate

extension BrowserWebCoordinator: WKUIDelegate {
    /// Handles `window.open`. Returning nil means WebKit does not create a web
    /// view, which is correct here because the coordinator has already made a
    /// tab for it.
    public nonisolated func webView(
        _ webView: WKWebView,
        createWebViewWith configuration: WKWebViewConfiguration,
        for navigationAction: WKNavigationAction,
        windowFeatures: WKWindowFeatures
    ) -> WKWebView? {
        guard let url = navigationAction.request.url else { return nil }
        Task { @MainActor in
            guard let tab = self.tab(for: webView) else { return }
            // `decidePolicyFor` answers `.cancel` for a `target="_blank"` link,
            // which is what normally turns one into a tab. This hook is the other
            // way WebKit asks for a window — a page calling `window.open` — and it
            // lands in the same place so the two cannot diverge.
            let resolvedPrivacy: BrowserSessionPrivacyMode =
                tab.privacyMode == .private
                    ? .private
                    : (self.tabManager?.newPagePrivacyMode ?? tab.privacyMode)
            self.tabManager?.openTab(
                url: url,
                privacyMode: resolvedPrivacy,
                openerTabId: tab.id,
                openSource: .webWindowOpen,
                activate: !self.settings.preferences.openNewTabsInBackground
            )
        }
        return nil
    }

    public nonisolated func webView(
        _ webView: WKWebView,
        runJavaScriptAlertPanelWithMessage message: String,
        initiatedByFrame frame: WKFrameInfo,
        completionHandler: @escaping () -> Void
    ) {
        Task { @MainActor in
            retirePendingDialog()
            self.overlays.javascriptDialog = JavaScriptDialog(
                kind: .alert,
                message: message,
                defaultText: "",
                fromUserScript: false,
                tabId: self.tab(for: webView)?.id ?? ""
            )
            // The pending value is only consumed by the UI, so the completion
            // handler is deferred until the user dismisses it. WebKit blocks the
            // page on this handler, which is the intended `alert()` behaviour.
            self.overlays.javascriptAlertCompletion = completionHandler
        }
    }

    public nonisolated func webView(
        _ webView: WKWebView,
        runJavaScriptConfirmPanelWithMessage message: String,
        initiatedByFrame frame: WKFrameInfo,
        completionHandler: @escaping (Bool) -> Void
    ) {
        Task { @MainActor in
            retirePendingDialog()
            self.overlays.javascriptDialog = JavaScriptDialog(
                kind: .confirm,
                message: message,
                defaultText: "",
                fromUserScript: false,
                tabId: self.tab(for: webView)?.id ?? ""
            )
            self.overlays.javascriptConfirmCompletion = completionHandler
        }
    }

    public nonisolated func webView(
        _ webView: WKWebView,
        runJavaScriptTextInputPanelWithPrompt prompt: String,
        defaultText: String?,
        initiatedByFrame frame: WKFrameInfo,
        completionHandler: @escaping (String?) -> Void
    ) {
        Task { @MainActor in
            retirePendingDialog()
            self.overlays.javascriptDialog = JavaScriptDialog(
                kind: .prompt,
                message: prompt,
                defaultText: defaultText ?? "",
                fromUserScript: false,
                tabId: self.tab(for: webView)?.id ?? ""
            )
            self.overlays.javascriptPromptCompletion = completionHandler
        }
    }

    /// Answers any dialog already showing before a new one takes its place.
    ///
    /// WebKit blocks the page on these completion handlers, and one that is
    /// silently dropped never unblocks it. A page that raises a second dialog
    /// while the first is still on screen — a script firing `alert()` in a
    /// loop, say — would otherwise strand the first handler forever; resolving
    /// it as a cancellation is the only outcome that keeps the page moving.
    @MainActor
    private func retirePendingDialog() {
        guard overlays.javascriptDialog != nil else { return }
        resolveJavaScriptDialog(confirmed: false, text: nil)
    }

    /// Media capture permission.
    ///
    /// per-site rules in `SitePermissionDefaultSettings`. iOS asks the app once
    /// per origin; Vela answers from the site rule rather than prompting again,
    /// because the app-level permission prompt has already been shown by the
    /// system by this point.
    public nonisolated func webView(
        _ webView: WKWebView,
        requestMediaCapturePermissionFor origin: WKSecurityOrigin,
        initiatedByFrame frame: WKFrameInfo,
        type: WKMediaCaptureType,
        decisionHandler: @escaping (WKPermissionDecision) -> Void
    ) {
        Task { @MainActor in
            let kind: SitePermissionKind
            switch type {
            case .camera: kind = .camera
            case .microphone: kind = .microphone
            case .cameraAndMicrophone: kind = .camera
            @unknown default: kind = .camera
            }

            let rule = self.settings.preferences.sitePermissions[kind]
            switch rule {
            case .allow:
                decisionHandler(.grant)
            case .block:
                decisionHandler(.deny)
            case .ask:
                self.overlays.permissionRequest = SitePermissionRequest(
                    origin: origin.host,
                    kind: kind,
                    decisionHandler: decisionHandler
                )
            }
        }
    }

    /// Resolves a pending media-capture prompt.
    public func resolvePermissionRequest(allow: Bool, remember: Bool) {
        guard let request = overlays.permissionRequest else { return }
        defer { overlays.permissionRequest = nil }
        if remember {
            settings.setSitePermissionDefault(allow ? .allow : .block, kind: request.kind)
        }
        request.decisionHandler(allow ? .grant : .deny)
    }

    /// File uploads.
    ///
    /// Returning without calling the completion handler would hang the page, so
    /// the handler is always called; cancelling means calling it with no URL,
    /// which the page sees as "user cancelled".
    ///
    /// `WKOpenPanelParameters` only exists on iOS 18.4 and later — WebKit added
    /// the hook then, and before it the app had no way into the file picker. On
    /// older systems this delegate method is absent and WebKit's own picker
    /// handles the input, so uploads still work; they just skip Vela's UI.
    @available(iOS 18.4, *)
    public nonisolated func webView(
        _ webView: WKWebView,
        runOpenPanelWith parameters: WKOpenPanelParameters,
        initiatedByFrame frame: WKFrameInfo,
        completionHandler: @escaping ([URL]?) -> Void
    ) {
        Task { @MainActor in
            self.overlays.fileUpload = FileUploadRequest(
                allowsMultipleSelection: parameters.allowsMultipleSelection,
                completionHandler: completionHandler
            )
        }
    }

    /// The long-press menu for a link or image.
    ///
    /// menu spec in `docs/aira-web-longpress-context-menu-implementation.md`.
    /// Returning nil keeps WebKit's own menu, which already offers open, copy,
    /// share and save-image; Vela adds its own entries through the shell instead
    /// of rebuilding the system menu.
    public nonisolated func webView(
        _ webView: WKWebView,
        contextMenuConfigurationForElement elementInfo: WKContextMenuElementInfo,
        completionHandler: @escaping (UIContextMenuConfiguration?) -> Void
    ) {
        completionHandler(nil)
    }
}

// MARK: - Dialog plumbing

extension BrowserWebCoordinator {
    /// Resolves the pending JavaScript dialog.
    public func resolveJavaScriptDialog(confirmed: Bool, text: String?) {
        guard let dialog = overlays.javascriptDialog else { return }
        overlays.javascriptDialog = nil

        switch dialog.kind {
        case .alert:
            overlays.javascriptAlertCompletion?()
            overlays.javascriptAlertCompletion = nil
        case .confirm:
            overlays.javascriptConfirmCompletion?(confirmed)
            overlays.javascriptConfirmCompletion = nil
        case .prompt:
            overlays.javascriptPromptCompletion?(text)
            overlays.javascriptPromptCompletion = nil
        }
    }

    /// Resolves the pending file upload.
    ///
    /// WebKit blocks the page until the completion handler runs, so a dismissal
    /// by any route — the picker's cancel button, a swipe — still has to call
    /// it, with `nil` for "user cancelled". Never calling it hangs the page on
    /// a question nobody can answer.
    public func resolveFileUpload(_ urls: [URL]?) {
        guard let request = overlays.fileUpload else { return }
        defer { overlays.fileUpload = nil }
        request.completionHandler(urls)
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
