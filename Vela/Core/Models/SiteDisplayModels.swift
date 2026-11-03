//
//  SiteDisplayModels.swift
//  Vela
//
//  A site's own answer to 桌面版 / 手机版.
//
//  The global choice in 网页标识 is a default, not a rule: a site that only
//  works in one of the two layouts needs its own answer, and a user who has
//  given it should not have to give it again on the next visit. The store
//  lives beside the settings document rather than inside it, so the site list
//  can grow without re-encoding every preference on each change.
//

import Foundation

/// The display a single site has been given.
///
/// Two states rather than three: "no entry" is the automatic identity, and an
/// empty dictionary value is not a state the user can choose. Keeping the
/// automatic answer out of the stored value is what lets the device rule
/// change under an untouched site.
public enum BrowserSiteDisplayMode: String, Codable, Sendable, CaseIterable, Identifiable {
    case desktop
    case mobile

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .desktop: return "桌面版"
        case .mobile: return "手机版"
        }
    }
}

/// Host text and domain matching shared by the per-site preferences.
///
/// The same shape the password vault uses: lowercased, scheme-free,
/// `www.`-free, and matching the host or any parent of it. A rule for
/// `example.com` therefore covers `m.example.com`, while a rule for the
/// subdomain alone does not leak to its siblings.
public enum BrowserSiteHost {
    /// Lowercased, scheme-free, `www.`-free host text. A pasted URL works; so
    /// does a bare host.
    public static func normalize(_ raw: String) -> String {
        var value = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if value.isEmpty { return "" }
        if value.contains("://") || value.contains("/") {
            if let host = URL(string: value.contains("://") ? value : "https://" + value)?.host {
                value = host.lowercased()
            } else if let first = value.split(separator: "/").first {
                value = String(first)
            }
        }
        // A pasted host may carry a port; the preference belongs to the site,
        // not to one port of it.
        if let colon = value.firstIndex(of: ":"), !value.contains("]") {
            let hostPart = String(value[value.startIndex..<colon])
            if !hostPart.isEmpty { value = hostPart }
        }
        if value.hasPrefix("www.") {
            value.removeFirst(4)
        }
        while value.hasSuffix(".") {
            value.removeLast()
        }
        return value
    }

    /// Whether a stored rule covers the page's host.
    public static func matches(pageHost: String, rule: String) -> Bool {
        let page = normalize(pageHost)
        let site = normalize(rule)
        guard !page.isEmpty, !site.isEmpty else { return false }
        return page == site || page.hasSuffix("." + site)
    }

    /// Walks a host and its parent domains, most specific first.
    public static func candidates(for host: String) -> [String] {
        let normalized = normalize(host)
        guard !normalized.isEmpty else { return [] }
        var result = [normalized]
        var candidate = normalized
        while let dot = candidate.firstIndex(of: ".") {
            candidate = String(candidate[candidate.index(after: dot)...])
            guard !candidate.isEmpty else { break }
            result.append(candidate)
        }
        return result
    }
}

/// The stored per-site display choices, keyed by normalized host.
public struct SiteDisplaySettings: Codable, Equatable, Sendable {
    public var modes: [String: BrowserSiteDisplayMode]

    public static let `default` = SiteDisplaySettings(modes: [:])

    public init(modes: [String: BrowserSiteDisplayMode] = [:]) {
        self.modes = modes
    }

    public var count: Int { modes.count }

    /// The most specific rule that covers this page, if any.
    public func mode(forPageHost host: String) -> BrowserSiteDisplayMode? {
        for candidate in BrowserSiteHost.candidates(for: host) {
            if let mode = modes[candidate] { return mode }
        }
        return nil
    }

    /// Sets or clears this page's rule. The key is the page's own host, not a
    /// parent: a choice made while on `m.example.com` belongs to that host,
    /// and a choice made on `example.com` covers its subdomains through the
    /// lookup above.
    public mutating func set(_ mode: BrowserSiteDisplayMode?, forPageHost host: String) {
        let normalized = BrowserSiteHost.normalize(host)
        guard !normalized.isEmpty else { return }
        if let mode {
            modes[normalized] = mode
        } else {
            modes[normalized] = nil
        }
    }

    /// The stored hosts in display order, for the settings screen.
    public var sortedHosts: [SiteDisplayEntry] {
        modes
            .sorted { $0.key < $1.key }
            .map { SiteDisplayEntry(host: $0.key, mode: $0.value) }
    }
}

/// One row of the per-site list. A named type rather than a tuple: key paths
/// do not reach tuple elements, and the settings list identifies rows by host.
public struct SiteDisplayEntry: Identifiable, Equatable, Sendable {
    public var id: String { host }
    public var host: String
    public var mode: BrowserSiteDisplayMode

    public init(host: String, mode: BrowserSiteDisplayMode) {
        self.host = host
        self.mode = mode
    }
}
