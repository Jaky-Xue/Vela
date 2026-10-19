//
//  UserAgentSettingsView.swift
//  Vela
//
//  The 网页标识 screen: desktop, mobile, and custom user-agent presets.
//

import SwiftUI
import UIKit

// MARK: - User agent

/// A user-agent preset the identifier screen offers.
///
/// `userAgent` is the literal string a page will receive; `nil` means the
/// default, which WebKit assembles from its own platform tokens and is the one
/// preset that never goes stale.
struct BrowserUserAgentPreset: Identifiable, Equatable {
    let id: String
    let title: String
    let userAgent: String?
    let isDesktop: Bool

    /// A one-line description of what the identifier claims — the device it
    /// pretends to be and the browser it says it is, read out of the string
    /// itself rather than written down beside it. A hand-written line can
    /// drift from the string it describes; this one is derived, so it cannot.
    ///
    /// The device half comes from the platform token in the first
    /// parentheses, the engine half from the browser token at the tail.
    var claimedSummary: String {
        guard let ua = userAgent, !ua.isEmpty else {
            return "由系统的 WebKit 现场生成，随 iOS 保持最新"
        }

        var device = ""
        if let open = ua.firstIndex(of: "("),
           let close = ua.firstIndex(of: ")"),
           open < close {
            let platform = String(ua[ua.index(after: open)..<close])
            let tokens = platform.split(separator: ";").map {
                String($0).trimmingCharacters(in: .whitespaces)
            }
            if tokens.first == "iPhone",
               let os = tokens.first(where: { $0.hasPrefix("CPU iPhone OS ") }) {
                let version = os
                    .replacingOccurrences(of: "CPU iPhone OS ", with: "")
                    .replacingOccurrences(of: " like Mac OS X", with: "")
                    .replacingOccurrences(of: "_", with: ".")
                device = "iPhone · iOS \(version)"
            } else if let os = tokens.first(where: { $0.hasPrefix("Android ") }) {
                let phone = tokens.last == os ? "" : tokens.last ?? ""
                device = phone.isEmpty ? os : "\(phone) · \(os)"
            } else if tokens.first == "Macintosh",
                      let os = tokens.first(where: { $0.contains("Mac OS X ") }) {
                let version = os.split(separator: " ").last
                    .map { String($0).replacingOccurrences(of: "_", with: ".") } ?? ""
                device = version.isEmpty ? "macOS" : "macOS \(version)"
            } else if let nt = tokens.first(where: { $0.hasPrefix("Windows NT ") }) {
                device = "Windows \(nt.dropFirst("Windows NT ".count))"
            }
        }

        // The most specific engine token wins: an Edge string carries Chrome's
        // token too, so Edge is checked before it.
        let engines: [(marker: String, name: String)] = [
            ("Edg/", "Edge"), ("Firefox/", "Firefox"), ("Chrome/", "Chrome"), ("Version/", "Safari")
        ]
        let engine = engines.lazy.compactMap { token -> String? in
            guard let range = ua.range(of: token.marker) else { return nil }
            let digits = ua[range.upperBound...].prefix { $0.isNumber || $0 == "." }
            guard let major = digits.split(separator: ".").first, !major.isEmpty else { return nil }
            return "\(token.name) \(major)"
        }.first

        return [device, engine].compactMap { $0 }.joined(separator: " · ")
    }

    static let all: [BrowserUserAgentPreset] = [
        BrowserUserAgentPreset(id: "default", title: "Vela 默认", userAgent: nil, isDesktop: false),
        BrowserUserAgentPreset(
            id: "safari-iphone", title: "Safari iPhone",
            userAgent: "Mozilla/5.0 (iPhone; CPU iPhone OS 26_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/26.0 Mobile/15E148 Safari/604.1",
            isDesktop: false
        ),
        BrowserUserAgentPreset(
            id: "chrome-android", title: "Chrome Android",
            userAgent: "Mozilla/5.0 (Linux; Android 16; Pixel 10) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/146.0.0.0 Mobile Safari/537.36",
            isDesktop: false
        ),
        BrowserUserAgentPreset(
            id: "chrome-windows", title: "Chrome Windows",
            userAgent: "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/146.0.0.0 Safari/537.36",
            isDesktop: true
        ),
        BrowserUserAgentPreset(
            id: "edge-windows", title: "Microsoft Edge Windows",
            userAgent: "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/146.0.0.0 Safari/537.36 Edg/146.0.0.0",
            isDesktop: true
        ),
        BrowserUserAgentPreset(
            id: "safari-macos", title: "Safari macOS",
            userAgent: "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/26.0 Safari/605.1.15",
            isDesktop: true
        ),
        BrowserUserAgentPreset(
            id: "firefox-windows", title: "Firefox Windows",
            userAgent: "Mozilla/5.0 (Windows NT 10.0; Win64; x64; rv:146.0) Gecko/20100101 Firefox/146.0",
            isDesktop: true
        )
    ]
}

