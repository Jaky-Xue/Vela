//
//  PagePopupWindow.swift
//  Vela
//
//  A window a page opened with `window.open`.
//
//  A `window.open` the browser answers with nil is a popup the page believes
//  was blocked: no handle comes back, so everything the page planned for that
//  window — a sign-in flow it watches for the redirect, a message window it
//  writes into, the `postMessage` it expects on the way back — never happens.
//  The page then either waits forever on a spinner or draws its own in-page
//  imitation of the dialog it asked for, which is the half-painted block a
//  clipped popup leaves behind.
//
//  WebKit keeps the opener link only between a page and a web view built from
//  the configuration it hands the delegate at `createWebViewWith`, so the
//  window is that web view, held here and shown over the page. Building a tab
//  from Vela's own configuration instead would lose the link, which is the
//  other half of the same bug.
//

import CoreGraphics
import Foundation
import WebKit

/// One window a page opened, waiting for the shell to show it.
public struct PagePopupWindow: Identifiable {
    public let id = UUID()
    /// The tab the window belongs to. Empty when the opener was itself a
    /// window; the shell still shows it, it just has no tab to report to.
    public let openerTabId: String
    /// The web view WebKit asked for. It is created from the configuration
    /// handed to `createWebViewWith`, which is what carries the opener link.
    public let webView: WKWebView
    /// The size the page asked for in its `window.open` feature string, left
    /// exactly as asked. The window is drawn at this size — a sign-in window
    /// is built for 400 by 600, and stretching it across the screen is what
    /// turned the provider's whole page into one small card in a field of
    /// empty background. `nil` means the page asked for no particular size,
    /// which gets the browser's own default window.
    public let requestedSize: CGSize?

    public init(openerTabId: String, webView: WKWebView, requestedSize: CGSize?) {
        self.openerTabId = openerTabId
        self.webView = webView
        self.requestedSize = requestedSize
    }
}
