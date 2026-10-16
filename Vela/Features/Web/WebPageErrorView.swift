//
//  WebPageErrorView.swift
//  Vela
//
//  What a tab shows when a navigation failed.
//
//  Before this existed the failure was recorded on the tab and rendered
//  nowhere: a site that could not be reached produced a blank white rectangle
//  with no reason, no address and nothing to press. That is the worst possible
//  answer, because it is indistinguishable from the browser itself being
//  broken — which is exactly how it was reported.
//
//  Two things it deliberately is not:
//
//    * It is not shown for a *cancelled* navigation. A redirect, a declined
//      `target="_blank"` and the stop button all cancel a navigation, and none
//      of them is a failure the user needs to hear about.
//    * It is not shown for an HTTP error response. A 404 or a 500 is a document
//      the server sent and WebKit rendered; the server's own page is the right
//      thing on screen, and `ServerStatusNotice` says so in one line instead of
//      replacing it.
//

import SwiftUI
import UIKit

/// The failure surface for a tab.
struct WebPageErrorView: View {
    var failure: TabNavigationFailure
    /// Whether the tab has history behind it, which is what decides if "返回上一页"
    /// is offered.
    var canGoBack: Bool
    var onReload: () -> Void
    var onGoBack: () -> Void
    var onCopyAddress: () -> Void
    var onHome: () -> Void

    @Environment(\.browserPalette) private var palette
    /// Set once the address has been copied, so the button can confirm it worked
    /// rather than looking like it did nothing.
    @State private var didCopy = false

    var body: some View {
        VStack(spacing: BrowserSpacing.regular) {
            Spacer(minLength: 0)

            Image(systemName: symbolName)
                .font(.system(size: 30, weight: .regular))
                .foregroundStyle(palette.secondaryText)
                .frame(width: 64, height: 64)
                .background(palette.controlFill, in: Circle())

            VStack(spacing: BrowserSpacing.tight) {
                Text(failure.title)
                    .font(.headline)
                    .foregroundStyle(palette.primaryText)
                    .multilineTextAlignment(.center)

                if !displayHost.isEmpty {
                    Text(displayHost)
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(palette.secondaryText)
                        .lineLimit(2)
                        .multilineTextAlignment(.center)
                }

                if !failure.detail.isEmpty {
                    Text(failure.detail)
                        .font(.footnote)
                        .foregroundStyle(palette.secondaryText)
                        .multilineTextAlignment(.center)
                        .padding(.top, BrowserSpacing.hairline)
                }
            }
            .padding(.horizontal, BrowserSpacing.loose)

            // The full address, so the user can see what was actually asked for
            // — including the parts the headline's host does not show, which is
            // usually what is wrong with it.
            if !failure.url.isEmpty {
                Text(failure.url)
                    .font(.caption.monospaced())
                    .foregroundStyle(palette.secondaryText.opacity(0.85))
                    .lineLimit(2)
                    .truncationMode(.middle)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, BrowserSpacing.loose)
                    .textSelection(.enabled)
            }

            Spacer(minLength: 0)

            VStack(spacing: BrowserSpacing.compact) {
                if failure.isRetryable {
                    Button(action: onReload) {
                        Label("重新载入", systemImage: "arrow.clockwise")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(palette.accent)
                }

                HStack(spacing: BrowserSpacing.compact) {
                    if canGoBack {
                        Button(action: onGoBack) {
                            Label("返回上一页", systemImage: "chevron.backward")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)
                    }

                    if !failure.url.isEmpty {
                        Button(action: copyAddress) {
                            Label(didCopy ? "已复制" : "复制网址",
                                  systemImage: didCopy ? "checkmark" : "doc.on.doc")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)
                    }
                }

                Button("返回主页", action: onHome)
                    .font(.footnote)
                    .foregroundStyle(palette.secondaryText)
                    .padding(.top, BrowserSpacing.hairline)
            }
            .padding(.horizontal, BrowserSpacing.loose)
            .padding(.bottom, BrowserSpacing.loose)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(palette.surface)
    }

    private func copyAddress() {
        UIPasteboard.general.string = failure.url
        didCopy = true
        Task {
            try? await Task.sleep(for: .seconds(2))
            didCopy = false
        }
    }

    /// The host, which is the part of the address a person recognises. Falls back
    /// to the whole string when there is no host — a `file:` URL or a typo'd
    /// scheme has none.
    private var displayHost: String {
        guard let host = URL(string: failure.url)?.host, !host.isEmpty else {
            return failure.url
        }
        return host
    }

    private var symbolName: String {
        switch failure.kind {
        case .offline: return "wifi.slash"
        case .dns: return "questionmark.circle"
        case .timeout: return "clock.badge.exclamationmark"
        case .refused, .connectionLost: return "bolt.horizontal.circle"
        case .emptyResponse: return "rectangle.slash"
        case .tls: return "lock.trianglebadge.exclamationmark"
        case .crashed: return "exclamationmark.triangle"
        case .cancelled: return "xmark.circle"
        case .httpStatus: return "server.rack"
        case .invalidUrl: return "text.badge.xmark"
        case .other: return "exclamationmark.circle"
        }
    }
}

/// A one-line notice that the server answered with an error status.
///
/// Shown *over* the document rather than instead of it, because the document is
/// the server's own error page and is usually more useful than anything Vela
/// could say. A 404 is not a connection failure, and treating it as one is how a
/// browser ends up hiding a page it received perfectly well.
struct ServerStatusNotice: View {
    var status: Int
    var onDismiss: () -> Void

    @Environment(\.browserPalette) private var palette

    var body: some View {
        HStack(spacing: BrowserSpacing.tight) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.caption)
            Text("服务器返回 \(status)")
                .font(.caption.weight(.medium))
            Spacer(minLength: 0)
            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .font(.caption2.weight(.bold))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("关闭提示")
        }
        .foregroundStyle(palette.primaryText)
        .padding(.horizontal, BrowserSpacing.compact)
        .padding(.vertical, BrowserSpacing.tight)
        .background(palette.controlFill, in: Capsule())
        .padding(.horizontal, BrowserChrome.sideInset)
        .accessibilityElement(children: .combine)
    }
}
