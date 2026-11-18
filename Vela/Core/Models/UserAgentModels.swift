//
//  UserAgentModels.swift
//  Vela
//
//  The identifier presets the 网页标识 screen offers.
//
//  They live in Core rather than beside the screen because the tab's identity
//  is decided in Core: `BrowserUserAgent.identity` has to know whether a stored
//  string is one of these presets or a value the user typed. A preset is a
//  choice of identity — "let the system say who I am", or "claim Chrome" — while
//  a typed value is the exact string to send. Keeping one list here is what lets
//  both sides agree.
//

import Foundation
import UIKit

/// The kind of device an identifier should describe.
///
/// The app's own rule, and the one the identifier screen's 自动 row promises:
/// a phone presents the phone's own page, an iPad presents the desktop page
/// the way a Mac does, and a Mac presents the desktop page. The iPad half is
/// deliberate. Tablet layouts are the narrowest branch of most sites' desktop
/// code and the one that ages worst; the desktop layout is the one the site's
/// authors actually test, and it is what a tablet can show in landscape.
///
/// It is a value rather than a read of `UIDevice` at every call site so a test
/// can say which device it is describing, and `current` is read once — the
/// idiom of a running app cannot change.
public enum BrowserDeviceClass: Sendable {
    case phone
    case pad
    case mac

    public static let current: BrowserDeviceClass = {
        switch UIDevice.current.userInterfaceIdiom {
        case .pad: return .pad
        case .mac: return .mac
        default: return .phone
        }
    }()

    /// Whether the automatic identity for this device is a desktop one.
    public var prefersDesktopIdentity: Bool {
        switch self {
        case .pad, .mac: return true
        case .phone: return false
        }
    }
}

/// A user-agent preset the identifier screen offers.
///
/// `userAgent` is what choosing the preset stores, and for the system presets it
/// is only a label: the resolver reads it back as "the system identity", not as
/// a string to send. The compatibility presets are the ones whose literal a page
/// actually receives. `nil` is the automatic choice, which follows the device.
struct BrowserUserAgentPreset: Identifiable, Equatable {
    let id: String
    let title: String
    let userAgent: String?
    let isDesktop: Bool

    var usesWebKitIdentity: Bool {
        id == "auto" || id.hasPrefix("safari-")
    }

