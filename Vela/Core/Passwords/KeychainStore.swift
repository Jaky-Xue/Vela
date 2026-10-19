//
//  KeychainStore.swift
//  Vela
//
//  A narrow wrapper over the iOS Keychain, used by the password vault.
//
//  The app's own value store is `UserDefaults` and SQLite, neither of which is
//  an appropriate place for a password. The Keychain is the system's answer:
//  entries are encrypted with the device key, only readable while the device is
//  unlocked, and marked `ThisDeviceOnly` so they are never carried to another
//  device by a backup — a password the user did not ask to sync must not move.
//
//  The wrapper keeps one service name and treats each account as one item, so
//  a credential's identity is its UUID and the rest of the record is the item's
//  data.
//

import Foundation
import Security

enum KeychainStoreError: LocalizedError {
    case unexpectedStatus(OSStatus)

    var errorDescription: String? {
        switch self {
        case let .unexpectedStatus(status):
            return "钥匙串操作失败（\(status)）"
        }
    }
}

final class KeychainStore {
    let service: String

    init(service: String) {
        self.service = service
    }

    private var baseQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service
        ]
    }

    /// Every item's data, in no particular order.
    func allData() throws -> [Data] {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecReturnAttributes as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitAll

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return [] }
        guard status == errSecSuccess else {
            throw KeychainStoreError.unexpectedStatus(status)
        }

        // With both data and attributes requested, Security answers with one
        // dictionary per item. Some OS versions hand back a single dictionary
        // for a one-item match, so both shapes are accepted.
        if let items = result as? [[String: Any]] {
            return items.compactMap { $0[kSecValueData as String] as? Data }
        }
        if let item = result as? [String: Any],
           let data = item[kSecValueData as String] as? Data {
            return [data]
        }
        return []
    }

    func read(account: String) -> Data? {
        var query = baseQuery
        query[kSecAttrAccount as String] = account
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess else {
            return nil
        }
        return result as? Data
    }

    /// Writes one item, updating it in place when the account exists.
    func save(account: String, data: Data) throws {
        let query = baseQuery.merging([kSecAttrAccount as String: account]) { _, new in new }

        let updateAttributes: [String: Any] = [
            kSecValueData as String: data
        ]
        let updateStatus = SecItemUpdate(query as CFDictionary, updateAttributes as CFDictionary)
        if updateStatus == errSecSuccess { return }
        guard updateStatus == errSecItemNotFound else {
            throw KeychainStoreError.unexpectedStatus(updateStatus)
        }

        var addQuery = query
        addQuery[kSecValueData as String] = data
        addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        addQuery[kSecAttrSynchronizable as String] = false
        let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
        guard addStatus == errSecSuccess else {
            throw KeychainStoreError.unexpectedStatus(addStatus)
        }
    }

    func delete(account: String) throws {
        let query = baseQuery.merging([kSecAttrAccount as String: account]) { _, new in new }
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainStoreError.unexpectedStatus(status)
        }
    }

    func deleteAll() throws {
        let status = SecItemDelete(baseQuery as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainStoreError.unexpectedStatus(status)
        }
    }
}
