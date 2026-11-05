//
//  BrowserWebCoordinator+UIDelegate.swift
//  Vela
//
//  The UI delegate: window.open, dialogs, permission prompts and file uploads.
//

import Foundation
import UIKit
import WebKit

// MARK: - UI delegate

extension BrowserWebCoordinator: WKUIDelegate {
    /// Handles `window.open`.
    ///
    /// WebKit's contract here is narrow: hand back a web view built from the
    /// configuration it passed, or refuse the window. Only the first answer
    /// keeps `window.opener` alive between the page and the window it opened
    /// — so answering nil is the browser telling the page its popup was
    /// blocked, whatever the app does next. Vela used to answer nil and open a
    /// tab instead: a sign-in window then had no handle to come back through
    /// and its page sat on a spinner, while a message window fell back to the
    /// page's own in-page copy, half painted over the content it was meant to
    /// float above. Both shapes are the same bug seen from two sides.
    ///
    /// The window is shown as a sheet over the page and goes away when the
    /// page calls `window.close()`.
    public nonisolated func webView(
        _ webView: WKWebView,
        createWebViewWith configuration: WKWebViewConfiguration,
        for navigationAction: WKNavigationAction,
        windowFeatures: WKWindowFeatures
    ) -> WKWebView? {
        // WebKit asks on the main thread, and the page needs the answer inside
        // this call rather than after a hop, so the main actor is asserted
        // instead of awaited — the same bargain the message bridge makes. The
        // view is written to a local so the asserted block carries no value
        // across the boundary, and a call that ever arrives off the main
        // thread is refused rather than trapped.
        guard Thread.isMainThread else { return nil }
        var window: WKWebView?
        MainActor.assumeIsolated {
            window = self.makePopupWindow(for: webView, configuration: configuration)
        }
        return window
    }

