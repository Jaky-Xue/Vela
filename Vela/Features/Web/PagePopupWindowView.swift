//
//  PagePopupWindowView.swift
//  Vela
//
//  The window a page opened with `window.open`.
//
//  It is drawn as a window rather than as a full-screen sheet: the page asked
//  for a window of a particular size, and a sign-in provider draws its form
//  for exactly that size. Stretched across the screen, the form shrinks to a
//  card in the middle of its own empty background — the shape the provider
//  never designed for, and the shape every desktop browser avoids by opening
//  the size that was asked for.
//
//  The view hosts the very web view WebKit built for the page, so the opener
//  link and everything the page writes into the window come through
//  untouched. A tab built from Vela's own configuration would look the same
//  and behave differently: the page would be talking to a window nobody is
//  showing.
//

import SwiftUI
import UIKit
import WebKit

struct PagePopupWindowView: View {
    @Environment(\.browserPalette) private var palette

    let popup: PagePopupWindow
    var onClose: () -> Void

    var body: some View {
        GeometryReader { geometry in
            let size = Self.windowSize(for: popup.requestedSize, in: geometry.size)
            ZStack {
                // A window sits over its page, so the page stays visible
                // around it — dimmed only enough to read as being behind the
                // window, which is what keeps it clear whose sign-in this is.
                Color.black.opacity(0.22)
                    .ignoresSafeArea()
                    .onTapGesture(perform: onClose)

                VStack(spacing: 0) {
                    header
                    Divider()
                    PopupWebView(webView: popup.webView)
                }
                .frame(width: size.width, height: size.height)
                .background(palette.surface)
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .strokeBorder(palette.separator.opacity(0.55), lineWidth: 0.5)
                }
                .shadow(color: .black.opacity(0.38), radius: 30, y: 14)
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
        }
        .ignoresSafeArea()
    }

    private var header: some View {
        HStack(spacing: 10) {
            Text(title)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(palette.primaryText)
                .lineLimit(1)
                .truncationMode(.middle)

            Spacer(minLength: 8)

            Button(action: onClose) {
                Text("关闭")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(palette.secondaryText)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(palette.controlFill, in: Capsule())
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
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

    /// The window's size on screen: what the page asked for, clamped to the
    /// room there is. A page that asked for nothing gets a default window
    /// rather than the full screen.
    static func windowSize(for requested: CGSize?, in available: CGSize) -> CGSize {
        let preferred = requested ?? CGSize(width: 460, height: 620)
        let maximumWidth = max(280, available.width - 80)
        let maximumHeight = max(320, available.height - 140)
        return CGSize(
            width: min(max(preferred.width, 280), maximumWidth),
            height: min(max(preferred.height, 320), maximumHeight)
        )
    }
}

/// Hands the page's own web view to SwiftUI without rebuilding it.
private struct PopupWebView: UIViewRepresentable {
    let webView: WKWebView

    func makeUIView(context: Context) -> WKWebView { webView }

    func updateUIView(_ uiView: WKWebView, context: Context) {}
}
