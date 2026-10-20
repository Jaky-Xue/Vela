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
        shellRoot
        .overlay(alignment: .top) {
            translationBarLayer
        }
        .animation(.snappy(duration: 0.24), value: showsTranslationBar)
        .sheet(isPresented: $showBookmarks) {
            NavigationStack { BookmarksView() }
                .environment(env)
                .browserAmbientSheet()
        }
        .sheet(isPresented: $showHistory) {
            NavigationStack { HistoryView() }
                .environment(env)
                // Applied to the stack rather than to the list so every pushed
                // screenshot — the day groups, an entry's detail sheet — shares
                // the palette without each one restating it.
                .browserListSurface()
                .browserAmbientSheet()
        }
        .sheet(isPresented: $showDownloads) {
            NavigationStack { DownloadsView() }
                .environment(env)
                .browserListSurface()
                .browserAmbientSheet()
        }
        .sheet(isPresented: $showSettings) {
            NavigationStack { SettingsView() }
                .environment(env)
                .browserListSurface()
                .browserAmbientSheet()
        }
        .sheet(isPresented: $showPasswords) {
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
        .sheet(isPresented: $showBookshelf) {
            NovelBookshelfView { book in
                showBookshelf = false
                // A resumed book that still has its chapter cached opens
                // instantly; otherwise the reader loads it itself.
                openNovel(book, chapter: env.novels.cachedChapter(book: book))
            }
            .environment(env)
        }
        .sheet(isPresented: $showShareSheet) {
            if let tab = activeTab, let url = URL(string: tab.url) {
                ShareSheet(items: [url])
            }
        }
        .sheet(isPresented: $showOfflinePages) {
            NavigationStack {
                OfflinePagesView(onOpen: openOfflinePage)
            }
            .environment(env)
            .browserListSurface()
            .browserAmbientSheet()
        }
        .sheet(isPresented: $showMenu) {
            MenuPanelView(
                tiles: env.settings.menuLayout.visibleTiles,
                canActOnPage: canActOnPage,
                isPrivateMode: activeTab?.privacyMode == .private,
                isPrivateBrowsingOn: env.settings.preferences.privateBrowsingMode ?? false,
                adBlockEnabled: env.settings.adBlockSettings.preferences.enabled,
                pageTitle: menuPanelTitle,
                onPerform: handleMenuAction,
                onOpenShortcut: handleMenuShortcut,
                scriptCommands: activeUserScriptCommands,
                onRunScriptCommand: { command in
                    showMenu = false
                    env.webCoordinator.runUserScriptMenuCommand(command)
                }
            )
            .environment(env)
            .browserAmbientSheet()
            // Presented over the panel rather than after it: the user can
            // manage rule sources and close the screen back to the menu.
            .sheet(isPresented: $showAdBlockSettings) {
                NavigationStack { AdBlockSettingsView() }
                    .environment(env)
                    .browserAmbientSheet()
            }
        }
        .sheet(isPresented: $showAddBookmarkChoice) {
            AddBookmarkChoiceSheet(
                url: activeTab?.url ?? "",
                title: activeTab?.title ?? ""
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
    }

}
