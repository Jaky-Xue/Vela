//
//  GoogleAccountModels.swift
//  Vela
//
//  A Google account the user has listed in 设置 ▸ Google 账号.
//
//  This is a *label*, not a credential. Signing in happens on Google's own
//  pages inside the browser, in the browser's own cookie jar; Vela never sees
//  or stores the password, and nothing here is sent anywhere. The list exists
//  so one tap reaches the account page and so 「退出所有 Google 账号」 has an
//  inventory of who the user expects to be signed in.
//

import Foundation

public struct GoogleAccount: Identifiable, Codable, Equatable, Sendable {
    public var id: String
    /// The address the user typed. Normalised when it is added.
    public var email: String
    /// An optional note — 「工作」, 「小号」 — shown under the address.
    public var label: String
    public var addedAt: Date

    public init(
        id: String = UUID().uuidString,
        email: String,
        label: String = "",
        addedAt: Date = Date()
    ) {
        self.id = id
        self.email = email
        self.label = label
        self.addedAt = addedAt
    }
}
