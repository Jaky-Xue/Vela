//
//  GoogleAccountService.swift
//  Vela
//
//  The accounts listed in 设置 ▸ Google 账号, and the browser's actual Google
//  session state.
//
//  Two different facts live here and are deliberately kept apart:
//
//  * The list is the user's own labels — an address and a note — stored in
//    `UserDefaults` on this device. Vela never asks Google for them.
//  * Whether the browser is signed in is read from its own cookie jar: an
//    httpOnly session cookie on a `google.com` domain means some account is
//    signed in. The address of that account is not readable from a cookie,
//    which is why the list cannot populate itself.
//
//  Signing out is real: it removes every Google-hosted cookie and every piece
//  of Google site data from the browser's data store, so Google's pages show
//  the signed-out state afterwards.
//

import Foundation
import Observation
import WebKit

@MainActor
@Observable
public final class GoogleAccountService {
    /// What the browser's cookie jar says about Google.
    public enum BrowserSession: Equatable {
        case unknown
        case signedIn
        case signedOut
    }

    public private(set) var accounts: [GoogleAccount] = []
    /// The browser's own state, not the list's. `unknown` until probed.
    public private(set) var browserSession: BrowserSession = .unknown
    public private(set) var isSigningOut = false

    private enum Key {
        static let document = "org.vela.browser.google-accounts"
    }

    private let defaults: UserDefaults
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    /// The cookie names a signed-in Google session carries. Any one of them on
    /// a Google domain is the signal; the values are never read.
    private static let sessionCookieNames: Set<String> = [
        "SID", "HSID", "SSID", "APISID", "SAPISID",
        "__Secure-1PSID", "__Secure-3PSID", "__Secure-1PAPISID", "__Secure-3PAPISID"
    ]

    /// The domains whose site data belongs to a Google sign-in. Signing out
    /// clears all of them together: leaving one behind leaves a Google page
    /// that still knows who the user is.
    private static let googleDomains: Set<String> = [
        "google.com",
        "accounts.google.com",
        "accounts.youtube.com",
        "googleusercontent.com",
        "googleapis.com",
        "gstatic.com",
        "youtube.com",
        "youtu.be"
    ]

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        reload()
    }

    // MARK: - The list

    public func reload() {
        guard let data = defaults.data(forKey: Key.document),
              let decoded = try? decoder.decode([GoogleAccount].self, from: data) else {
            accounts = []
            return
        }
        accounts = decoded
    }

    /// Adds an address. The same address twice is one row: a second add is
    /// treated as a chance to change the note, not a second account.
    @discardableResult
    public func add(email: String, label: String) -> GoogleAccount? {
        guard let normalized = Self.normalizedEmail(email) else { return nil }
        let trimmedLabel = label.trimmingCharacters(in: .whitespacesAndNewlines)
        if let index = accounts.firstIndex(where: { $0.email == normalized }) {
            accounts[index].label = trimmedLabel
            persist()
            return accounts[index]
        }
        let account = GoogleAccount(email: normalized, label: trimmedLabel)
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
    /// A Google address is not validated against Google here — that would be
    /// a network call for a label — only against the shape of an address.
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

    /// Reads the cookie jar and answers whether a Google session is present.
    public func refreshSession() async {
        let cookies = await Self.allCookies()
        browserSession = cookies.contains { cookie in
            guard Self.sessionCookieNames.contains(cookie.name) else { return false }
            let domain = cookie.domain.lowercased()
            return domain == "google.com" || domain.hasSuffix(".google.com")
        } ? .signedIn : .signedOut
    }

    /// Signs out of every Google account in the browser and forgets the list.
    ///
    /// This is the destructive action, and it is deliberately all-or-nothing:
    /// clearing one Google domain while another keeps its cookie leaves the
    /// user signed in somewhere they cannot see.
    public func signOutEverywhere() async {
        guard !isSigningOut else { return }
        isSigningOut = true
        await Self.clearGoogleData()
        accounts.removeAll()
        persist()
        browserSession = .signedOut
        isSigningOut = false
    }

    private static func allCookies() async -> [HTTPCookie] {
        await withCheckedContinuation { continuation in
            WKWebsiteDataStore.default().httpCookieStore.getAllCookies { cookies in
                continuation.resume(returning: cookies)
            }
        }
    }

    private static func clearGoogleData() async {
        let types = WKWebsiteDataStore.allWebsiteDataTypes()
        await withCheckedContinuation { continuation in
            WKWebsiteDataStore.default().removeData(
                ofTypes: types,
                for: googleDomains,
                modifiedSince: .distantPast
            ) {
                continuation.resume()
            }
        }
    }
}
