//
//  ElementHideModels.swift
//  Vela
//
//  The element picker's records: selectors the user hid on a site, grouped by
//  host. They survived the removal of the ad-block rule engine because hiding
//  one element on one site is a direct user action, not a subscription.
//

import Foundation

/// One entry per element the user pointed at and hid.
public struct ManualElementHideRule: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var selector: String
    public var createdAt: Date

    public init(id: String = UUID().uuidString, selector: String, createdAt: Date = Date()) {
        self.id = id
        self.selector = selector
        self.createdAt = createdAt
    }
}

/// The selectors hidden for one host.
public struct ManualElementHideSiteRules: Codable, Equatable, Sendable, Identifiable {
    public var id: String { host }
    public var host: String
    public var rules: [ManualElementHideRule]

    public init(host: String, rules: [ManualElementHideRule] = []) {
        self.host = host
        self.rules = rules
    }
}

public struct ManualElementHideSettings: Codable, Equatable, Sendable {
    public var sites: [ManualElementHideSiteRules]

    public init(sites: [ManualElementHideSiteRules] = []) {
        self.sites = sites
    }

    public static let `default` = ManualElementHideSettings()

    public func rules(for host: String) -> [ManualElementHideRule] {
        sites.first { $0.host == host }?.rules ?? []
    }

    /// Every selector that applies to `host`, including hosts that are a suffix
    /// of it — a rule added on `news.example.com` also applies to a subdomain.
    public func effectiveSelectors(for host: String) -> [String] {
        let normalized = host.lowercased()
        return sites
            .filter { normalized == $0.host || normalized.hasSuffix("." + $0.host) }
            .flatMap { $0.rules.map(\.selector) }
    }
}
