//
//  ContentBlockerModels.swift
//  Vela
//
//  The ad-blocker's device-local settings: on/off and the sites that are
//  allowed to load their ads anyway.
//
//  A document of its own rather than a field in the preferences document, for
//  the decode reason every new settings domain carries: an absent key must
//  decode to the default instead of resetting the rest of the document.
//

import Foundation

public struct ContentBlockerSettings: Codable, Equatable, Sendable {
    public var enabled: Bool
    /// Hosts that bypass the rule list. Parent-domain matching, the same shape
    /// the password vault and the per-site display choices use.
    public var whitelistedHosts: [String]

    public init(enabled: Bool = true, whitelistedHosts: [String] = []) {
        self.enabled = enabled
        self.whitelistedHosts = whitelistedHosts
    }

    public static let `default` = ContentBlockerSettings()

    /// Whether this page is exempt from blocking.
    public func isExcepted(host: String) -> Bool {
        let normalized = BrowserSiteHost.normalize(host)
        guard !normalized.isEmpty else { return false }
        return whitelistedHosts.contains { BrowserSiteHost.matches(pageHost: normalized, rule: $0) }
    }
}
