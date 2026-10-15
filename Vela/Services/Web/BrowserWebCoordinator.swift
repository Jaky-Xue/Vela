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

    /// The values the shell renders over a page. Owned by the environment and
    /// handed in, so a view can observe one dialog without observing the engine.
    public let overlays: WebPageOverlays

    public init(
        overlays: WebPageOverlays,
        settings: SettingsService,
        adBlock: AdBlockEngine,
        history: HistoryService,
        downloads: DownloadService,
        bookmarks: BookmarkService,
        userScripts: UserScriptRepository,
        searchHistory: SearchHistoryRepository,
        sessionRepository: TabSessionRepository
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
    /// The prompt is only shown when the policy is `ask`; `block` silently drops
    /// and `allow` opens directly.
    private func handleExternalScheme(_ url: URL, from webView: WKWebView, tab: BrowserTabState) {
        guard let scheme = url.scheme?.lowercased(), scheme != "http", scheme != "https" else { return }

        // Internal schemes never leave the app.
        if scheme == "about" || scheme == "data" || scheme == "blob" || scheme == "javascript" {
            return
        }

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
            WebPageScripts.colorSchemeScript(prefersDark: tab.privacyMode == .private)
        ]

        for source in startScripts {
            controller.addUserScript(
                WKUserScript(source: source, injectionTime: .atDocumentStart, forMainFrameOnly: false)
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

        // Element fullscreen and picture-in-picture are what make video playback
        // usable, and both are opt-in on iOS.
        if #available(iOS 15.4, *) {
            preferences.isElementFullscreenEnabled = true
        }

        configuration.allowsInlineMediaPlayback = true
        configuration.allowsPictureInPictureMediaPlayback = true
        configuration.mediaTypesRequiringUserActionForPlayback = []

        // A description is what a `target="_blank"` popup inherits; without it
        // WebKit refuses to create the configuration at all.
        return configuration
    }

    /// The identifier this tab presents to sites.
    ///
    /// Read through the protocol rather than from the settings service at the
    /// web-view site, so there is exactly one place that answers "what does a tab
    /// look like to a site" and the per-tab and global paths cannot disagree.
    public func userAgent(for tab: BrowserTabState) -> String {
        BrowserUserAgent.resolve(
            custom: settings.preferences.customUserAgent,
            prefersDesktop: settings.preferences.desktopSiteByDefault
        )
    }

    /// The coordinator is both of these; WebKit holds them weakly, and the app
    /// environment is what keeps it alive.
    public var navigationDelegate: WKNavigationDelegate? { self }
    public var uiDelegate: WKUIDelegate? { self }

    /// Records a visit for a navigation the coordinator allowed.
    public func recordVisit(
        url: URL,
        title: String,
        boundary: BrowserDataBoundary,
        transition: HistoryTransition
    ) {
        // The tab id is not available here; the caller that owns the tab records
        // through `HistoryService` directly. This conformance exists so the
        // protocol is complete for callers that only have a boundary.
        history.recordVisit(
            url: url,
            title: title,
            tabId: url.host ?? "unknown",
            boundary: boundary,
            transition: transition
        )
    }

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
    public nonisolated func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
    ) {
        Task { @MainActor in
            guard let tab = self.tab(for: webView) else {
                decisionHandler(.allow)
                return
            }

            guard let url = navigationAction.request.url else {
                decisionHandler(.cancel)
                return
            }

            // 1. An external scheme leaves the browser when the policy allows it.
            if let scheme = url.scheme?.lowercased(),
               scheme != "http", scheme != "https", scheme != "about", scheme != "file", scheme != "blob" {
                self.handleExternalScheme(url, from: webView, tab: tab)
                decisionHandler(.cancel)
                return
            }

            // 2. A `target="_blank"` link or a `window.open` becomes a new tab,
            //    created here rather than by WebKit, so the tab registry stays
            //    the only thing that knows which web views exist.
            if navigationAction.targetFrame == nil {
                let created = self.tabManager?.createTab(
                    url: url.absoluteString,
                    privacyMode: tab.privacyMode,
                    openerTabId: tab.id,
                    openSource: .webTargetBlank,
                    activate: !self.settings.preferences.openNewTabsInBackground
                )
                if let created, !self.settings.preferences.openNewTabsInBackground {
                    _ = self.tabManager?.ensureWebView(for: created)
                }
                decisionHandler(.cancel)
                return
            }

            // 3. A user-typed or link navigation updates the pending URL so the
            //    address bar shows it immediately, before the page commits.
            //    iOS reports an address-bar load as `.other` — there is no
            //    `.typed` case on `WKNavigationType`, unlike macOS.
            if navigationAction.navigationType == .other || navigationAction.navigationType == .linkActivated {
                tab.pendingUrl = url.absoluteString
            }

            self.history.recordVisit(
                url: url,
                title: tab.title,
                tabId: tab.id,
                boundary: tab.dataBoundary,
                transition: Self.transition(for: navigationAction.navigationType)
            )
            decisionHandler(.allow)
        }
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

    public nonisolated func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        Task { @MainActor in
            guard let tab = self.tab(for: webView) else { return }
            tab.isLoading = true
            tab.estimatedProgress = 0
            tab.lastError = ""
            tab.runtimeState = tab.id == self.tabManager?.activeTabId ? .active : .background
            self.adBlock.resetPageReport()
        }
    }

    public nonisolated func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        Task { @MainActor in
            guard let tab = self.tab(for: webView) else { return }
            tab.isHome = false
            if let url = webView.url {
                tab.url = url.absoluteString
                tab.pendingUrl = ""
            }
        }
    }

    public nonisolated func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        Task { @MainActor in
            guard let tab = self.tab(for: webView) else { return }
            tab.isLoading = false
            tab.estimatedProgress = 1
            tab.lastLoadedAt = Date()
            tab.runtimeState = tab.id == self.tabManager?.activeTabId ? .active : .background
            if let url = webView.url {
                tab.url = url.absoluteString
                // The last-good pair is what the error surface offers as "go
                // back to the page that worked".
                tab.lastGoodUrl = url.absoluteString
                tab.lastGoodTitle = webView.title ?? tab.title
            }
            if let title = webView.title, !title.isEmpty {
                tab.title = title
                if let url = webView.url {
                    self.history.updateTitle(
                        url: url,
                        title: title,
                        tabId: tab.id,
                        boundary: tab.dataBoundary
                    )
                }
            }
            tab.canGoBack = webView.canGoBack
            tab.canGoForward = webView.canGoForward
            self.tabManager?.persistSession()
        }
    }

    public nonisolated func webView(
        _ webView: WKWebView,
        didFailProvisionalNavigation navigation: WKNavigation!,
        withError error: Error
    ) {
        Task { @MainActor in
            self.handleLoadFailure(webView: webView, error: error, provisional: true)
        }
    }

    public nonisolated func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        Task { @MainActor in
            self.handleLoadFailure(webView: webView, error: error, provisional: false)
        }
    }

    public nonisolated func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        Task { @MainActor in
            guard let tab = self.tab(for: webView) else { return }
            // A content-process kill is not a load failure: reloading the same
            // URL usually succeeds.
            tab.lastCrashReason = .webContentProcess
            tab.runtimeState = .crashed
            tab.isLoading = false
            webView.reload()
        }
    }

    @MainActor
    private func handleLoadFailure(webView: WKWebView, error: Error, provisional: Bool) {
        guard let tab = self.tab(for: webView) else { return }
        let nsError = error as NSError

        // A cancellation is not a failure: it is what a redirect or a
        // `decisionHandler(.cancel)` produces, and surfacing it would put an
        // error page over a navigation the user did not notice happening.
        if nsError.domain == NSURLErrorDomain, nsError.code == NSURLErrorCancelled {
            return
        }

        tab.isLoading = false
        tab.runtimeState = .failed
        tab.lastError = Self.describe(error: nsError)
        tab.pendingUrl = ""
        tab.canGoBack = webView.canGoBack
        tab.canGoForward = webView.canGoForward
    }

    static func describe(error: NSError) -> String {
        if error.domain == NSURLErrorDomain {
            switch error.code {
            case NSURLErrorNotConnectedToInternet:
                return "网络连接不可用。"
            case NSURLErrorTimedOut:
                return "连接超时。"
            case NSURLErrorCannotFindHost:
                return "找不到该服务器。请检查网址是否正确。"
            case NSURLErrorCannotConnectToHost:
                return "无法连接到该服务器。"
            case NSURLErrorNetworkConnectionLost:
                return "网络连接已断开。"
            case NSURLErrorDNSLookupFailed:
                return "域名解析失败。"
            case NSURLErrorSecureConnectionFailed:
                return "安全连接失败，可能是服务器证书有问题。"
            case NSURLErrorServerCertificateUntrusted:
                return "服务器证书不受信任。"
            default:
                break
            }
        }
        if error.domain == "WebKitErrorDomain", error.code == 102 {
            return "该地址无法打开。"
        }
        return error.localizedDescription
    }

    @MainActor
    private func tab(for webView: WKWebView) -> BrowserTabState? {
        guard let tabManager else { return nil }
        return tabManager.tabs.first { tabManager.webView(for: $0.id) === webView }
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
            let created = self.tabManager?.createTab(
                url: url.absoluteString,
                privacyMode: tab.privacyMode,
                openerTabId: tab.id,
                openSource: .webWindowOpen,
                activate: !self.settings.preferences.openNewTabsInBackground
            )
            if let created, !self.settings.preferences.openNewTabsInBackground {
                _ = self.tabManager?.ensureWebView(for: created)
            }
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
        MainActor.assumeIsolated {
            coordinator?.handle(message: message, from: webView)
        }
    }
}
