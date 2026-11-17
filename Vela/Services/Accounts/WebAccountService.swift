//
//  WebAccountService.swift
//  Vela
//
//  The accounts listed in 设置 ▸ 账号, and the browser's actual sign-in state
//  for each provider.
//
//  Two different facts live here and are deliberately kept apart:
//
//  * The list is the user's own labels — a provider, an address, a note —
//    stored in `UserDefaults` on this device. Vela never asks the provider for
//    them.
//  * Whether the browser is signed in is read from its own cookie jar: an
//    httpOnly session cookie on the provider's domain means some account is
//    signed in. The address of that account is not readable from a cookie,
//    which is why the list cannot populate itself.
//
//  Signing out is real: it removes every cookie and every piece of site data
//  for that provider's domains from the browser's data store, so the
//  provider's pages show the signed-out state afterwards.
//

import Foundation
import Observation
import WebKit

@MainActor
@Observable
public final class WebAccountService {
    /// What the browser's cookie jar says about one provider.
    public enum BrowserSession: Equatable {
        case unknown
        case signedIn
        case signedOut
    }

    public private(set) var accounts: [WebAccount] = []
    /// The browser's own state per provider, not the list's. A provider is
    /// `unknown` until it has been probed.
    public private(set) var sessions: [WebAccountProvider: BrowserSession] = [:]
    public private(set) var signingOutProvider: WebAccountProvider?

    private enum Key {
        static let document = "org.vela.browser.web-accounts"
    }

    private let defaults: UserDefaults
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        reload()
    }

    // MARK: - The list

    public func reload() {
        guard let data = defaults.data(forKey: Key.document),
              let decoded = try? decoder.decode([WebAccount].self, from: data) else {
            accounts = []
            return
        }
        accounts = decoded
    }

    public func accounts(for provider: WebAccountProvider) -> [WebAccount] {
        accounts.filter { $0.provider == provider }
    }

    /// Adds an address. The same address on the same provider is one row: a
    /// second add is a chance to change the note, not a second account.
    @discardableResult
    public func add(
        provider: WebAccountProvider,
        email: String,
        label: String
    ) -> WebAccount? {
        guard let normalized = Self.normalizedEmail(email) else { return nil }
        let trimmedLabel = label.trimmingCharacters(in: .whitespacesAndNewlines)
        if let index = accounts.firstIndex(where: {
            $0.provider == provider && $0.email == normalized
        }) {
            accounts[index].label = trimmedLabel
            persist()
            return accounts[index]
        }
        let account = WebAccount(provider: provider, email: normalized, label: trimmedLabel)
        accounts.append(account)
        persist()
        return account
    }

    public func remove(id: String) {
        guard accounts.contains(where: { $0.id == id }) else { return }
        accounts.removeAll { $0.id == id }
        persist()
    }

    public func updateLabel(id: String, label: String) {
        guard let index = accounts.firstIndex(where: { $0.id == id }) else { return }
        accounts[index].label = label.trimmingCharacters(in: .whitespacesAndNewlines)
        persist()
    }

    /// An address, lowercased and trimmed, or `nil` when it cannot be one.
    /// The address is checked for its shape only — validating it against the
    /// provider would be a network call for a label.
    public static func normalizedEmail(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard trimmed.count >= 5, !trimmed.contains(" ") else { return nil }
        let parts = trimmed.split(separator: "@", omittingEmptySubsequences: false)
        guard parts.count == 2,
              !parts[0].isEmpty,
              parts[1].firstIndex(of: ".") != nil,
              !parts[1].hasSuffix(".") else { return nil }
        return trimmed
    }

    private func persist() {
        guard let data = try? encoder.encode(accounts) else { return }
        defaults.set(data, forKey: Key.document)
    }

    // MARK: - The browser's own session

    public func session(for provider: WebAccountProvider) -> BrowserSession {
        sessions[provider] ?? .unknown
    }

    /// Reads the cookie jar once and answers for every provider.
    public func refreshSessions() async {
        let cookies = await Self.allCookies()
        var resolved: [WebAccountProvider: BrowserSession] = [:]
        for provider in WebAccountProvider.allCases {
            let signedIn = cookies.contains { cookie in
                guard provider.sessionCookieNames.contains(cookie.name) else { return false }
                let domain = cookie.domain.lowercased()
                return provider.sessionCookieDomains.contains { root in
                    domain == root || domain.hasSuffix("." + root)
                }
            }
            resolved[provider] = signedIn ? .signedIn : .signedOut
        }
        sessions = resolved
    }

    /// Signs out of every account of one provider in the browser and forgets
    /// that provider's list.
    ///
    /// Deliberately all-or-nothing for the provider: clearing one domain while
    /// another keeps its cookie leaves the user signed in somewhere they
    /// cannot see.
    public func signOut(_ provider: WebAccountProvider) async {
        guard signingOutProvider == nil else { return }
        signingOutProvider = provider
        await Self.clearData(domains: provider.domainsToClear)
        accounts.removeAll { $0.provider == provider }
        persist()
        sessions[provider] = .signedOut
        signingOutProvider = nil
    }

    /// Signs out of every provider the browser knows about and forgets every
    /// listed account. The unified 「退出所有账号」 action.
    public func signOutAll() async {
        guard signingOutProvider == nil else { return }
        for provider in WebAccountProvider.allCases {
            signingOutProvider = provider
            await Self.clearData(domains: provider.domainsToClear)
            accounts.removeAll { $0.provider == provider }
            persist()
            sessions[provider] = .signedOut
        }
        signingOutProvider = nil
    }

    private static func allCookies() async -> [HTTPCookie] {
        await withCheckedContinuation { continuation in
            WKWebsiteDataStore.default().httpCookieStore.getAllCookies { cookies in
                continuation.resume(returning: cookies)
            }
        }
    }

    private static func clearData(domains: Set<String>) async {
        let types = WKWebsiteDataStore.allWebsiteDataTypes()
        await withCheckedContinuation { continuation in
            WKWebsiteDataStore.default().removeData(
                ofTypes: types,
                for: domains,
                modifiedSince: .distantPast
            ) {
                continuation.resume()
            }
        }
    }
}
