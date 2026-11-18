//
//  BrowserShellView+Presentations.swift
//  Vela
//
//  The shell’s sheets, overlays and alerts, split out of the root view file so
//  neither the state machine nor the presentation chain has to be read through
//  the other.
//
import SwiftUI
import UIKit
import WebKit

extension BrowserShellView {
    func presentations() -> some View {
        bookmarksPresentations()
        .sheet(isPresented: shell.binding(forKind: .siteCapabilities)) {
            if let tab = activeTab {
                NavigationStack { SiteCapabilitiesView(tab: tab) }.environment(env).browserAmbientSheet()
            }
        }
        .sheet(isPresented: shell.binding(forKind: .history)) {
            NavigationStack { HistoryView() }
                .environment(env)
                // Applied to the stack rather than to the list so every pushed
                // screenshot — the day groups, an entry's detail sheet — shares
                // the palette without each one restating it.
                .browserListSurface()
                .browserAmbientSheet()
        }
        .sheet(isPresented: shell.binding(forKind: .downloads)) {
            NavigationStack { DownloadsView() }
                .environment(env)
                .browserListSurface()
                .browserAmbientSheet()
        }
        .sheet(isPresented: shell.binding(forKind: .settings)) {
            NavigationStack {
                SettingsView(initialDestination: shell.settingsDestination)
            }
            .environment(env)
            .browserListSurface()
            .browserAmbientSheet()
        }
        .sheet(isPresented: shell.binding(forKind: .passwords)) {
            NavigationStack {
                PasswordVaultView()
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button("完成") { showPasswords = false }
                        }
                    }
            }
            .environment(env)
            .browserAmbientSheet()
        }
        .sheet(isPresented: shell.binding(forKind: .bookshelf)) {
            if let context = shell.bookshelfContext {
                NovelBookshelfView(library: context.library) { book in
                    shell.dismiss(kind: .bookshelf)
                    // A resumed book that still has its chapter cached opens
                    // instantly; otherwise the reader loads it itself.
                    openNovel(
                        book,
                        chapter: context.library.cachedChapter(book: book),
                        sourceTabId: context.sourceTabId,
                        library: context.library,
                        isPrivateSession: context.isPrivate,
                        sessionGeneration: context.generation
                    )
                }
                .environment(env)
            } else {
                Text("无法打开书架。")
                    .padding()
            }
        }
        .sheet(isPresented: shell.binding(forKind: .share)) {
            if let tab = activeTab, let url = URL(string: tab.url) {
                ShareSheet(items: [url])
            }
        }
        .sheet(isPresented: shell.binding(forKind: .offlinePages)) {
            NavigationStack {
                OfflinePagesView(onOpen: openOfflinePage)
            }
            .environment(env)
            .browserListSurface()
            .browserAmbientSheet()
        }
        // The menu is a sheet, and 添加书签/书签/etc. are second sheets. The
        // destination waits for this dismissal to finish rather than asking
        // UIKit to dismiss and present in the same update.
        .sheet(isPresented: shell.menuBinding, onDismiss: { shell.performPendingMenuPresentation() }) {
            MenuPanelView(
                settings: env.settings,
                canActOnPage: canActOnPage,
                isPrivateMode: activeTab?.privacyMode == .private,
                isPrivateBrowsingOn: env.settings.preferences.privateBrowsingMode ?? false,
                // Only an explicit per-site choice lights the tile. The
                // automatic identity on an iPad is desktop without the user
                // asking, and drawing that as an active switch is what made
                // the tile look like a default that had been turned on.
                isDesktopSiteOn: activeTab.flatMap { tab -> Bool? in
                    guard let host = URL(string: tab.url)?.host else { return nil }
                    return env.settings.siteDisplayMode(forPageHost: host) == .desktop
                } ?? false,
                onResetSiteDisplay: {
                    guard let tab = activeTab else { return }
                    shell.dismiss(.menu)
                    resetSiteDisplayMode(for: tab)
                },
                pageTitle: menuPanelTitle,
                onPerform: handleMenuAction,
                onOpenShortcut: handleMenuShortcut
            )
            .environment(env)
            .browserAmbientSheet()
        }
        .sheet(isPresented: shell.binding(forKind: .addBookmarkChoice)) {
            AddBookmarkChoiceSheet(
                url: activeTab?.url ?? "",
                title: activeTab?.title ?? "",
                isPrivate: env.currentPrivacyMode == .private
            )
            .environment(env)
            .browserAmbientSheet()
        }
        .sheet(item: Binding(
            get: { env.overlays.elementPick },
            set: { value in
                if value == nil {
                    env.webCoordinator.disarmElementPicker(in: activeWebView)
                    env.overlays.elementPick = nil
                }
            }
        )) { pick in
            ElementHideConfirmSheet(
                pick: pick,
                onHide: { applyElementHide(pick) },
                onCancel: {
                    env.webCoordinator.disarmElementPicker(in: activeWebView)
                    env.overlays.elementPick = nil
                }
            )
            .environment(env)
            .browserAmbientSheet()
        }
        .alert(
            "离线页面",
            isPresented: Binding(
                get: { offlineNotice != nil },
                set: { if !$0 { offlineNotice = nil } }
            ),
            presenting: offlineNotice
        ) { _ in
            Button("好") { offlineNotice = nil }
        } message: { message in
            Text(message)
        }
        .alert(
            "无法打开该地址",
            isPresented: Binding(
                get: { addressNotice != nil },
                set: { if !$0 { addressNotice = nil } }
            ),
            presenting: addressNotice
        ) { _ in
            Button("搜索「\(rejectedInput)」") {
                let input = rejectedInput
                addressNotice = nil
                searchRefusedInput(input)
            }
            Button("好", role: .cancel) { addressNotice = nil }
        } message: { notice in
            Text(notice)
        }
        .sheet(item: Binding(
            get: { env.overlays.pendingUserScriptInstall },
            set: { value in
                if value == nil {
                    env.overlays.pendingUserScriptInstall = nil
                }
            }
        )) { request in
            UserScriptInstallPromptView(request: request) {
                env.overlays.pendingUserScriptInstall = nil
            }
            .environment(env)
            .browserAmbientSheet()
        }
        .alert(
            env.overlays.javascriptDialog?.message ?? "",
            isPresented: Binding(
                get: { env.overlays.javascriptDialog != nil },
                set: { if !$0 { env.webCoordinator.resolveJavaScriptDialog(confirmed: false, text: nil) } }
            ),
            presenting: env.overlays.javascriptDialog
        ) { dialog in
            switch dialog.kind {
            case .alert:
                Button("好") { env.webCoordinator.resolveJavaScriptDialog(confirmed: true, text: nil) }
            case .confirm:
                Button("取消", role: .cancel) {
                    env.webCoordinator.resolveJavaScriptDialog(confirmed: false, text: nil)
                }
                Button("确定") { env.webCoordinator.resolveJavaScriptDialog(confirmed: true, text: nil) }
            case .prompt:
                // A prompt needs a text field, which an alert cannot host on
                // iOS; the shell routes it to the sheet below instead.
                Button("关闭") { env.webCoordinator.resolveJavaScriptDialog(confirmed: false, text: nil) }
            }
        } message: { dialog in
            if dialog.fromUserScript {
                Text("来自用户脚本")
            }
        }
        .alert(
            "要用其他应用打开吗？",
            isPresented: Binding(
                get: { env.overlays.externalNavigation != nil },
                set: { if !$0 { env.webCoordinator.dismissExternalNavigation() } }
            ),
            presenting: env.overlays.externalNavigation
        ) { request in
            Button("打开") { env.webCoordinator.confirmExternalNavigation(allow: true, remember: false) }
            Button("总是允许此网站") {
                env.webCoordinator.confirmExternalNavigation(allow: true, remember: true)
            }
            Button("取消", role: .cancel) { env.webCoordinator.dismissExternalNavigation() }
        } message: { request in
            Text(request.url.absoluteString)
        }
        .sheet(
            isPresented: Binding(
                get: { env.overlays.permissionRequest != nil },
                // Dismissing the sheet by any route other than the two buttons
                // is a refusal. Leaving the request set would make the sheet
                // re-present forever, and never calling WebKit's handler would
                // block the page on a question nobody can answer.
                set: { if !$0 { env.webCoordinator.resolvePermissionRequest(allow: false, remember: false) } }
            )
        ) {
            if let request = env.overlays.permissionRequest {
                PermissionPromptView(request: request) { allow, remember in
                    env.webCoordinator.resolvePermissionRequest(allow: allow, remember: remember)
                }
                .browserAmbientSheet()
            }
        }
        .fileImporter(
            isPresented: Binding(
                get: { env.overlays.fileUpload != nil },
                set: { if !$0 { env.webCoordinator.resolveFileUpload(nil) } }
            ),
            allowedContentTypes: [.item],
            allowsMultipleSelection: env.overlays.fileUpload?.allowsMultipleSelection ?? false
        ) { result in
            switch result {
            case .success(let urls):
                // A picked file is readable only inside its security scope, and
                // WebKit copies the contents when the handler runs, so access
                // is opened here and left open for WebKit to read through.
                for url in urls {
                    _ = url.startAccessingSecurityScopedResource()
                }
                env.webCoordinator.resolveFileUpload(urls)
            case .failure:
                env.webCoordinator.resolveFileUpload(nil)
            }
        }
        // A sheet's content changing state (a section opening, a row
        // arriving) uses the softer sheet curve rather than each screen
        // picking its own spring.
        .animation(BrowserMotion.sheet(reduceMotion), value: shell.overlays)
    }

    /// The bookmarks surface — the iPad sidebar, the phone sheet, and the jelly
    /// that carries either one in and out.
    ///
    /// Split out of `presentations()` because these three modifiers put that
    /// single chain past the type checker's budget; the failure lands on an
    /// unrelated alert far down the chain, which reads like the alert's fault.
    private func bookmarksPresentations() -> some View {
        shellRoot
            .overlay {
                if usesPadLayout && showBookmarks {
                    bookmarksSidebarLayer
                }
            }
            .animation(reduceMotion ? nil : BrowserMotion.jelly(false), value: showBookmarks)
            .sheet(isPresented: bookmarksSheetBinding) {
                NavigationStack { BookmarksView(onClose: { showBookmarks = false }) }
                    .environment(env)
                    .presentationBackground(.thinMaterial)
            }
    }

    /// The bookmarks sheet exists on phone only; on iPad the same flag drives
    /// the overlay, so the binding must never ask for a sheet there.
    private var bookmarksSheetBinding: Binding<Bool> {
        Binding(
            get: { !usesPadLayout && showBookmarks },
            set: { if !$0 && !usesPadLayout { showBookmarks = false } }
        )
    }

}
