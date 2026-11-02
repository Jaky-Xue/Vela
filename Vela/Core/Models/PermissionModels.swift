//
//  PermissionModels.swift
//  Vela
//
//  What a site asked for, what the browser answered, and how long that answer
//  lasts. The record is the value the 网站权限 screen reads as 访问记录.
//

import Foundation

/// The answer a site received.
public enum SitePermissionDecision: String, Codable, Sendable, CaseIterable {
    case allowed
    case denied

    public var displayName: String {
        switch self {
        case .allowed: return "允许"
        case .denied: return "拒绝"
        }
    }
}

/// How long the answer applies.
///
/// The distinction is the whole point of the log: "允许一次" and "这个网站永远
/// 允许" look identical on screen until the next visit, so the record says which
/// one happened.
public enum SitePermissionScope: String, Codable, Sendable, CaseIterable {
    /// The answer applied to the one request and was not remembered.
    case once
    /// Held for the rest of this session, including relaunch-free tab closure.
    case session
    /// Stored against the site in 设置 ▸ 网站权限.
    case site
    /// The request never reached a prompt: the site or global default decided it.
    case `default`

    public var displayName: String {
        switch self {
        case .once: return "一次"
        case .session: return "本次会话"
        case .site: return "此网站"
        case .default: return "默认规则"
        }
    }
}

/// One line in the access record.
public struct SitePermissionRecord: Codable, Identifiable, Equatable, Sendable {
    public var id: UUID
    public var host: String
    public var kind: SitePermissionKind
    public var decision: SitePermissionDecision
    public var scope: SitePermissionScope
    public var createdAt: Date

    public init(
        id: UUID = UUID(),
        host: String,
        kind: SitePermissionKind,
        decision: SitePermissionDecision,
        scope: SitePermissionScope,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.host = host
        self.kind = kind
        self.decision = decision
        self.scope = scope
        self.createdAt = createdAt
    }
}
