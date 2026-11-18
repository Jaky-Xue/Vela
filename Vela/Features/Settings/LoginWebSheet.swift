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
//  The only injected code is the browser's visual appearance stylesheet.
//  Sign-in pages have no userscript or message bridge.
//

import SwiftUI
import UIKit
import WebKit

struct LoginWebSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme

    let provider: WebAccountProvider
    var onFinish: () -> Void

    @State private var isLoading = true
    @State private var keyboardVisible = false

    var body: some View {
        NavigationStack {
            Group {
                if let url = provider.signInURL {
                    ZStack {
                        LoginWebView(
                            url: url,
                            style: colorScheme == .dark ? .dark : .light,
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
                ToolbarItem(placement: .topBarLeading) {
                    if keyboardVisible {
                        Button("收起键盘", systemImage: "keyboard.chevron.compact.down") {
                            UIApplication.shared.sendAction(
                                #selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil
                            )
                        }
                        .labelStyle(.iconOnly)
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") {
                        onFinish()
                        dismiss()
                    }
                }
            }
        }
        .ignoresSafeArea(.keyboard, edges: .bottom)
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardDidShowNotification)) { _ in
            keyboardVisible = true
        }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardDidHideNotification)) { _ in
            keyboardVisible = false
        }
        .presentationDetents([.large])
        .presentationCompactAdaptation(.fullScreenCover)
    }
}

/// The sign-in page itself.
///
/// A bare `WKWebView` on purpose: the browser's coordinator carries the
/// content blocker, page bridges and installed userscripts. It still reads
/// and writes the browser's own
/// cookie jar, which is the whole point.
private struct LoginWebView: UIViewRepresentable {
    let url: URL
    let style: UIUserInterfaceStyle
    @Binding var isLoading: Bool

    func makeUIView(context: Context) -> LoginWebContainer {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .default()
        configuration.userContentController.addUserScript(WebPageScripts.makeAppearanceScript())
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.overrideUserInterfaceStyle = style
        webView.backgroundColor = .systemBackground
        webView.navigationDelegate = context.coordinator
        webView.uiDelegate = context.coordinator
        webView.allowsBackForwardNavigationGestures = true
        webView.scrollView.keyboardDismissMode = .interactive
        webView.load(URLRequest(url: url))
        return LoginWebContainer(webView: webView)
    }

    func updateUIView(_ container: LoginWebContainer, context: Context) {
        context.coordinator.parent = self
        if container.webView.overrideUserInterfaceStyle != style {
            container.webView.overrideUserInterfaceStyle = style
        }
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


private final class LoginWebContainer: UIView {
    let webView: WKWebView

    init(webView: WKWebView) {
        self.webView = webView
        super.init(frame: .zero)
        backgroundColor = .systemBackground
        keyboardLayoutGuide.followsUndockedKeyboard = false
        keyboardLayoutGuide.usesBottomSafeArea = false

        addSubview(webView)
        webView.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            webView.topAnchor.constraint(equalTo: topAnchor),
            webView.leadingAnchor.constraint(equalTo: leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: trailingAnchor),
            webView.bottomAnchor.constraint(equalTo: keyboardLayoutGuide.topAnchor)
        ])
    }

    required init?(coder: NSCoder) {
        return nil
    }
}
