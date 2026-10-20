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
    func retirePendingDialog() {
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

