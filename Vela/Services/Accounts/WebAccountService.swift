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

    /// The list used to live in `UserDefaults`; it is a Keychain item now.
    private enum Key {
        static let document = "org.vela.browser.web-accounts"
        static let legacyDefaultsKey = "org.vela.browser.web-accounts"
    }

    /// The address list is a set of personal identifiers, so it lives in the
    /// Keychain rather than in a plist any file reader can open: encrypted
    /// with the device key, readable only while unlocked, and marked
    /// this-device-only so a backup never carries it elsewhere.
    private let store: KeychainStore
    private let legacyDefaults: UserDefaults
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    init(
        store: KeychainStore = KeychainStore(service: KeychainStore.webAccountsService),
        legacyDefaults: UserDefaults = .standard
    ) {
        self.store = store
        self.legacyDefaults = legacyDefaults
        migrateOutOfUserDefaultsIfNeeded()
        reload()
    }

    /// Carries a list written by the first 4.0.72 build out of `UserDefaults`.
    private func migrateOutOfUserDefaultsIfNeeded() {
        guard store.read(account: Key.document) == nil,
              let legacy = legacyDefaults.data(forKey: Key.legacyDefaultsKey) else { return }
        try? store.save(account: Key.document, data: legacy)
        legacyDefaults.removeObject(forKey: Key.legacyDefaultsKey)
    }

    // MARK: - The list

    public func reload() {
        guard let data = store.read(account: Key.document),
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
        do {
            try store.save(account: Key.document, data: data)
        } catch {
            // The list stays in memory for this launch and the next save tries
            // again. Nothing is written anywhere less protected instead.
        }
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

    /// Clears every web record whose registrable domain belongs to the
    /// provider.
    ///
    /// WebKit removes data by *record*, not by domain string: the store is
    /// asked what it holds, the records that belong to the provider are kept,
    /// and those are removed. Matching a record by suffix is what makes
    /// `accounts.google.com` data go with `google.com`.
    private static func clearData(domains: Set<String>) async {
        let store = WKWebsiteDataStore.default()
        let types = WKWebsiteDataStore.allWebsiteDataTypes()
        let records = await withCheckedContinuation { continuation in
            store.fetchDataRecords(ofTypes: types) { records in
                continuation.resume(returning: records)
            }
        }
        let matching = records.filter { record in
            let name = record.displayName.lowercased()
            return domains.contains { root in
                name == root || name.hasSuffix("." + root)
            }
        }
        guard !matching.isEmpty else { return }
        await withCheckedContinuation { continuation in
            store.removeData(ofTypes: types, for: matching) {
                continuation.resume()
            }
        }
    }
}
