//
//  PrivacyModels.swift
//  Vela
//
//  Privacy controls that are policies rather than per-site permissions.
//
//  WebRTC is the one that needs explaining: a page can open peer connections
//  from any frame, and a host ICE candidate can carry a local address. WebKit
//  already uses mDNS for many host candidates, but that is a default, not a
//  guarantee across every WebKit version and configuration. Vela therefore
//  ships a policy the user chooses, applied by a document-start script in every
//  frame before the page's own code can build a peer connection.
//

import Foundation

/// How Vela treats WebRTC.
public enum WebRTCProtectionMode: String, CaseIterable, Codable, Sendable, Identifiable {
    /// Do nothing; the engine's own default applies.
    case allow
    /// Drop host candidates that expose a private or link-local address.
    case balanced
    /// Force relay-only ICE, so no direct peer address is used at all.
    case strict
    /// Remove `RTCPeerConnection` and the capture APIs from the page.
    case blocked

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .allow: return "允许"
        case .balanced: return "防泄露"
        case .strict: return "仅中继"
        case .blocked: return "完全禁用"
        }
    }

    public var summary: String {
        switch self {
        case .allow: return "不干预网页的 WebRTC 行为。"
        case .balanced: return "过滤发往对端的私有地址候选，视频通话通常仍可用；不重写 SDP。"
        case .strict: return "强制 relay，只通过 TURN 中继连接；没有 TURN 时通话会失败。"
        case .blocked: return "网页无法创建 RTCPeerConnection，也无法调用摄像头/麦克风采集 API。"
        }
    }

    public var symbolName: String {
        switch self {
        case .allow: return "network"
        case .balanced: return "shield.lefthalf.filled"
        case .strict: return "arrow.triangle.branch"
        case .blocked: return "xmark.shield"
        }
    }

    /// Resolves a stored raw value. The default is 防泄露: filtering private
    /// host candidates does not break ordinary calls, so it is the safe default
    /// for an install that never chose.
    public static func resolve(_ rawValue: String?) -> WebRTCProtectionMode {
        guard let rawValue, let mode = WebRTCProtectionMode(rawValue: rawValue) else {
            return .balanced
        }
        return mode
    }
}
