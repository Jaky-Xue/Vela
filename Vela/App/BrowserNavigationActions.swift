//
//  BrowserNavigationActions.swift
//  Vela
//
//  The navigation decisions every entry point shares.
//
//  The toolbar, the menu, the hardware-keyboard commands and the overview all
//  spell "go back", "reload" and "open the home tab" at their own call sites.
//  Those spellings had drifted: the back button used WebKit, the menu's 主页
//  created a tab, and an empty back list meant different things on different
//  paths. The decisions live here as one value with one set of rules; the shell
//  keeps only the view state each decision leaves behind.
//

import Foundation
import UIKit

@MainActor
struct BrowserNavigationActions {
    enum BackStep: Equatable {
        /// There was no tab to act on.
        case none
        /// WebKit moved back; nothing else to do.
        case webView
        /// WebKit had nothing behind the page; activate the tab that opened it.
        case opener(String)
        /// The tab is on its native home surface; return it to the page it keeps.
        case returnToPage
        /// Nothing behind the page and no opener; leave it on the home surface.
        case home
    }

    let tabManager: TabManager
    let webCoordinator: BrowserWebCoordinator

    func backStep(for tab: BrowserTabState?) -> BackStep {
        guard let tab else { return .none }
        if tab.isHome { return .returnToPage }
        if webCoordinator.goBack() { return .webView }
        if !tab.openerTabId.isEmpty,
           tabManager.tabs.contains(where: { $0.id == tab.openerTabId }) {
            return .opener(tab.openerTabId)
        }
        return .home
    }

    @discardableResult
    func reload(_ tab: BrowserTabState?) -> Bool {
        guard let tab else { return false }
        return tabManager.reload(tab: tab)
    }

    /// Opens the start page as its own tab, unless the active tab is already
    /// that surface.
    @discardableResult
    func openHomeTab(from activeTab: BrowserTabState?) -> BrowserTabState? {
        guard activeTab?.isHome != true else { return nil }
        return tabManager.createTab(openSource: .user)
    }
}
