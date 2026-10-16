//
//  AddressBarView.swift
//  Vela
//
//  The address-input logic that is *not* a view: the URL-versus-query
//  resolver, and the progress ring the tab overview draws.
//
//  The resolver lives outside the omnibox even though it is what the omnibox
//  mostly does, because the new-tab home and the shell's navigation path both
//  call it. The rest of the address bar is elsewhere:
//
//    * the bar itself is `UI/Omnibox/OmniboxView.swift`,
//    * the suggestion list is `UI/Omnibox/OmniboxSuggestionListView.swift`,
//    * the engine and the session are `UI/Omnibox/OmniboxViewModel.swift`,
//    * the value types are `UI/Omnibox/OmniboxModels.swift`.
//

import SwiftUI
import UIKit

/// Why an omnibox submission was not turned into a navigation.
///
/// A rejection is a value rather than a silent `nil` so the shell can say what
/// happened. An address bar that swallows an input the user meant something by
/// is indistinguishable from one that is broken.
enum AddressBarRejection: Equatable {
    case empty
    /// A scheme Vela will not open from the address bar: `file:`, `data:`,
    /// `javascript:` and the like.
    case unsupportedScheme(String)
    /// The configured search engine's template cannot express a query, so there
    /// is neither an address nor a search to fall back to.
    case noUsableSearchEngine
}

/// What an omnibox submission should do.
enum AddressBarResolution: Equatable {
    /// Load it in the current tab.
    case navigate(URL)
    /// A scheme that belongs to another app; hand it to the system.
    case handOff(URL)
    /// Send the text to the configured search engine.
    case search(URL)
    case rejected(AddressBarRejection)
}

/// Turns typed text into a URL, or decides it is a query.
///
/// `BrowserAddressDisplayCoordinator`. The rules, in order:
///
/// * An input with a scheme Vela can load is a URL.
/// * `about:blank` is a URL; every other `about:` is not.
/// * A scheme belonging to another app is handed to the system.
/// * A scheme Vela will not open — `file:`, `data:`, `javascript:` — is
///   refused, and the refusal is reported rather than searched for.
/// * An input with no spaces that contains a dot and a plausible TLD is a URL,
///   with `https://` assumed.
/// * A bare localhost or an IP address is a URL.
/// * Anything else is a search query.
enum BrowserUrlResolver {
    /// Schemes the address bar navigates to.
    ///
    /// Deliberately only these two. `file:` reaches nothing a browser on iOS can
    /// show — the app's own container is the only place it resolves — and
    /// `data:` renders markup the user did not type under a URL that appears to
    /// have come from the address bar, which is the shape of a phishing page.
    /// Neither is something someone types on purpose.
    ///
    /// This constrains the *address bar*, not WebKit. A page may still use
    /// `data:`, `blob:` and `file:` and they load normally; see
    /// `BrowserWebCoordinator.internalSchemes`. Typing one is a different act
    /// from a page asking for one.
    private static let navigableSchemes: Set<String> = ["http", "https"]

    /// The one `about:` URL the address bar accepts: the empty document, which is
    /// what typing `about:blank` asks for.
    static let blankPageUrl = "about:blank"

    /// Schemes that are meaningful but are handed to the system rather than
    /// loaded, so typing one does not produce a blank page.
    static let externalSchemes: Set<String> = [
        "mailto", "tel", "sms", "facetime", "itms-apps", "alipays", "weixin", "taobao", "mqq"
    ]

    /// Schemes the address bar refuses outright.
    ///
    /// `ftp` is here because WebKit on iOS cannot load it: passing it through
    /// would produce a navigation that always fails, when saying "this address
    /// cannot be opened" is both true and immediate.
    private static let refusedSchemes: Set<String> = [
        "file", "data", "javascript", "blob", "vbscript", "ftp", "about", "ws", "wss", "chrome"
    ]

