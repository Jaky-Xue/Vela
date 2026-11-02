//
//  BrowserShellView+OfflinePages.swift
//  Vela
//
//  The offline-page actions.
//
import SwiftUI
import UIKit
import WebKit

extension BrowserShellView {
    /// Opens settings, optionally on a named screen.
    ///
    /// One entry point so a context that names a screen can open it directly
    /// rather than the settings root, and so the root itself always clears a
    /// destination left over from the previous opening.
    func openSettings(_ destination: SettingsDestination? = nil) {
        settingsDestination = destination
        showSettings = true
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
    /// the document exactly as it owns a network page, so back/forward, find
    /// and reader all keep working.
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
