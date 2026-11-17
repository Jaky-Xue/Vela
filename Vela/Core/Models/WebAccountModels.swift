//
//  WebAccountModels.swift
//  Vela
//
//  An account the user has listed in 设置 ▸ 账号, and the providers whose
//  sign-in the browser can recognise.
//
//  This is a *label*, not a credential. Signing in happens on the provider's
//  own pages inside the browser, in the browser's own cookie jar; Vela never
//  sees or stores a password, and nothing here is sent anywhere. The list
//  exists so one tap reaches the account page and so 「退出所有 … 账号」 has an
//  inventory of who the user expects to be signed in.
//

import Foundation

/// A provider whose sign-in the browser can detect and clear.
///
/// Everything provider-specific — the sign-in page, the account page, the
/// cookie names that mean "signed in", the domains that belong to a session —
/// lives here, so the service and the screen stay provider-agnostic.
public enum WebAccountProvider: String, Codable, Sendable, CaseIterable, Identifiable {
    case google
    case apple

    public var id: String { rawValue }

    /// The name used in copy: 「Google 账号」, 「Apple 账号」.
    public var displayName: String {
        switch self {
        case .google: return "Google"
        case .apple: return "Apple"
        }
    }

    public var screenTitle: String { "\(displayName) 账号" }

    /// The provider's own sign-in page, opened in a tab.
    public var signInURL: URL? {
        switch self {
        case .google:
            return URL(
                string: "https://accounts.google.com/ServiceLogin?continue=https%3A%2F%2Fmyaccount.google.com%2F"
            )
        case .apple:
            return URL(string: "https://appleid.apple.com/sign-in")
        }
    }

    /// Where the user manages the account once signed in.
    public var accountPageURL: URL? {
        switch self {
        case .google: return URL(string: "https://myaccount.google.com/")
        case .apple: return URL(string: "https://account.apple.com/")
        }
    }

    /// The cookie names a signed-in session carries. Only the names are read;
    /// the values never leave the cookie store.
    public var sessionCookieNames: Set<String> {
        switch self {
        case .google:
            return [
                "SID", "HSID", "SSID", "APISID", "SAPISID",
                "__Secure-1PSID", "__Secure-3PSID",
                "__Secure-1PAPISID", "__Secure-3PAPISID"
            ]
        case .apple:
            return ["myacinfo", "acinfo"]
        }
    }

    /// The domains those cookies live on. A cookie on a subdomain counts.
    public var sessionCookieDomains: [String] {
        switch self {
        case .google: return ["google.com"]
        case .apple: return ["apple.com"]
        }
    }

    /// Every domain whose site data belongs to this provider's sign-in.
    /// Signing out clears them together: leaving one behind leaves a page that
    /// still knows who the user is.
    public var domainsToClear: Set<String> {
        switch self {
        case .google:
            return [
                "google.com", "accounts.google.com", "accounts.youtube.com",
                "googleusercontent.com", "googleapis.com", "gstatic.com",
                "youtube.com", "youtu.be"
            ]
        case .apple:
            return [
                "apple.com", "appleid.apple.com", "idmsa.apple.com",
                "account.apple.com", "icloud.com"
            ]
        }
    }
}

public struct WebAccount: Identifiable, Codable, Equatable, Sendable {
    public var id: String
    public var provider: WebAccountProvider
    /// The address the user typed. Normalised when it is added.
    public var email: String
    /// An optional note — 「工作」, 「小号」 — shown under the address.
    public var label: String
    public var addedAt: Date

    public init(
        id: String = UUID().uuidString,
        provider: WebAccountProvider,
        email: String,
        label: String = "",
        addedAt: Date = Date()
    ) {
        self.id = id
        self.provider = provider
        self.email = email
        self.label = label
        self.addedAt = addedAt
    }
}
