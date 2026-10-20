//
//  BrowserWebCoordinator+Navigation.swift
//  Vela
//
//  The navigation delegate: policy, commit/finish, failures, app-link rewriting
//  and the per-web-view navigation trace.
//

import Foundation
import UIKit
import WebKit

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
    func resolvePolicy(
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

        // The scripts belong to this page, so they are chosen here, for this
        // URL, before WebKit starts the document.
        refreshUserScripts(webView: webView, tab: tab, url: url)

        // 4. The identifier can depend on the host, and a link tap reaches
        //    this point after the request was built with the previous page's
        //    identifier. A YouTube link opened from another page therefore
        //    carried the iPad identifier and was served the desktop site — the
        //    player this engine cannot caption. The load is cancelled and
        //    re-issued once, the way the app-link rewrite below does it, under
        //    the identifier the destination host needs.
        if navigationAction.navigationType == .linkActivated
            || navigationAction.navigationType == .other,
           let host = url.host,
           BrowserUserAgent.isVideoSiteHost(host),
           pendingIdentityReloads.remove(url.absoluteString) == nil {
            let identity = BrowserUserAgent.identity(
                custom: settings.preferences.customUserAgent,
                prefersDesktop: settings.preferences.desktopSiteByDefault,
                host: host
            )
            if webView.customUserAgent != identity.customUserAgent {
                if pendingIdentityReloads.count > 16 {
                    pendingIdentityReloads.removeAll()
                }
                pendingIdentityReloads.insert(url.absoluteString)
                webView.customUserAgent = identity.customUserAgent
                let target = tab
                // Off the policy callback's own turn: the cancel has to be
                // delivered before a new load starts on the same web view.
                Task { @MainActor in
                    _ = self.tabManager?.load(url: url, in: target)
                }
                return .cancel
            }
        }

        // 5. A tapped universal link on a registered app-link domain is
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

        // 6. A user-typed or link navigation updates the pending URL so the
        //    address bar shows it immediately, before the page commits. iOS
        //    reports an address-bar load as `.other` — there is no `.typed` case
        //    on `WKNavigationType`, unlike macOS.
        if navigationAction.navigationType == .other
            || navigationAction.navigationType == .linkActivated {
            tab.pendingUrl = url.absoluteString
        }

        // 7. Going back, going forward and reloading are re-displays of a page
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

            // A response WebKit cannot render is a download. Vela takes the
            // request over here instead of letting WebKit start a WKDownload:
            // the browser's own transfer engine can queue it, split it into
            // range requests and copy the web view's cookies into the request.
            // The navigation is cancelled so the page behind it stays put.
            if !navigationResponse.canShowMIMEType {
                guard let url = navigationResponse.response.url,
                      let scheme = url.scheme?.lowercased() else {
                    decisionHandler(.download)
                    return
                }
                // Only web URLs are modelled here. A blob or data URL stays on
                // WebKit's own path: URLSession cannot fetch it, and handing it
                // to the queue would only turn a working download into a
                // failed one.
                guard scheme == "http" || scheme == "https" else {
                    decisionHandler(.download)
                    return
                }
                self.downloads.handleWebDownload(
                    request: URLRequest(url: url),
                    boundary: tab.dataBoundary,
                    webView: webView,
                    suggestedFileName: navigationResponse.response.suggestedFilename ?? "download",
                    mimeType: navigationResponse.response.mimeType ?? "",
                    totalBytes: navigationResponse.response.expectedContentLength
                )
                decisionHandler(.cancel)
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
    func beginNavigation(_ navigation: WKNavigation?, in webView: WKWebView) {
        guard let tab = tab(for: webView) else { return }
        pruneTraces()
        // The commands close over the document that registered them; the
        // document is being replaced.
        overlays.userScriptMenuCommands.removeAll { $0.tabId == tab.id }

        let serial = nextNavigationSerial
        nextNavigationSerial += 1
        let url = webView.url?.absoluteString ?? tab.pendingUrl

        // The policy callback attaches the scripts; attaching again here, at
        // the start of the load itself, is the belt to that suspenders — a
        // navigation that reached WebKit from a path without a policy pass
        // still gets the page's scripts before its document is built.
        if let target = URL(string: url) {
            refreshUserScripts(webView: webView, tab: tab, url: target)
        }
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
            if let url = webView.url,
               !(tab.isOfflinePage && url.absoluteString.hasPrefix("about:")) {
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
            if let url = webView.url,
               !(tab.isOfflinePage && url.absoluteString.hasPrefix("about:")) {
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
            // A tab whose web view the pool let go comes back at the top of a
            // fresh document; this is the one event that says the document is
            // ready to be scrolled.
            self.restoreScrollPosition(of: tab, in: webView)
            self.applyForcedZoom(to: webView)
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

    /// Restores the position a discarded or restored tab was left at.
    ///
    /// The flag is consumed here, once, so an ordinary navigation later in the
    /// same tab does not jump back to a place the user has already left.
    @MainActor
    func restoreScrollPosition(of tab: BrowserTabState, in webView: WKWebView) {
        guard tab.pendingScrollRestore else { return }
        tab.pendingScrollRestore = false
        guard tab.scrollOffsetY > 1 else { return }
        webView.evaluateJavaScript(
            WebPageScripts.scrollRestoreScript(offsetY: tab.scrollOffsetY),
            completionHandler: nil
        )
    }

    /// Records a page title on the tab and in the history.
    @MainActor
    func apply(title: String, to tab: BrowserTabState, in webView: WKWebView) {
        tab.title = title
        // A saved page is not a visit; recording its title would edit the
        // history row of the last time the user was actually online.
        guard !tab.isOfflinePage else { return }
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
    func readTitleFromDocument(
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
    func handleLoadFailure(webView: WKWebView, navigation: WKNavigation?, error: Error) {
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
    func isPlaceholderDocument(in webView: WKWebView, tab: BrowserTabState) -> Bool {
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
    func trace(for webView: WKWebView) -> NavigationTrace? {
        guard let trace = traces[ObjectIdentifier(webView)], trace.webView === webView else {
            return nil
        }
        return trace
    }

    /// True when a callback belongs to a navigation the web view has moved past.
    @MainActor
    func isStale(_ navigation: WKNavigation?, in webView: WKWebView) -> Bool {
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
    func elapsedMilliseconds(for webView: WKWebView) -> Int? {
        guard let trace = trace(for: webView) else { return nil }
        return Int(Date().timeIntervalSince(trace.startedAt) * 1000)
    }

    /// Drops traces for web views the pool no longer owns.
    @MainActor
    func pruneTraces() {
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
    func log(
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
    func tab(for webView: WKWebView) -> BrowserTabState? {
        guard let tabManager else { return nil }
        return tabManager.tabs.first { tabManager.webView(for: $0.id) === webView }
    }

    /// The live web view for a tab id, or nil when the tab is cold.
    @MainActor
    func webView(for tabId: String) -> WKWebView? {
        tabManager?.webView(for: tabId)
    }
}

