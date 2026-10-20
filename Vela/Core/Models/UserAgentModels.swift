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
import UIKit

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
            return "按当前设备自动选择：iPhone 手机版、iPad 平板版、Mac 桌面版"
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
        BrowserUserAgentPreset(
            id: "auto",
            title: "自动（跟随设备）",
            userAgent: nil,
            isDesktop: false
        ),
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

/// The User-Agent values presented to pages.
///
/// The identifier presented is Safari's, built from the running system's version
/// numbers, and the previous implementation got this wrong in two separate ways
/// that both produced the same complaint from sites — 「浏览器版本太低」:
///
/// * It hardcoded `Version/17.0`, so on any later iOS every site was told the
///   browser was Safari 17. The engine was current; only the label was stale, and
///   the label is the entire basis of the site's judgement.
/// * It wrote the whole string, including `AppleWebKit/605.1.15`. That token is
///   WebKit's, and writing it down is the same mistake one layer down — it would
///   go stale the day the engine's version token moves.
///
/// So only the tail is written here, and it is handed to WebKit through
/// `applicationNameForUserAgent`, which appends it to the identifier WebKit
/// builds for itself. On iOS 27 the platform token says `CPU iPhone OS 27_…` and
/// the WebKit token is whatever iOS 27 ships, without Vela knowing either.
///
/// Two tokens in the tail are fixed rather than derived, and both are
/// observations of what the system itself sends rather than version guesses:
/// `Mobile/15E148` appears verbatim in the identifier a bare `WKWebView` reports
/// on this platform (measured), and `Safari/604.1` is the token iOS Safari
/// appends. Neither is compared against a version by sites; `Version/` is, and
/// that one is derived.
///
/// A bare `WKWebView` sends neither `Version/` nor `Safari/` — they are tokens
/// Safari adds for itself — and a site that looks for them treats their absence
/// as an embedded browser and tells the user to go and open Safari. That is why
/// the tail cannot simply be omitted.

public enum BrowserUserAgent {
    /// The tail WebKit should append to its own identifier.
    public static var safariTail: String {
        "Version/\(operatingSystemVersion) Mobile/15E148 Safari/604.1"
    }

    /// How a tab should identify itself, given the user's settings — and the
    /// host it is about to open, which one family of sites branches on.
    public static func identity(
        custom: String,
        prefersDesktop: Bool,
        host: String? = nil
    ) -> BrowserWebIdentity {
        let trimmed = custom.trimmingCharacters(in: .whitespacesAndNewlines)

        // Video sites get an answer of their own, ahead of every preset and of
        // the desktop toggle; only a hand-typed identifier outranks it. YouTube
        // is the case that matters. Its player is built for the browser it
        // believes it is talking to, and every identity this app can claim is a
        // lie to it: the iPad and desktop identifiers land the desktop site and
        // its sign-in wall, and a preset that claims Chrome leaves the mobile
        // player's captions unrendered, because the renderer it selects expects
        // Chrome. The mobile Safari identifier is the one shape whose player,
        // playback and captions work on this engine.
        //
        // A preset is a choice of identity rather than a hand-written string,
        // so it yields here. A string the user typed is kept: that is the exact
        // value they asked for.
        if let host, isVideoSiteHost(host),
           trimmed.isEmpty || BrowserUserAgentPreset.isPreset(trimmed) {
            return BrowserWebIdentity(
                applicationNameForUserAgent: safariTail,
                customUserAgent: mobileIdentifier
            )
        }

        // Someone who typed a string asked for that exact value. Letting the
        // desktop toggle override it is what made the field look broken.
        if !trimmed.isEmpty {
            return BrowserWebIdentity(applicationNameForUserAgent: safariTail, customUserAgent: trimmed)
        }
        if prefersDesktop {
            return BrowserWebIdentity(
                applicationNameForUserAgent: safariTail,
                customUserAgent: desktopIdentifier
            )
        }
        // The default: no custom identifier at all, so WebKit appends the tail to
        // its own prefix and the result is what Safari would have sent on this
        // device.
        return BrowserWebIdentity(applicationNameForUserAgent: safariTail)
    }

