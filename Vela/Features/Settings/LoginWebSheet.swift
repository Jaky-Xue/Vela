//
//  LoginWebSheet.swift
//  Vela
//
//  A provider's own sign-in page, in a small window.
//
//  A sheet rather than a tab opened behind the settings: the user asked to
//  sign in, and the page they asked for belongs in front of them, not behind
//  the sheet they are reading. The web view shares the browser's cookie jar
//  (`.default()`), so signing in here is signing in for the browser — the same
//  cookies the tabs use, and the same state 「退出所有账号」 clears.
//
//  Nothing is injected into this page: no user scripts, no page bridges. It is
//  a password form, and the browser's own plumbing has no business in it.
//

import SwiftUI
import WebKit

struct LoginWebSheet: View {
    @Environment(\.dismiss) private var dismiss

    let provider: WebAccountProvider
    var onFinish: () -> Void

    @State private var isLoading = true

    var body: some View {
        NavigationStack {
            Group {
                if let url = provider.signInURL {
                    ZStack {
                        LoginWebView(
                            url: url,
                            isLoading: $isLoading
                        )
                        if isLoading {
                            ProgressView()
                                .padding(14)
                                .background(
                                    .regularMaterial,
                                    in: RoundedRectangle(cornerRadius: 12, style: .continuous)
                                )
                        }
                    }
                } else {
                    Text("无法打开 \(provider.displayName) 的登录页。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .navigationTitle(provider.displayName)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") {
                        onFinish()
                        dismiss()
                    }
                }
            }
        }
        .presentationDetents([.large])
        .presentationCompactAdaptation(.fullScreenCover)
    }
}

/// The sign-in page itself.
///
/// A bare `WKWebView` on purpose: the browser's coordinator carries the
/// content blocker, the page bridges and the user-script worlds, none of which
/// may run on a password form. It still reads and writes the browser's own
/// cookie jar, which is the whole point.
private struct LoginWebView: UIViewRepresentable {
    let url: URL
    @Binding var isLoading: Bool

    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .default()
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        webView.uiDelegate = context.coordinator
        webView.allowsBackForwardNavigationGestures = true
        webView.scrollView.keyboardDismissMode = .interactive
        webView.load(URLRequest(url: url))
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        context.coordinator.parent = self
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate {
        var parent: LoginWebView

        init(parent: LoginWebView) {
            self.parent = parent
        }

        func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
            parent.isLoading = true
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            parent.isLoading = false
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            parent.isLoading = false
        }

        func webView(
            _ webView: WKWebView,
            didFailProvisionalNavigation navigation: WKNavigation!,
            withError error: Error
        ) {
            parent.isLoading = false
        }

        /// A link that asks for a new window — a help page, a recovery flow —
        /// stays in this one. Sign-in flows that lose their landing page are
        /// the usual cause of a window that never finishes.
        func webView(
            _ webView: WKWebView,
            createWebViewWith configuration: WKWebViewConfiguration,
            for navigationAction: WKNavigationAction,
            windowFeatures: WKWindowFeatures
        ) -> WKWebView? {
            if navigationAction.request.url != nil {
                webView.load(navigationAction.request)
            }
            return nil
        }
    }
}
