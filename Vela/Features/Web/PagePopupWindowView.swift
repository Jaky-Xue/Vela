//
//  PagePopupWindowView.swift
//  Vela
//
//  The sheet that shows a window a page opened with `window.open`.
//
//  It hosts the very web view WebKit built for the page, so the opener link
//  and everything the page writes into the window come through untouched. A
//  tab built from Vela's own configuration would look the same and behave
//  differently: the page would be talking to a window nobody is showing.
//

import SwiftUI
import UIKit
import WebKit

struct PagePopupWindowView: View {
    let popup: PagePopupWindow
    var onClose: () -> Void

    var body: some View {
        NavigationStack {
            PopupWebView(webView: popup.webView)
                .ignoresSafeArea(edges: .bottom)
                .navigationTitle(title)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("关闭") { onClose() }
                    }
                }
        }
    }

    /// The window's own address, which is the one thing about it that says
    /// what it is for — a sign-in window names the identity provider, a
    /// message window names the site.
    private var title: String {
        guard let host = popup.webView.url?.host, !host.isEmpty else {
            return "弹出窗口"
        }
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }
}

/// Hands the page's own web view to SwiftUI without rebuilding it.
private struct PopupWebView: UIViewRepresentable {
    let webView: WKWebView

    func makeUIView(context: Context) -> WKWebView { webView }

    func updateUIView(_ uiView: WKWebView, context: Context) {}
}
