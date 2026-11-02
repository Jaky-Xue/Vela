//
//  PermissionAuditService.swift
//  Vela
//
//  The site-permission access record.
//
//  It lives at the process level beside the other shared services: every
//  Stage Manager window writes into the same log, because the user reads it as
//  "what has this browser told websites", not "what did this window do".
//
//  The log is capped and rotated oldest-first. It holds only the host, the
//  kind, the answer and the scope — no page title, URL path or content — so it
//  can be read and cleared without touching anything else the browser keeps.
//

import Foundation
import Observation

@MainActor
@Observable
public final class PermissionAuditService {
    private static let storageKey = "org.vela.browser.permission-audit"
    private static let capacity = 500

    public private(set) var records: [SitePermissionRecord]

    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: Self.storageKey),
           let stored = try? JSONDecoder().decode([SitePermissionRecord].self, from: data) {
            self.records = stored
        } else {
            self.records = []
        }
    }

    /// Appends one decision, newest first.
    public func record(
        host: String,
        kind: SitePermissionKind,
        decision: SitePermissionDecision,
        scope: SitePermissionScope
    ) {
        let normalized = host.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !normalized.isEmpty else { return }
        records.insert(
            SitePermissionRecord(
                host: normalized,
                kind: kind,
                decision: decision,
                scope: scope
            ),
            at: 0
        )
        if records.count > Self.capacity {
            records.removeLast(records.count - Self.capacity)
        }
        persist()
    }

    public func clear() {
        guard !records.isEmpty else { return }
        records = []
        persist()
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(records) else { return }
        defaults.set(data, forKey: Self.storageKey)
    }
}