    /// A one-line description of what the identifier claims — the device it
    /// pretends to be and the browser it says it is, read out of the string
    /// itself rather than written down beside it. A hand-written line can
    /// drift from the string it describes; this one is derived, so it cannot.
    ///
    /// The device half comes from the platform token in the first
    /// parentheses, the engine half from the browser token at the tail.
    var claimedSummary: String {
        guard let ua = userAgent, !ua.isEmpty else {
            return "按当前设备自动决定：iPhone 手机版，iPad 与 Mac 桌面版"
        }

        if usesWebKitIdentity {
            return isDesktop ? "由当前系统生成桌面版标识" : "由当前系统生成手机版标识"
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
            } else if tokens.first == "iPad",
                      let os = tokens.first(where: { $0.hasPrefix("CPU OS ") }) {
                let version = os
                    .replacingOccurrences(of: "CPU OS ", with: "")
                    .replacingOccurrences(of: " like Mac OS X", with: "")
                    .replacingOccurrences(of: "_", with: ".")
                device = "iPad · iPadOS \(version)"
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

    /// The presets the screen lists, newest first within each family.
    ///
    /// The two system presets name the string the current build would
    /// reconstruct, and that value is only ever a label: choosing one stores
    /// it, and the identity resolver reads it back as "let the system say who
    /// I am" rather than as a string to send. The compatibility presets are
    /// real overrides, so their versions are written down — and therefore
    /// have to be bumped with a release, which is what keeps a site that
    /// compares `Chrome/` against a minimum from answering
    /// 「浏览器版本过低」.
    static let all: [BrowserUserAgentPreset] = [
        BrowserUserAgentPreset(
            id: "auto",
            title: "自动（跟随设备）",
            userAgent: nil,
            isDesktop: false
        ),
        BrowserUserAgentPreset(
            id: "safari-iphone", title: "系统手机版",
            userAgent: BrowserUserAgent.mobileIdentifier,
            isDesktop: false
        ),
        BrowserUserAgentPreset(
            id: "safari-ipad", title: "系统手机版",
            userAgent: BrowserUserAgent.padIdentifier,
            isDesktop: false
        ),
        BrowserUserAgentPreset(
            id: "chrome-android", title: "Chrome Android",
            userAgent: "Mozilla/5.0 (Linux; Android 17; Pixel 11) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/158.0.0.0 Mobile Safari/537.36",
            isDesktop: false
        ),
        BrowserUserAgentPreset(
            id: "chrome-windows", title: "Chrome Windows",
            userAgent: "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/158.0.0.0 Safari/537.36",
            isDesktop: true
        ),
        BrowserUserAgentPreset(
            id: "edge-windows", title: "Microsoft Edge Windows",
            userAgent: "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/157.0.0.0 Safari/537.36 Edg/157.0.0.0",
            isDesktop: true
        ),
        BrowserUserAgentPreset(
            id: "safari-macos", title: "系统桌面版",
            userAgent: BrowserUserAgent.desktopIdentifier,
            isDesktop: true
        ),
        BrowserUserAgentPreset(
            id: "firefox-windows", title: "Firefox Windows",
            userAgent: "Mozilla/5.0 (Windows NT 10.0; Win64; x64; rv:160.0) Gecko/20100101 Firefox/160.0",
            isDesktop: true
        )
    ]

    /// The preset a stored string stands for — the current literals, and the
    /// strings earlier builds of this app wrote for the same choices.
    ///
    /// The system presets are not values a user types; they mean "let the
    /// system say what I am". Builds before 4.0.77 stored such a choice as a
    /// literal, and a literal carries the version it was written with: after
    /// an OS update it is exactly the stale label that sites reject with
    /// 「浏览器版本过低」. Recognising the shape — a Safari identifier with no
    /// other browser's token in it — is what lets those stored strings follow
    /// the system again instead of being sent verbatim forever.
    static func matching(_ stored: String) -> BrowserUserAgentPreset? {
        let trimmed = stored.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return all.first }
        if let exact = all.first(where: { $0.userAgent == trimmed }) { return exact }
        guard let family = systemSafariPresetID(for: trimmed) else { return nil }
        return all.first { $0.id == family }
    }

    /// The system preset a Safari-shaped identifier belongs to.
    ///
    /// A string that names another browser, or an Android device, is a
    /// compatibility choice and is kept exactly as the user gave it.
    static func systemSafariPresetID(for identifier: String) -> String? {
        let lowered = identifier.lowercased()
        guard lowered.contains("applewebkit/"),
              lowered.contains("version/"),
              lowered.contains("safari/") else { return nil }
        let foreign = [
            "chrome/", "crios/", "chromium", "edg/", "edgios/", "edga/",
            "firefox/", "fxios/", "opr/", "opera", "samsungbrowser",
            "micromessenger", "mqqbrowser", "qqbrowser", "ucbrowser",
            "baiduboxapp", "alipayclient", "weibo", "aweme", "android"
        ]
        guard !foreign.contains(where: lowered.contains) else { return nil }
        if lowered.contains("ipad") { return "safari-ipad" }
        if lowered.contains("iphone") || lowered.contains("ipod") { return "safari-iphone" }
        if lowered.contains("macintosh") { return "safari-macos" }
        return nil
    }
}

/// Resolves native WebKit display modes and explicit User-Agent overrides.
public enum BrowserUserAgent {
    /// The newest system version this build claims: `27.2`.
    ///
    /// `Version/` is the token sites compare against a minimum, and it is the
    /// one token a bare `WKWebView` does not send at all. An identifier that
    /// only ever reported the running system would still read as an old
    /// browser on a device left on an older iOS — which is the same complaint
    /// the hardcoded `Version/17.0` produced, arrived at from the other side.
    /// So the identifier claims the newest version this build knows: the
    /// running one when that is newer, this value otherwise. Bump it with
    /// each release; nothing else here has to change.
    public static let newestSystemVersion = "27.2"

    /// The version the identifier claims: the running system's when it is
    /// newer than `newestSystemVersion`, and `newestSystemVersion` otherwise.
    ///
    /// Read once — the system cannot change while the app is running, and this
    /// is asked for before every navigation and on every settings redraw.
    public static let claimedSystemVersion: String = {
        let running = ProcessInfo.processInfo.operatingSystemVersion
        let text = "\(running.majorVersion).\(running.minorVersion)"
        return isVersion(text, newerThan: newestSystemVersion) ? text : newestSystemVersion
    }()

