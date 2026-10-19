//
//  PasswordModels.swift
//  Vela
//
//  The vault's value type.
//
//  A credential is stored whole, as JSON, inside one Keychain item — password
//  included. Nothing about it ever enters the preferences document, the
//  database, or any other file the app can read without the Keychain; the
//  vault's own list is decoded from the Keychain on unlock.
//

import Foundation

/// One saved login.
public struct VaultCredential: Identifiable, Codable, Equatable, Sendable {
    public var id: String
    /// What the vault shows as the row's title, e.g. "GitHub".
    public var title: String
    /// The normalized host the credential belongs to, lowercased and without
    /// a leading "www.".
    public var host: String
    public var username: String
    public var password: String
    public var notes: String
    public var createdAt: Date
    public var updatedAt: Date

    public init(
        id: String = UUID().uuidString,
        title: String,
        host: String,
        username: String,
        password: String,
        notes: String = "",
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.title = title
        self.host = VaultCredential.normalizeHost(host)
        self.username = username
        self.password = password
        self.notes = notes
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    /// The display host, without the normalization's leading-www removal.
    public var displayHost: String { host }

    /// Whether this credential belongs to a page on `host`.
    ///
    /// A saved `example.com` fills `www.example.com` and `login.example.com`,
    /// but a saved `login.example.com` does not fill `example.com`: the more
    /// specific entry is the one that knows the subdomain's form.
    public func matches(host pageHost: String) -> Bool {
        let normalized = VaultCredential.normalizeHost(pageHost)
        guard !normalized.isEmpty, !host.isEmpty else { return false }
        return normalized == host || normalized.hasSuffix("." + host)
    }

    /// Lowercased, scheme-free, "www."-free host text. A pasted URL works; so
    /// does a bare host.
    public static func normalizeHost(_ raw: String) -> String {
        var value = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if value.isEmpty { return "" }
        if value.contains("://") || value.contains("/") {
            if let host = URL(string: value.contains("://") ? value : "https://" + value)?.host {
                value = host.lowercased()
            } else if let first = value.split(separator: "/").first {
                value = String(first)
            }
        }
        // A pasted host may carry a port; the credential belongs to the site,
        // not to one port of it.
        if let colon = value.firstIndex(of: ":"), !value.contains("]") {
            let hostPart = String(value[value.startIndex..<colon])
            if !hostPart.isEmpty { value = hostPart }
        }
        if value.hasPrefix("www.") {
            value.removeFirst(4)
        }
        return value
    }

    /// A title to show when the user left the title empty.
    public static func fallbackTitle(for host: String) -> String {
        host.isEmpty ? "未命名" : host
    }
}
