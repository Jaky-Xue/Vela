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
    @Environment(\.horizontalSizeClass) private var sizeClass

    let provider: WebAccountProvider
    var onFinish: () -> Void

    @State private var isLoading = true
    @State private var keyboardVisible = false
    /// The docked keyboard's height in points, measured here rather than read
    /// from the keyboard safe area: SwiftUI's avoidance shrinks the layout by
    /// an amount that also covers the accessory bar, and shrinking the web
    /// view is exactly what re-flows the page.
    @State private var keyboardHeight: CGFloat = 0

    /// The window's size on iPad, in points. A size, not a maximum: the card
    /// keeps it while the keyboard is up so the page inside never re-flows.
    private static let cardSize = CGSize(width: 640, height: 620)

    /// A full-screen cover that *draws* the small window on iPad.
    ///
    /// It used to be a system sheet. UIKit moves a presented sheet up when a
    /// docked keyboard would cover its first responder, and with a web page
    /// inside that means the whole window jumps — the top slides under the
    /// status bar and the bottom disappears behind the keyboard. Shrinking the
    /// card instead, which an earlier build did, re-flows the page under the
    /// user's finger. So the card keeps one size and *rises*: it is centred in
    /// the part of the window the keyboard leaves free, and the web view's
    /// viewport never changes. On a phone the page keeps its viewport and
    /// scrolls under the keyboard, as Safari's does.
    var body: some View {
        Group {
            if sizeClass == .regular {
                GeometryReader { proxy in
                    let cardWidth = min(Self.cardSize.width, proxy.size.width - 88)
                    let cardHeight = min(Self.cardSize.height, proxy.size.height - 88)
                    // Centre the card in the space above the keyboard, but never
                    // push it past the window's top edge; whatever is left
                    // over is covered by the page's own scrolling.
                    let lift = min(keyboardHeight, max(0, proxy.size.height - cardHeight - 24))
                    ZStack {
                        Color.black.opacity(0.4).ignoresSafeArea()
                        signInPage
                            .frame(width: cardWidth, height: cardHeight)
                            .background(Color(uiColor: .systemBackground))
                            .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
                            .shadow(color: .black.opacity(0.4), radius: 34, y: 16)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .offset(y: -lift / 2)
                            .animation(.easeOut(duration: 0.24), value: lift)
                    }
                }
                .ignoresSafeArea(.keyboard, edges: .bottom)
            } else {
                signInPage
                    // A phone's page scrolls under the keyboard, the way
                    // Safari's does.
                    .ignoresSafeArea(.keyboard, edges: .bottom)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillChangeFrameNotification)) { note in
            keyboardHeight = dockedKeyboardHeight(from: note)
        }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardDidShowNotification)) { _ in
            keyboardVisible = true
        }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardDidHideNotification)) { _ in
            keyboardVisible = false
        }
        // The window is drawn over the screen it was opened from, as the
        // system sheet did — a cover's own background would black it out.
        .presentationBackground(.clear)
    }

    /// How much of the window a bottom-anchored keyboard covers.
    ///
    /// A floating keyboard is a panel the user can park anywhere; moving the
    /// window for it would be moving it for a corner. It has to touch the
    /// screen's bottom edge and span a good part of its width to count. iPadOS
    /// draws its keyboard a little narrower than the screen, which is why the
    /// width share here is a half rather than the near-everything the browser
    /// shell asks for.
    private func dockedKeyboardHeight(from notification: Notification) -> CGFloat {
        guard sizeClass == .regular,
              let value = notification
                  .userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? NSValue else { return 0 }
        // The window's frame, not the screen's: a window's frame is already in
        // the keyboard's coordinate space in every orientation, while a
        // screen's dimensions describe an iPad the window may not be using.
        let windows = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap { $0.windows }
        guard let window = windows.first(where: { $0.isKeyWindow }) ?? windows.first else { return 0 }
        let frame = value.cgRectValue
        let bounds = window.frame
        guard frame.maxY >= bounds.maxY - 1,
              frame.width >= bounds.width * 0.5 else { return 0 }
        return max(0, bounds.maxY - frame.minY)
    }

    private var signInPage: some View {
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
    }
}

