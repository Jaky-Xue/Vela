//
//  BrowserShellView+TranslationAndOffline.swift
//  Vela
//
//  The translation bar’s state helpers and the offline-page actions.
//
import SwiftUI
import UIKit
import WebKit

extension BrowserShellView {
    // MARK: - Page translation

    /// Whether the translation bar should be on screen.
    ///
    /// It appears for an automatic offer, while a translation runs, and while
    /// one is applied. It stays out of the way of the tab overview, the
    /// scanner, the novel reader and the omnibox search page: those are layers
    /// above the page, and a small bar floating over them would read as part
    /// of them.
    var showsTranslationBar: Bool {
        guard !translationBarDismissed,
              !showTabsOverview,
              !showQRScanner,
              novelSession == nil,
              !omnibox.isEditing,
              let tab = activeTab,
              !tab.isHome,
              tabManager.webView(for: tab.id) != nil else { return false }

        if env.translation.isBusy || env.translation.isTranslated { return true }
        if case .failed = env.translation.phase { return true }
        return env.translation.detected != nil
    }

    /// The distance from the window's top to the bar.
    ///
    /// On the iPad layout the bar sits under the chrome's top bar when it is
    /// visible; on the phone layout there is no top bar, so it sits below the
    /// status bar. The page runs underneath it either way.
    var translationBarTopPadding: CGFloat {
        if usesPadLayout {
            return safeTop + (chromeHidden ? 6 : Self.padTopBarHeight + 6)
        }
        return safeTop + 6
    }

    /// Re-identifies the page the translation bar belongs to.
    var translationDetectionKey: String {
        guard let tab = activeTab, !tab.isHome, tab.loadState == .finished else {
            return ""
        }
        return "\(tab.id)|\(tab.url)"
    }

    @ViewBuilder
    var translationBarLayer: some View {
        if showsTranslationBar, let webView = activeWebView {
            TranslationBar(
                webView: webView,
                onClose: {
                    withAnimation(.snappy(duration: 0.2)) {
                        translationBarDismissed = true
                    }
                },
                onOpenSettings: { showSettings = true }
            )
            .padding(.horizontal, 10)
            .padding(.top, translationBarTopPadding)
            .transition(.move(edge: .top).combined(with: .opacity))
            .zIndex(12)
        }
    }

    /// Hands the active tab and document to the translation service, which is
    /// where the per-tab applied state lives.
    func syncTranslationState() {
        guard let tab = activeTab else {
            env.translation.reset()
            return
        }
        env.translation.sync(
            tabId: tab.id,
            url: tab.url,
            webView: tabManager.webView(for: tab.id)
        )
    }

    /// Recognises the page's language and, when it differs from the target,
    /// leaves the bar showing its offer. A site marked 总是翻译 starts at once.
    func offerTranslationIfNeeded() async {
        guard let tab = activeTab, !tab.isHome, tab.loadState == .finished,
              let webView = tabManager.webView(for: tab.id) else { return }

        let settings = env.settings.translationSettings
        guard settings.offersAutomatically else { return }
        if let host = URL(string: tab.url)?.host,
           settings.rule(for: host) == .never {
            return
        }
        if env.translation.isTranslated || env.translation.isBusy { return }

        await env.translation.detectLanguage(in: webView, target: settings.target)

        guard activeTab?.id == tab.id,
              !env.translation.isTranslated,
              !env.translation.isBusy else { return }
        if let host = URL(string: tab.url)?.host,
           settings.rule(for: host) == .always,
           env.translation.detected != nil {
            startPageTranslation(target: settings.target)
        }
    }

    /// Starts translating the active page.
    func startPageTranslation(target: TranslationTargetLanguage? = nil) {
        guard let tab = activeTab, !tab.isHome,
              let webView = tabManager.webView(for: tab.id) else { return }
        translationBarDismissed = false
        if let target {
            env.settings.updateTranslationSettings { $0.target = target }
        }
        let settings = env.settings.translationSettings
        let resolved = target ?? settings.target
        Task {
            await env.translation.translate(
                webView: webView,
                settings: settings,
                target: resolved
            )
        }
    }

    /// Saves the active page's archive, then reports the result in one line.
    func saveOfflinePage() {
        guard let tab = activeTab, !tab.isHome,
              let webView = tabManager.webView(for: tab.id) else { return }
        let urlString = tab.url
        let title = tab.title
        let favicon = tab.faviconUrl
        Task { @MainActor in
            let result = await env.offlinePages.save(
                webView: webView,
                urlString: urlString,
                title: title,
                faviconUrl: favicon
            )
            switch result {
            case .success:
                offlineNotice = "页面已保存，可以在离线页面中打开。"
            case let .failure(error):
                offlineNotice = error.localizedDescription
            }
        }
    }

    /// Opens a saved archive in a fresh tab.
    ///
    /// The archive is handed to the tab's web view directly; the tab then owns
    /// the document exactly as it owns a network page, so back/forward, find,
    /// reader and translation all keep working.
    func openOfflinePage(_ page: OfflinePageRecord) {
        showOfflinePages = false
        guard let url = URL(string: page.originalUrl) else {
            offlineNotice = "离线文件已丢失，请重新保存这个页面。"
            return
        }
        Task { @MainActor in
            guard let data = await env.offlinePages.archiveData(for: page) else {
                offlineNotice = "离线文件已丢失，请重新保存这个页面。"
                return
            }
            let tab = tabManager.createTab(openSource: .user)
            tabManager.loadOfflineArchive(
                data: data,
                baseURL: url,
                title: page.displayTitle,
                in: tab
            )
            env.offlinePages.markOpened(page)
        }
    }

}
