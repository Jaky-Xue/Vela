//
//  NovelLoaderSupport.swift
//  Vela
//
//  The configuration and data-store choices the off-screen novel loaders use.
//
//  Both loaders fetch site pages in a WKWebView, so their data store decides
//  where the site's cookies, local storage and cache live. Ordinary reading
//  uses the default store — the session the user browsed with. Private reading
//  must use the window's private store instead, or the visit would write into
//  the regular profile. Keeping the choice here makes both loaders agree and
//  makes the decision testable without starting a load.
//

import Foundation
import WebKit

enum NovelLoaderConfiguration {
    /// The configuration both novel loaders use for their off-screen view.
    static func make(dataStore: WKWebsiteDataStore) -> WKWebViewConfiguration {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = dataStore
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true
        return configuration
    }
}

enum NovelLoaderDataStore {
    /// The store the chapter and TOC loaders should use for this session.
    ///
    /// The private expression is an autoclosure so a regular session never
    /// materialises the private store just to choose the default one.
    static func resolve(
        isPrivateSession: Bool,
        privateStore: @autoclosure () -> WKWebsiteDataStore
    ) -> WKWebsiteDataStore {
        isPrivateSession ? privateStore() : WKWebsiteDataStore.default()
    }
}

enum NovelReaderDisplayDataStore {
    /// The store the reader's local-HTML web view should use.
    ///
    /// Normal reading keeps the existing ephemeral store: the chapter is a
    /// local HTML string, and its absolute image URLs must not borrow the
    /// regular profile's cookies. Private reading uses the session's private
    /// store, so those subresources stay inside the same private session.
    static func resolve(
        isPrivateSession: Bool,
        privateStore: @autoclosure () -> WKWebsiteDataStore
    ) -> WKWebsiteDataStore {
        isPrivateSession ? privateStore() : WKWebsiteDataStore.nonPersistent()
    }
}