    /// Builds the window a page asked for and hands it to the shell.
    ///
    /// One window is shown at a time, so a second `window.open` replaces the
    /// first: the earlier page's `window.close()` has already been honoured
    /// by then in every flow that matters, and a window nobody can see would
    /// otherwise keep loading behind the sheet.
    @MainActor
    private func makePopupWindow(
        for opener: WKWebView,
        configuration: WKWebViewConfiguration
    ) -> WKWebView {
        overlays.popupWindow?.webView.stopLoading()

        let popup = WKWebView(frame: .zero, configuration: configuration)
        popup.navigationDelegate = self
        popup.uiDelegate = self
        popup.allowsBackForwardNavigationGestures = true
        // The window belongs to the page's own identity: it was built from the
        // configuration WebKit cloned off the opener, so the store, the
        // scripts and the identifier are already the page's.
        overlays.popupWindow = PagePopupWindow(
            openerTabId: tab(for: opener)?.id ?? "",
            webView: popup
        )
        return popup
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
    func retirePendingDialog() {
        guard overlays.javascriptDialog != nil else { return }
        resolveJavaScriptDialog(confirmed: false, text: nil)
    }

    /// Media capture permission.
    ///
    /// A request for camera and microphone at once carries both kinds, so a
    /// global default that blocks either one refuses the pair. The prompt
    /// names both, and 「以后对这个网站都这样」 stores both rules.
    public nonisolated func webView(
        _ webView: WKWebView,
        requestMediaCapturePermissionFor origin: WKSecurityOrigin,
        initiatedByFrame frame: WKFrameInfo,
        type: WKMediaCaptureType,
        decisionHandler: @escaping (WKPermissionDecision) -> Void
    ) {
        Task { @MainActor in
            let kinds: [SitePermissionKind]
            switch type {
            case .camera: kinds = [.camera]
            case .microphone: kinds = [.microphone]
            case .cameraAndMicrophone: kinds = [.camera, .microphone]
            @unknown default: kinds = [.camera]
            }
            self.requestPermission(
                kinds: kinds,
                host: origin.host,
                tabId: self.tab(for: webView)?.id ?? ""
            ) { allowed in
                decisionHandler(allowed ? .grant : .deny)
            }
        }
    }

    /// Motion and orientation permission.
    public nonisolated func webView(
        _ webView: WKWebView,
        requestDeviceOrientationAndMotionPermissionFor origin: WKSecurityOrigin,
        initiatedByFrame frame: WKFrameInfo,
        decisionHandler: @escaping (WKPermissionDecision) -> Void
    ) {
        Task { @MainActor in
            self.requestPermission(
                kinds: [.sensor],
                host: origin.host,
                tabId: self.tab(for: webView)?.id ?? ""
            ) { allowed in
                decisionHandler(allowed ? .grant : .deny)
            }
        }
    }

    /// Resolves the prompt on screen.
    ///
    /// `remember` writes a per-site rule; otherwise the answer is held for the
    /// rest of the session. Either way every covered kind is recorded, so the
    /// access log says what actually happened rather than only what the sheet
    /// asked about.
    public func resolvePermissionRequest(allow: Bool, remember: Bool) {
        guard let request = overlays.permissionRequest else { return }
        overlays.permissionRequest = nil

        let rule: SitePermissionRule = allow ? .allow : .block
        // 无痕 never writes a site rule: the promise of the mode is that the
        // next session starts from nothing, and a persistent exception would
        // be exactly the trace it is supposed to leave behind.
        let persistsSiteRule = remember && !request.isPrivate
        let scope: SitePermissionScope = persistsSiteRule
            ? .site
            : (request.isPrivate ? .once : .session)
        for kind in request.coveredKinds {
            if persistsSiteRule {
                settings.setSitePermissionRule(rule, host: request.host, kind: kind)
            } else if !request.isPrivate {
                permissionSessionDecisions[Self.permissionKey(host: request.host, kind: kind)] = rule
            }
            if !request.isPrivate {
                permissionAudit.record(
                    host: request.host,
                    kind: kind,
                    decision: allow ? .allowed : .denied,
                    scope: scope
                )
            }
        }
        request.respond(allow)
    }

    /// Retires a prompt whose tab navigated away.
    ///
    /// WebKit blocks the page on a media decision handler and the page bridge
    /// blocks its wrapper on the JavaScript answer; either one dropping the
    /// question leaves the caller waiting forever. Denying is the only safe
    /// close.
    public func cancelPendingPermission(tabId: String) {
        guard let request = overlays.permissionRequest, request.tabId == tabId else { return }
        overlays.permissionRequest = nil
        if !request.isPrivate {
            permissionAudit.record(
                host: request.host,
                kind: request.kind,
                decision: .denied,
                scope: .once
            )
        }
        request.respond(false)
    }

    /// Answers one request from the rules, or raises the prompt.
    ///
    /// The order is deliberate: a stored site rule, then this session's answer,
    /// then the kind's default. Only `.ask` at the end of that chain reaches
    /// the user.
    @MainActor
    func requestPermission(
        kinds: [SitePermissionKind],
        host: String,
        tabId: String,
        respond: @escaping (Bool) -> Void
    ) {
        let ordered = SitePermissionKind.allCases.filter { kinds.contains($0) }
        guard !ordered.isEmpty else {
            respond(true)
            return
        }

        // A background tab must not raise a sheet over the page the user is
        // reading. The request is refused immediately; when the tab comes
        // forward, its next attempt is asked normally.
        if !tabId.isEmpty, tabId != tabManager?.activeTabId {
            respond(false)
            return
        }

        let isPrivate = tabManager?.tab(id: tabId)?.privacyMode == .private
        let resolved: [(kind: SitePermissionKind, rule: SitePermissionRule, scope: SitePermissionScope)] =
            ordered.map { kind in
                let match = resolvedPermission(kind: kind, host: host)
                return (kind, match.rule, match.scope)
            }

        if resolved.contains(where: { $0.rule == .block }) {
            recordAutomaticDecisions(resolved, host: host, shouldRecord: !isPrivate)
            respond(false)
            return
        }

        if resolved.allSatisfy({ $0.rule == .allow }) {
            recordAutomaticDecisions(resolved, host: host, shouldRecord: !isPrivate)
            respond(true)
            return
        }

        // One prompt at a time. A page that asks again while the sheet is up
        // is refused rather than stacked; leaving it unanswered would hang the
        // page just as badly.
        guard overlays.permissionRequest == nil else {
            if !isPrivate {
                permissionAudit.record(
                    host: host,
                    kind: ordered[0],
                    decision: .denied,
                    scope: .once
                )
            }
            respond(false)
            return
        }

        let askKind = resolved.first(where: { $0.rule == .ask })?.kind ?? ordered[0]
        overlays.permissionRequest = SitePermissionRequest(
            tabId: tabId,
            host: host,
            kind: askKind,
            coveredKinds: ordered,
            isPrivate: isPrivate,
            respond: respond
        )
    }

    @MainActor
    private func resolvedPermission(
        kind: SitePermissionKind,
        host: String
    ) -> (rule: SitePermissionRule, scope: SitePermissionScope) {
        if let site = settings.preferences.sitePermissionRule(host: host, kind: kind) {
            return (site, .site)
        }
        let key = Self.permissionKey(host: host, kind: kind)
        if let session = permissionSessionDecisions[key] {
            return (session, .session)
        }
        return (settings.preferences.sitePermissions[kind], .default)
    }

    @MainActor
    private func recordAutomaticDecisions(
        _ resolved: [(kind: SitePermissionKind, rule: SitePermissionRule, scope: SitePermissionScope)],
        host: String,
        shouldRecord: Bool
    ) {
        guard shouldRecord else { return }
        for item in resolved {
            permissionAudit.record(
                host: host,
                kind: item.kind,
                decision: item.rule == .allow ? .allowed : .denied,
                scope: item.scope
            )
        }
    }

    static func permissionKey(host: String, kind: SitePermissionKind) -> String {
        host.lowercased() + "|" + kind.rawValue
    }

    /// Answers a question from the page-side permission bridge.
    ///
    /// The bridge posts a request id; the reply is a call back into that same
    /// document. A navigation in the meantime retires the request, and the
    /// evaluation then has no promise to resolve, which is correct.
    @MainActor
    func handlePermissionAsk(_ message: WKScriptMessage, webView: WKWebView) {
        guard message.frameInfo.isMainFrame,
              let tab = tab(for: webView),
              let host = URL(string: tab.url)?.host, !host.isEmpty,
              let payload = message.body as? [String: Any],
              let requestId = payload["id"] as? String,
              let rawKind = payload["kind"] as? String,
              let kind = SitePermissionKind(rawValue: rawKind) else { return }

        requestPermission(kinds: [kind], host: host, tabId: tab.id) { allowed in
            let literal = self.jsonLiteral(requestId)
            let flag = allowed ? "true" : "false"
            let script = "window.__velaPermissionResolve(\(literal), \(flag));"
            webView.evaluateJavaScript(script, completionHandler: nil)
        }
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