    /// The same version in the platform token's spelling: `27_2`.
    static let claimedSystemToken = claimedSystemVersion.replacingOccurrences(
        of: ".", with: "_"
    )

    /// What WebKit appends to the identifier it builds for itself.
    ///
    /// A bare `WKWebView` sends neither `Version/` nor `Safari/` — they are
    /// tokens Safari adds for itself — and a site that looks for them treats
    /// their absence as an embedded browser: the other way a site tells the
    /// user to go and open Safari, and one of the ways it answers
    /// 「浏览器版本过低」. Dropping this tail is what produced the complaint
    /// this build fixes.
    ///
    /// `Mobile/15E148` is repeated here on purpose: it is the token WebKit's
    /// own string already ends with, and Safari's order
    /// (`Version/ … Mobile/ … Safari/`) is the one parsers expect to find.
    /// The tail is carried by every identity, including a compatibility
    /// override — WebKit ignores it while an override is set, and it is what
    /// the tab falls back to when the override is cleared.
    public static let safariTail = "Version/\(claimedSystemVersion) Mobile/15E148 Safari/604.1"

    /// What a desktop page appends: macOS Safari's shape, which carries no
    /// `Mobile/` marker — that token is what makes a string read as mobile.
    /// An iPad's automatic identity uses this one, because the page WebKit
    /// shows there is already the desktop one and a mobile tail would claim
    /// otherwise.
    public static let desktopSafariTail = "Version/\(claimedSystemVersion) Safari/605.1.15"

    /// Resolves WebKit's content mode and any explicitly chosen User-Agent.
    public static func identity(
        custom: String,
        prefersDesktop: Bool,
        host: String? = nil,
        device: BrowserDeviceClass = .current,
        siteMode: BrowserSiteDisplayMode? = nil
    ) -> BrowserWebIdentity {
        if let siteMode {
            return systemIdentity(desktop: siteMode == .desktop)
        }

        let trimmed = custom.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            let isDesktop = prefersDesktop || device.prefersDesktopIdentity
            // The automatic identity leaves the string to WebKit on both
            // layouts — on an iPad that is already the desktop page — and adds
            // only the Safari tokens. Only an explicit desktop choice (the
            // 系统桌面版 preset, a site's 桌面网站) sends the reconstructed Mac
            // string, because that one has to be swappable while the tab stays
            // open and WebKit's own identifier cannot be talked into a Mac
            // platform token.
            return BrowserWebIdentity(
                applicationNameForUserAgent: isDesktop ? desktopSafariTail : safariTail,
                isDesktop: isDesktop,
                usesRecommendedContentMode: !prefersDesktop
            )
        }

        // A stored system preset — or a literal an earlier build wrote for one
        // — is not a string to send: it means "let the system say who I am",
        // at the newest version this build knows.
        let preset = BrowserUserAgentPreset.matching(trimmed)
        if let preset, preset.usesWebKitIdentity {
            return systemIdentity(desktop: preset.isDesktop)
        }

        // Someone who typed a string asked for that exact value, and the
        // layout follows the platform that string claims.
        return BrowserWebIdentity(
            applicationNameForUserAgent: safariTail,
            customUserAgent: trimmed,
            isDesktop: preset?.isDesktop ?? isDesktopIdentifier(trimmed, device: device)
        )
    }

    /// One system identity: what the browser claims and how the page is laid
    /// out, in the two halves the architecture separates.
    ///
    /// An explicit mobile choice sets no override at all, so WebKit builds the
    /// whole string from its own platform and engine tokens and the automatic
    /// identity's Safari tail is appended to that. An explicit desktop choice
    /// has to name the Mac platform token — WebKit will not rewrite that half
    /// of the identifier for us — so it presents the reconstructed desktop
    /// string instead. That string is assigned per navigation like any other
    /// override, which is what lets a tab move between 手机 and 桌面 on the
    /// same site without the tail and the layout falling out of step.
    static func systemIdentity(
        desktop: Bool,
        usesRecommendedContentMode: Bool = false
    ) -> BrowserWebIdentity {
        BrowserWebIdentity(
            applicationNameForUserAgent: safariTail,
            customUserAgent: desktop ? desktopIdentifier : nil,
            isDesktop: desktop,
            usesRecommendedContentMode: usesRecommendedContentMode
        )
    }