    /// The video-site hosts that receive the mobile identifier.
    ///
    /// Domain-or-subdomain matching, the same shape the page scripts apply
    /// when they stand down for a site's own player.
    public static func isVideoSiteHost(_ host: String) -> Bool {
        let lowered = host.lowercased()
        let domains = ["youtube.com", "youtube-nocookie.com", "youtubekids.com", "youtu.be"]
        return domains.contains { lowered == $0 || lowered.hasSuffix(".\($0)") }
    }

    /// The identifier the running device should present by default.
    ///
    /// The automatic preset is the initial choice, and this is what makes it
    /// mean "the device you are holding": an iPhone claims a phone, an iPad a
    /// tablet, and a Mac a desktop. The default path still lets WebKit build
    /// its own identifier (which is the most current one); this value is used
    /// to show the user what that identifier is and as the base for the
    /// explicit presets.
    public static var deviceIdentifier: String {
        switch UIDevice.current.userInterfaceIdiom {
        case .pad:
            return padIdentifier
        case .mac:
            return desktopIdentifier
        default:
            return mobileIdentifier
        }
    }

    /// A complete iPad identifier, for the automatic tablet identity.
    public static var padIdentifier: String {
        "Mozilla/5.0 (iPad; CPU OS "
            + "\(operatingSystemVersion.replacingOccurrences(of: ".", with: "_")) like Mac OS X) "
            + "AppleWebKit/605.1.15 (KHTML, like Gecko) \(safariTail)"
    }

    /// A complete desktop identifier, for the "请求桌面网站" toggle.
    ///
    /// The whole string is written out here, unlike the mobile case, because a web
    /// view cannot be told to claim a different platform — the platform token is
    /// the one part of the identifier WebKit will not rewrite for us. So this one
    /// does contain written-down tokens: the Mac platform token (which is the lie
    /// the user asked for) and `AppleWebKit/605.1.15`, which is an approximation.
    ///
    /// That approximation is acceptable and the default path does not share it:
    /// sites compare the `Version/` token against a minimum, and that one is
    /// derived from the running system. If WebKit's own version token ever moves,
    /// desktop mode would be presenting the old one while the default path — the
    /// mobile identifier, assembled by WebKit from its own prefix — stays correct
    /// without a change here.
    public static var desktopIdentifier: String {
        desktopForm(of: mobileIdentifier)
    }

    /// The identifier a phone-sized tab presents, reconstructed.
    ///
    /// WebKit assembles the real one from its own prefix plus `safariTail`; this
    /// is that string written out. It is used as the base for the desktop form
    /// above, and the settings screen compares it against the identifier a real
    /// page reports so the two can be seen to agree.
    public static var mobileIdentifier: String {
        "Mozilla/5.0 (iPhone; CPU iPhone OS "
            + "\(operatingSystemVersion.replacingOccurrences(of: ".", with: "_")) like Mac OS X) "
            + "AppleWebKit/605.1.15 (KHTML, like Gecko) \(safariTail)"
    }

    /// `26.1`, as the system reports it.
    static var operatingSystemVersion: String {
        let version = ProcessInfo.processInfo.operatingSystemVersion
        return "\(version.majorVersion).\(version.minorVersion)"
    }

    /// Rewrites a mobile Safari identifier into a desktop one.
    ///
    /// Only the platform token and the `Mobile/` marker change. Rewriting the
    /// version tokens as well is how the identifier goes stale, so they are left
    /// describing the engine that is actually running.
    static func desktopForm(of identifier: String) -> String {
        var text = identifier

        // `(iPhone; CPU iPhone OS 26_1 like Mac OS X)` → a Mac platform token.
        // The group is what a site branches on to choose a layout; everything
        // after it describes WebKit, which is the same either way.
        if let start = text.range(of: "(iPhone;"),
           let end = text.range(of: ") ", range: start.upperBound..<text.endIndex) {
            text.replaceSubrange(start.lowerBound..<end.lowerBound, with: "(Macintosh; Intel Mac OS X 10_15_7")
        }

        // ` Mobile/15E148` is the marker that makes a string read as mobile, and
        // macOS Safari does not send it.
        if let start = text.range(of: " Mobile/"),
           let end = text.range(of: " ", range: start.upperBound..<text.endIndex) {
            text.removeSubrange(start.lowerBound..<end.lowerBound)
        }

        return text
    }
}