/// The configuration the sign-in page runs in.
///
/// Deliberately bare, and the one place in the browser that must stay that
/// way: the browser's own coordinator carries the content blocker, the GM
/// bridge and every installed userscript, and none of them belongs on a
/// password form. The only script injected here is the appearance
/// stylesheet; the Safari tail is a header, not code.
///
/// It is a factory rather than a literal inside the view so a test can hold
/// this line — "the sign-in page injects nothing" is a promise that only a
/// test keeps true as the view grows.
enum LoginWebConfiguration {
    static func make() -> WKWebViewConfiguration {
        let configuration = WKWebViewConfiguration()
        configuration.applicationNameForUserAgent = BrowserUserAgent.safariTail
        configuration.websiteDataStore = .default()
        configuration.userContentController.addUserScript(WebPageScripts.makeAppearanceScript())
        return configuration
    }
}

/// The sign-in page itself.
///
/// A bare `WKWebView` on purpose: the browser's coordinator carries the
/// content blocker, page bridges and installed userscripts. It still reads
/// and writes the browser's own
/// cookie jar, which is the whole point.
///
/// It takes the system identity rather than the user's 网页标识 choice — a
/// sign-in form has no business claiming to be Chrome — but the Safari tail is
/// still appended. That tail is what makes the page see Safari rather than
/// WebKit's bare string, and a form that answers 「浏览器版本过低」 is a
/// sign-in the user cannot finish.
private struct LoginWebView: UIViewRepresentable {
    let url: URL
    let style: UIUserInterfaceStyle
    @Binding var isLoading: Bool

    func makeUIView(context: Context) -> LoginWebContainer {
        let configuration = LoginWebConfiguration.make()
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
    private var keyboardObserver: NSObjectProtocol?

    init(webView: WKWebView) {
        self.webView = webView
        super.init(frame: .zero)
        backgroundColor = .systemBackground

        addSubview(webView)
        webView.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            webView.topAnchor.constraint(equalTo: topAnchor),
            webView.leadingAnchor.constraint(equalTo: leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: trailingAnchor),
            webView.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])

        // The page keeps its viewport while the keyboard is up, and the
        // keyboard becomes a scroll inset the way Safari treats it. Pinning
        // the web view to `keyboardLayoutGuide.top` instead shrank the
        // viewport: every keyboard change re-flowed the document under the
        // finger, so Google's form jumped as soon as a field was focused and
        // an undocked keyboard looked like it was eating more of the page the
        // further it was dragged.
        keyboardObserver = NotificationCenter.default.addObserver(
            forName: UIResponder.keyboardWillChangeFrameNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            self?.applyKeyboardFrame(from: notification)
        }
    }

    required init?(coder: NSCoder) {
        return nil
    }

    deinit {
        if let keyboardObserver {
            NotificationCenter.default.removeObserver(keyboardObserver)
        }
    }

    /// Makes room for the keyboard without resizing the web view.
    ///
    /// Only a *docked* keyboard takes space: one that sits on the window's
    /// bottom edge and spans it. A floating iPad keyboard is a panel the user
    /// can put anywhere, and making the page give way to its top edge would
    /// lift a whole screen of content for a keyboard covering a corner — the
    /// same rule the browser's own shell applies. The scroll view's automatic
    /// adjustment already accounts for the bottom safe area, which a docked
    /// keyboard covers too, so that part is subtracted rather than counted
    /// twice.
    private func applyKeyboardFrame(from notification: Notification) {
        guard let value = notification
            .userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? NSValue else { return }
        let keyboardOnScreen = value.cgRectValue
        let inset: CGFloat
        if let window,
           isDocked(keyboardOnScreen, in: window) {
            let keyboard = convert(keyboardOnScreen, from: window.screen.coordinateSpace)
            let overlap = max(0, bounds.maxY - keyboard.minY)
            inset = max(0, overlap - safeAreaInsets.bottom)
        } else {
            inset = 0
        }
        let scrollView = webView.scrollView
        guard abs(scrollView.contentInset.bottom - inset) > 0.5 else { return }
        scrollView.contentInset.bottom = inset
        scrollView.verticalScrollIndicatorInsets.bottom = inset
    }

    /// Whether the keyboard is attached to the bottom of the window and covers
    /// it horizontally. The same test the shell's observers apply, so the two
    /// surfaces agree about what "the keyboard is up" means.
    private func isDocked(_ keyboardOnScreen: CGRect, in window: UIWindow) -> Bool {
        let windowOnScreen = window.convert(window.bounds, to: window.screen.coordinateSpace)
        let intersection = windowOnScreen.intersection(keyboardOnScreen)
        guard !intersection.isNull else { return false }
        return intersection.maxY >= windowOnScreen.maxY - 1
            && intersection.width >= windowOnScreen.width * 0.5
    }
}