    /// Whether `lhs` names a newer version than `rhs`, compared component by
    /// component so `27.10` ranks above `27.2` rather than below it.
    static func isVersion(_ lhs: String, newerThan rhs: String) -> Bool {
        let left = lhs.split(separator: ".").map { Int($0) ?? 0 }
        let right = rhs.split(separator: ".").map { Int($0) ?? 0 }
        for index in 0..<max(left.count, right.count) {
            let lhsPart = index < left.count ? left[index] : 0
            let rhsPart = index < right.count ? right[index] : 0
            if lhsPart != rhsPart { return lhsPart > rhsPart }
        }
        return false
    }

    /// Whether a hand-typed identifier describes a desktop browser.
    ///
    /// The layout follows the string now, so a typed value has to answer the
    /// question itself. The platform token is the signal; a string carrying
    /// none falls back to the device's automatic answer rather than guessing.
    public static func isDesktopIdentifier(
        _ identifier: String,
        device: BrowserDeviceClass = .current
    ) -> Bool {
        let lowered = identifier.lowercased()
        if lowered.contains("iphone") || lowered.contains("ipad")
            || lowered.contains("android") || lowered.contains("mobile") {
            return false
        }
        if lowered.contains("macintosh") || lowered.contains("windows nt")
            || lowered.contains("x11") || lowered.contains("cros")
            || lowered.contains("linux") {
            return true
        }
        return device.prefersDesktopIdentity
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
    /// mean "the device you are holding": an iPhone claims a phone, and an
    /// iPad claims a Mac — the desktop identity its automatic mode uses. The
    /// phone default path still lets WebKit build its own identifier and adds
    /// only the Safari tail; this value is used to show the user what that
    /// identifier claims and as the base for the explicit presets.
    public static var deviceIdentifier: String {
        BrowserDeviceClass.current.prefersDesktopIdentity ? desktopIdentifier : mobileIdentifier
    }

    /// A complete iPad identifier, for the explicit iPad preset.
    ///
    /// It is no longer the automatic identity on an iPad — that is the desktop
    /// one — but it stays available for a site whose tablet layout is what the
    /// user wants.
    public static let padIdentifier = "Mozilla/5.0 (iPad; CPU OS "
        + "\(claimedSystemToken) like Mac OS X) "
        + "AppleWebKit/605.1.15 (KHTML, like Gecko) \(safariTail)"

    /// A complete desktop identifier, for the desktop preset and for reading
    /// back what a desktop identity claims.
    ///
    /// The whole string is written out because a web view cannot be told to
    /// claim a different platform — the platform token is the one part of the
    /// identifier WebKit will not rewrite for us — so this is what a desktop
    /// identity actually sends. The version tokens in it are the claimed ones,
    /// not numbers written down when the string was authored, so a desktop
    /// page is never told it is running last year's Safari.
    public static let desktopIdentifier: String = desktopForm(of: mobileIdentifier)

    /// The identifier a phone-sized tab claims, reconstructed.
    ///
    /// WebKit assembles the real one from its own prefix; this is that string
    /// written out, with the Safari tokens the system identity appends. It is
    /// used as the base for the desktop form above, as the iPhone preset's
    /// stored value, and on the settings screen as the description of what a
    /// system identity claims.
    ///
    /// A constant because every token in it is fixed for the life of the
    /// process; the identity is read before every navigation and on every
    /// settings redraw, and rebuilding the string there bought nothing.
    public static let mobileIdentifier = "Mozilla/5.0 (iPhone; CPU iPhone OS "
        + "\(claimedSystemToken) like Mac OS X) "
        + "AppleWebKit/605.1.15 (KHTML, like Gecko) \(safariTail)"

    /// Rewrites a mobile Safari identifier into a desktop one.
    ///
    /// Only the platform token and the `Mobile/` marker change. The version
    /// tokens are already the claimed ones, so they are carried over as they
    /// are — rewriting them here is how the two forms drift apart.
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
