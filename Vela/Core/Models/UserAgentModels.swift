//
//  UserAgentModels.swift
//  Vela
//
//  The identifier presets the 网页标识 screen offers.
//
//  They live in Core rather than beside the screen because the tab's identity
//  is decided in Core: `BrowserUserAgent.identity` has to know whether a stored
//  string is one of these presets or a value the user typed, and the two are
//  treated differently on video sites. Keeping one list here is what lets both
//  sides agree.
//

import Foundation

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

    /// Whether a stored identifier is one of the presets above.
    static func isPreset(_ userAgent: String) -> Bool {
        all.contains { $0.userAgent == userAgent }
    }
}