    /// The URL an input resolves to, when it resolves to one.
    ///
    /// This answers "is this an address rather than a search", which is what the
    /// omnibox's first suggestion row needs. What to *do* with the answer is
    /// `resolve(_:searchEngine:)`.
    static func resolveDirectUrl(_ input: String) -> URL? {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        // Any interior whitespace makes this a phrase rather than an address. A
        // host cannot contain a space, so a URL with one in it is a typo the user
        // wants searched, not a malformed request to fail on.
        guard !trimmed.contains(where: { $0.isWhitespace }) else { return nil }

        // An explicit scheme wins outright, whether or not it carries an
        // authority.
        //
        // The `://` spelling is the common one but not the only one: `mailto:`,
        // `tel:` and `sms:` are written without it, and an address bar that only
        // recognised the authority form would send every one of them to the
        // search engine — so the "email this" link the user copied would become a
        // search for the literal text of the address.
        if let scheme = scheme(of: trimmed) {
            if navigableSchemes.contains(scheme) {
                return httpUrl(trimmed)
            }
            if trimmed.lowercased() == blankPageUrl {
                return URL(string: blankPageUrl)
            }
            if externalSchemes.contains(scheme) {
                return URL(string: trimmed)
            }
            if refusedSchemes.contains(scheme) {
                return nil
            }
            // A scheme Vela does not know is not a scheme as far as the address
            // bar is concerned. `localhost:8080` and `192.168.1.1:3000` both land
            // here — neither word is a real scheme, but both parse as one — and
            // both are hosts, so the checks below decide.
        }

        // Strip a trailing slash-only path for the checks below.
        let candidate = trimmed.hasSuffix("/") ? String(trimmed.dropLast()) : trimmed
        guard !candidate.isEmpty else { return nil }

        // localhost and port, e.g. `localhost:8080` or `127.0.0.1:3000`.
        let hostPart = candidate.split(separator: "/").first.map(String.init) ?? candidate
        let hostWithoutPort = hostPart.split(separator: ":").first.map(String.init) ?? hostPart

        if hostWithoutPort == "localhost" { return httpUrl("http://\(candidate)") }
        if isIPv4(hostWithoutPort) { return httpUrl("http://\(candidate)") }
        // A bracketed IPv6 literal.
        if hostWithoutPort.hasPrefix("[") && hostWithoutPort.hasSuffix("]") {
            return httpUrl("http://\(candidate)")
        }

        guard hostWithoutPort.contains(".") else { return nil }
        // Reject a trailing dot or a leading dot, which are typos rather than
        // hosts, and reject a "TLD" of digits (a version number, not a domain).
        guard !hostWithoutPort.hasPrefix("."), !hostWithoutPort.hasSuffix(".") else { return nil }
        let tld = hostWithoutPort.split(separator: ".").last.map(String.init) ?? ""
        guard tld.count >= 2, tld.contains(where: { $0.isLetter }) else { return nil }

        return httpUrl("https://\(candidate)")
    }

    /// True when the input should be searched rather than navigated.
    static func isSearchQuery(_ input: String) -> Bool {
        resolveDirectUrl(input) == nil
    }

    /// Builds an `http(s)` URL, and checks that it really has a host.
    ///
    /// `URL(string:)` succeeding is not evidence that a URL is usable: it returns
    /// an object for `https://` and for `https:///path`, neither of which has a
    /// host, and handing one of those to a web view produces a blank failure with
    /// no explanation. A host is the one thing an `http(s)` URL cannot do
    /// without, so it is checked here rather than assumed.
    ///
    /// A non-ASCII host — `中文.com`, `bücher.example` — is percent-encoded and
    /// retried when the direct parse fails, because an internationalised domain
    /// is a normal thing for this app's users to type and a search is not what
    /// they asked for.
    private static func httpUrl(_ text: String) -> URL? {
        if let url = URL(string: text), hasUsableHost(url) { return url }
        guard let encoded = percentEncodingHost(of: text),
              let url = URL(string: encoded),
              hasUsableHost(url) else { return nil }
        return url
    }

    private static func hasUsableHost(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased(), navigableSchemes.contains(scheme) else {
            return false
        }
        guard let host = url.host, !host.isEmpty else { return false }
        return true
    }

