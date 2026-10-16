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

/// Turns typed text into a URL, or decides it is a query.
///
/// `BrowserAddressDisplayCoordinator`. The rules, in order:
///
/// * An input with a scheme Vela can load is a URL.
/// * An input with no spaces that contains a dot and a plausible TLD is a URL,
///   with `https://` assumed.
/// * A bare localhost or an IP address is a URL.
/// * Anything else is a search query.
enum BrowserUrlResolver {
    /// Schemes Vela will navigate to directly from the address bar.
    private static let loadableSchemes: Set<String> = ["http", "https", "file", "about", "data"]
    /// Schemes that are meaningful but are handed to the system rather than
    /// loaded, so typing one does not produce a blank page.
    static let externalSchemes: Set<String> = [
        "mailto", "tel", "sms", "facetime", "itms-apps", "alipays", "weixin", "taobao", "mqq"
    ]

    /// The URL an input resolves to, when it resolves to one.
    static func resolveDirectUrl(_ input: String) -> URL? {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        // An explicit scheme wins outright, whether or not it carries an
        // authority.
        //
        // The `://` spelling is the common one but not the only one: `mailto:`,
        // `tel:` and `sms:` are written without it, and an address bar that only
        // recognised the authority form would send every one of them to the
        // search engine — so the "email this" link the user copied would become
        // a search for the literal text of the address.
        if let scheme = scheme(of: trimmed),
           loadableSchemes.contains(scheme) || externalSchemes.contains(scheme) {
            return URL(string: trimmed)
        }

        // A single word with no dot is a query, not a host.
        let hasSpace = trimmed.contains(" ")
        guard !hasSpace else { return nil }

        // Strip a trailing slash-only path for the checks below.
        let candidate = trimmed.hasSuffix("/") ? String(trimmed.dropLast()) : trimmed
        guard !candidate.isEmpty else { return nil }

        // localhost and port, e.g. `localhost:8080` or `127.0.0.1:3000`.
        let hostPart = candidate.split(separator: "/").first.map(String.init) ?? candidate
        let hostWithoutPort = hostPart.split(separator: ":").first.map(String.init) ?? hostPart

        if hostWithoutPort == "localhost" { return URL(string: "http://\(candidate)") }
        if isIPv4(hostWithoutPort) { return URL(string: "http://\(candidate)") }
        // A bracketed IPv6 literal.
        if hostWithoutPort.hasPrefix("[") && hostWithoutPort.hasSuffix("]") {
            return URL(string: "http://\(candidate)")
        }

        guard hostWithoutPort.contains(".") else { return nil }
        // Reject a trailing dot or a leading dot, which are typos rather than
        // hosts, and reject a "TLD" of digits (a version number, not a domain).
        guard !hostWithoutPort.hasPrefix("."), !hostWithoutPort.hasSuffix(".") else { return nil }
        let tld = hostWithoutPort.split(separator: ".").last.map(String.init) ?? ""
        guard tld.count >= 2, tld.contains(where: { $0.isLetter }) else { return nil }

        return URL(string: "https://\(candidate)")
    }

    /// True when the input should be searched rather than navigated.
    static func isSearchQuery(_ input: String) -> Bool {
        resolveDirectUrl(input) == nil
    }

    /// The scheme an input declares, if it declares one.
    ///
    /// Read from the text rather than from `URL`, because the question being
    /// asked is "did the user name a scheme", and `URL(string:)` will happily
    /// parse a bare host as a schemeless URL. A scheme is a letter followed by
    /// letters, digits, `+`, `-` or `.` — which is what keeps `localhost:8080`
    /// and `192.168.1.1:3000` out of this path, since neither `localhost` nor a
    /// numeric host is a legal scheme.
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
            guard let number = Int(part), number >= 0, number <= 255 else { return false }
            return true
        }
    }

    /// The URL to load for an omnibox submission.
    ///
    static func resolveNavigation(
        input: String,
        searchEngine: SearchEngineRecord
    ) -> URL? {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if let direct = resolveDirectUrl(trimmed) { return direct }
        return searchEngine.searchUrl(for: trimmed)
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
