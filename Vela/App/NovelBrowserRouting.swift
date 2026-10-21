//
//  NovelBrowserRouting.swift
//  Vela
//
//  Where a novel reader's "open in browser" action is allowed to land.
//
//  The reader is a window-level layer, so the active tab at the moment of the
//  action is not necessarily the tab the novel session came from. A private
//  reader must never hand its chapter URL to a regular tab: that would write
//  the private address into regular history and cookies. The decision is kept
//  here, as a pure value, so it can be tested without presenting the reader.
//

import Foundation

enum NovelBrowserTarget: Equatable {
    /// A tab that still exists and is the private session's source.
    case existingTab(String)
    /// No valid private source remains; open a fresh private tab.
    case newPrivateTab
    /// A regular reader keeps the pre-existing behaviour.
    case activeTab(String)
    /// A regular reader with no active tab gets a regular tab.
    case newRegularTab
    /// The session that requested the action has already ended.
    case refuse
}

enum NovelBrowserRouting {
    /// The target for a reader's open-in-browser action.
    ///
    /// A private session only accepts its own live private source tab, or a
    /// new private tab. It never falls back to the active tab, even when that
    /// tab is the only one on screen. A stale generation refuses outright.
    static func target(
        isPrivateSession: Bool,
        sessionGeneration: Int,
        currentGeneration: Int,
        sourceTabId: String,
        tabs: [(id: String, privacyMode: BrowserSessionPrivacyMode)],
        activeTabId: String?
    ) -> NovelBrowserTarget {
        if isPrivateSession {
            guard sessionGeneration == currentGeneration else { return .refuse }
            if let source = tabs.first(where: {
                $0.id == sourceTabId && $0.privacyMode == .private
            }) {
                return .existingTab(source.id)
            }
            return .newPrivateTab
        }

        if let activeTabId,
           tabs.contains(where: { $0.id == activeTabId }) {
            return .activeTab(activeTabId)
        }
        return .newRegularTab
    }
}