    /// Percent-encodes only the host portion of an authority-form URL.
    ///
    /// Encoding the whole string would break the scheme separator and the path;
    /// the host is the only part that can legitimately hold characters `URL`
    /// refuses.
    private static func percentEncodingHost(of text: String) -> String? {
        guard let separator = text.range(of: "://") else { return nil }
        let head = String(text[text.startIndex..<separator.lowerBound])
        let rest = String(text[separator.upperBound...])
        let hostEnd = rest.firstIndex { $0 == "/" || $0 == "?" || $0 == "#" } ?? rest.endIndex
        let host = String(rest[rest.startIndex..<hostEnd])
        guard !host.isEmpty else { return nil }
        let tail = String(rest[hostEnd...])
        guard let encodedHost = host.addingPercentEncoding(withAllowedCharacters: .urlHostAllowed) else {
            return nil
        }
        return "\(head)://\(encodedHost)\(tail)"
    }

    /// The scheme an input declares, if it declares one.
    ///
    /// Read from the text rather than from `URL`, because the question being
    /// asked is "did the user name a scheme", and `URL(string:)` will happily
    /// parse a bare host as a schemeless URL. A scheme is a letter followed by
    /// letters, digits, `+`, `-` or `.` — a shape `localhost` and `192.168.1.1`
    /// also happen to fit, which is why a name found this way still has to be
    /// recognised as a scheme before it is treated as one.
    private static func scheme(of input: String) -> String? {
        guard let colon = input.firstIndex(of: ":") else { return nil }
        let candidate = String(input[input.startIndex..<colon]).lowercased()
        guard let first = candidate.first, first.isLetter else { return nil }
        guard candidate.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "+" || $0 == "-" || $0 == "." }) else {
            return nil
        }
        return candidate
    }

    private static func isIPv4(_ value: String) -> Bool {
        let parts = value.split(separator: ".")
        guard parts.count == 4 else { return false }
        return parts.allSatisfy { part in
            // Leading zeros and a `+` sign both parse as integers but are not
            // octets, so the spelling is checked rather than only the value.
            guard !part.isEmpty, part.allSatisfy(\.isNumber) else { return false }
            guard let number = Int(part), number >= 0, number <= 255 else { return false }
            return true
        }
    }

    /// What an omnibox submission should do.
    ///
    /// One function rather than a URL-or-nothing pair, because "it did not
    /// resolve to a URL" covers three different situations the user should be
    /// told apart: a search, a scheme that belongs to another app, and an input
    /// this browser will not open.
    static func resolve(input: String, searchEngine: SearchEngineRecord) -> AddressBarResolution {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .rejected(.empty) }

        if let direct = resolveDirectUrl(trimmed) {
            if let scheme = direct.scheme?.lowercased(), externalSchemes.contains(scheme) {
                return .handOff(direct)
            }
            return .navigate(direct)
        }

        // A refused scheme is reported, not searched for: a user who typed
        // `file:///…` meant to open a file, and a results page about the string
        // they typed is not an answer to that.
        if let scheme = scheme(of: trimmed), refusedSchemes.contains(scheme) {
            return .rejected(.unsupportedScheme(scheme))
        }

        guard let searchUrl = searchEngine.searchUrl(for: trimmed) else {
            return .rejected(.noUsableSearchEngine)
        }
        return .search(searchUrl)
    }

    /// The URL to load for an omnibox submission.
    ///
    /// Kept because a caller that only wants the destination — a test, or the
    /// new-tab surface — should not have to unpack `AddressBarResolution`.
    static func resolveNavigation(
        input: String,
        searchEngine: SearchEngineRecord
    ) -> URL? {
        switch resolve(input: input, searchEngine: searchEngine) {
        case let .navigate(url), let .handOff(url), let .search(url):
            return url
        case .rejected:
            return nil
        }
    }
}

/// A determinate progress ring.
///
/// Not `ProgressView(.circular)` because the built-in one ignores a fractional
/// value in its circular style on iOS and shows an indeterminate spinner, which
/// for a progress indicator is worse than showing nothing.
///
/// The address bar no longer uses this — it draws the 2 pt line in
/// `OmniboxView` — but the tab overview still marks a loading tab with it.
struct ProgressRing: View {
    var progress: Double
    var lineWidth: CGFloat = 2

    var body: some View {
        Circle()
            .trim(from: 0, to: max(0.02, min(1, progress)))
            .stroke(
                Color.accentColor,
                style: StrokeStyle(lineWidth: lineWidth, lineCap: .round)
            )
            .rotationEffect(.degrees(-90))
            .animation(.easeOut(duration: 0.15), value: progress)
    }
}