struct UserAgentSettingsView: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.browserPalette) private var palette

    /// Flips on when the copy button is pressed, off again shortly after —
    /// the button's own confirmation.
    @State private var didCopyIdentity = false

    /// The preset currently in force: the match for the stored custom string,
    /// or the default when none is stored. A stored string that matches no
    /// preset was typed by hand and is reported as such.
    private var selectedPreset: BrowserUserAgentPreset? {
        let stored = env.settings.preferences.customUserAgent
        guard !stored.isEmpty else { return BrowserUserAgentPreset.all[0] }
        return BrowserUserAgentPreset.all.first { $0.userAgent == stored }
    }

    /// The name of what is in force. With the desktop-site toggle on and no
    /// preset chosen, the identity is Vela's default in its desktop form —
    /// saying just 「Vela 默认」 there would contradict the string below it.
    private var effectivePresetTitle: String {
        guard let preset = selectedPreset else { return "自定义" }
        if preset.id == BrowserUserAgentPreset.all[0].id,
           env.settings.preferences.customUserAgent.isEmpty,
           env.settings.preferences.desktopSiteByDefault {
            return "\(preset.title) · 桌面版"
        }
        return preset.title
    }

    /// The string the next request will actually carry, computed the way the
    /// web view computes it — through `BrowserUserAgent.identity`, which is
    /// the one place that answers the question. Reading the stored fields
    /// directly instead is what let this row show the mobile identifier while
    /// pages were receiving the desktop one.
    private var effectiveOutgoingIdentifier: String {
        let identity = BrowserUserAgent.identity(
            custom: env.settings.preferences.customUserAgent,
            prefersDesktop: env.settings.preferences.desktopSiteByDefault
        )
        return identity.customUserAgent
            ?? (env.settings.preferences.desktopSiteByDefault
                ? BrowserUserAgent.desktopIdentifier
                : BrowserUserAgent.mobileIdentifier)
    }

    var body: some View {
        List {
            Section {
                HStack {
                    Text("默认网页标识")
                    Spacer(minLength: 8)
                    Text(effectivePresetTitle)
                        .foregroundStyle(.secondary)
                }
            } footer: {
                Text("选择后，之后打开的页面都会以它出现。")
            }

            Section("移动端网页") {
                ForEach(BrowserUserAgentPreset.all.filter { !$0.isDesktop }) { preset in
                    presetRow(preset)
                }
            }

            Section("桌面端网页") {
                ForEach(BrowserUserAgentPreset.all.filter { $0.isDesktop }) { preset in
                    presetRow(preset)
                }
            }

            Section {
                TextField("自定义 User-Agent", text: Binding(
                    get: { env.settings.preferences.customUserAgent },
                    set: { value in
                        env.settings.update { $0.customUserAgent = value }
                        apply(reload: false)
                    }
                ), axis: .vertical)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .font(.system(size: 13, design: .monospaced))
                .lineLimit(3...6)

                Button("恢复默认") {
                    env.settings.update { $0.customUserAgent = "" }
                    apply(reload: true)
                }
            } header: {
                Text("自定义标识")
            } footer: {
                Text("填写后覆盖上面选择的预设。")
            }

            Section {
                Text(effectiveOutgoingIdentifier)
                    .font(.system(size: 12, design: .monospaced))
                    .textSelection(.enabled)
                    .foregroundStyle(palette.primaryText)
                    .frame(maxWidth: .infinity, alignment: .leading)

                Button {
                    UIPasteboard.general.string = effectiveOutgoingIdentifier
                    // The button is what confirms the copy; without a state
                    // change the tap reads as having done nothing.
                    didCopyIdentity = true
                    Task {
                        try? await Task.sleep(nanoseconds: 1_600_000_000)
                        didCopyIdentity = false
                    }
                } label: {
                    Label(
                        didCopyIdentity ? "已复制" : "复制标识",
                        systemImage: didCopyIdentity ? "checkmark" : "doc.on.doc"
                    )
                }
            } header: {
                Text("当前标识")
            } footer: {
                Text("这是下一个页面请求实际会携带的字符串。")
            }
        }
        .navigationTitle("网页标识")
        .navigationBarTitleDisplayMode(.inline)
    }

    /// One preset row with the reference screen's radio affordance: an empty
    /// ring for the choices not taken, a filled check for the one in force —
    /// and, under the title, what the identifier claims, so a choice can be
    /// read before it is taken rather than only after.
    private func presetRow(_ preset: BrowserUserAgentPreset) -> some View {
        let isSelected = selectedPreset?.id == preset.id
        return Button {
            env.settings.update { $0.customUserAgent = preset.userAgent ?? "" }
            apply(reload: true)
        } label: {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text(preset.title)
                        .foregroundStyle(palette.primaryText)
                    Text(preset.claimedSummary)
                        .font(.footnote)
                        .foregroundStyle(palette.secondaryText)
                        .lineLimit(1)
                }
                Spacer(minLength: 8)
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 20, weight: .light))
                    .foregroundStyle(isSelected ? Color.blue : Color.secondary.opacity(0.55))
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// Pushes the identifier onto every open tab, and reloads the active one when
    /// the change should be visible at once.
    ///
    /// A `User-Agent` only takes effect on the next request, so without this the
    /// screen would save a value that nothing reads until the user happened to
    /// navigate again — which is exactly how it behaved before.
    private func apply(reload: Bool) {
        env.tabManager.applyUserAgentToAllWebViews()
        guard reload, let tab = env.tabManager.activeTab else { return }
        _ = env.tabManager.reload(tab: tab)
    }
}
