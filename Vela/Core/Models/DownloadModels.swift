//
//  DownloadModels.swift
//  Vela
//
//  The download model: one record per task, plus the status vocabulary the list
//  and the settings screen render.
//
//  WebKit performs the transfer. A `WKDownload` is created for any response the
//  web view would otherwise render, and cancelling one hands back resume data,
//  so the state machine here tracks what WebKit is doing rather than driving a
//  connection of its own. That is also why every status below has a real event
//  behind it and none is inferred.
//

import Foundation

/// Ported from the `status` field of `DownloadV2TaskEntity`.
public enum DownloadStatus: String, Codable, Sendable, CaseIterable {
    case pending
    case running
    case paused
    case completed
    case failed
    case cancelled

    public var isTerminal: Bool {
        self == .completed || self == .failed || self == .cancelled
    }

    public var displayName: String {
        switch self {
        case .pending: return "等待中"
        case .running: return "下载中"
        case .paused: return "已暂停"
        case .completed: return "已完成"
        case .failed: return "失败"
        case .cancelled: return "已取消"
        }
    }
}

/// Ported from the `resume_capability` field. On iOS the equivalent fact is
/// whether `WKDownload` produced resume data, which the delegate only reports
/// once a transfer has actually started.
public enum DownloadResumeCapability: String, Codable, Sendable, CaseIterable {
    case unknown
    case resumable
    case notResumable = "not_resumable"

    public var displayName: String {
        switch self {
        case .unknown: return "未知"
        case .resumable: return "支持断点续传"
        case .notResumable: return "不支持断点续传"
        }
    }
}

/// Ported from the `failure` field of `DownloadV2TaskEntity`.
public struct DownloadFailure: Codable, Equatable, Sendable {
    public var reason: String
    public var errorCode: Int
    public var occurredAt: Date

    public init(reason: String, errorCode: Int = 0, occurredAt: Date = Date()) {
        self.reason = reason
        self.errorCode = errorCode
        self.occurredAt = occurredAt
    }

    /// The message shown in the download list. Ported from the failure copy in
    /// `DownloadManagementPage`.
    public var displayMessage: String {
        if !reason.isEmpty { return reason }
        switch errorCode {
        case -1009: return "网络连接已断开。"
        case -1001: return "请求超时。"
        case -1003: return "找不到该服务器。"
        case -1005: return "服务器中断了连接。"
        case -1100: return "文件不存在。"
        case -1102: return "没有访问权限。"
        case -3000: return "服务器返回了无效响应。"
        default: return "下载失败（错误码 \(errorCode)）。"
        }
    }
}

/// Ported from `DownloadV2TaskEntity`, flattened onto the `downloads` table.
public struct DownloadTask: Codable, Equatable, Sendable, Identifiable {
    public var id: String { guid }
    public var guid: String
    public var profileId: BrowserProfileId
    public var privacyMode: BrowserSessionPrivacyMode
    public var dataScope: BrowserDataScope
    public var requestUrl: String
    public var finalUrl: String
    public var suggestedFileName: String
    public var resolvedFileName: String
    public var mimeType: String
    public var status: DownloadStatus
    public var receivedBytes: Int64
    public var totalBytes: Int64
    public var writtenBytes: Int64
    public var destinationPath: String
    public var failure: DownloadFailure?
    public var createdAt: Date
    public var updatedAt: Date
    public var completedAt: Date?

    public init(
        guid: String = UUID().uuidString,
        profileId: BrowserProfileId = browserMainProfileId,
        privacyMode: BrowserSessionPrivacyMode = .regular,
        dataScope: BrowserDataScope = .profilePersistent,
        requestUrl: String,
        finalUrl: String = "",
        suggestedFileName: String,
        resolvedFileName: String = "",
        mimeType: String = "",
        status: DownloadStatus = .pending,
        receivedBytes: Int64 = 0,
        totalBytes: Int64 = 0,
        writtenBytes: Int64 = 0,
        destinationPath: String = "",
        failure: DownloadFailure? = nil,
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        completedAt: Date? = nil
    ) {
        self.guid = guid
        self.profileId = profileId
        self.privacyMode = privacyMode
        self.dataScope = dataScope
        self.requestUrl = requestUrl
        self.finalUrl = finalUrl
        self.suggestedFileName = suggestedFileName
        self.resolvedFileName = resolvedFileName
        self.mimeType = mimeType
        self.status = status
        self.receivedBytes = receivedBytes
        self.totalBytes = totalBytes
        self.writtenBytes = writtenBytes
        self.destinationPath = destinationPath
        self.failure = failure
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.completedAt = completedAt
    }

    /// 0...1, or nil when the server did not report a length (a chunked
    /// response), in which case the UI shows an indeterminate bar rather than a
    /// progress bar stuck at zero.
    public var progress: Double? {
        guard totalBytes > 0 else { return nil }
        return min(1, max(0, Double(receivedBytes) / Double(totalBytes)))
    }

    public var displayName: String {
        if !resolvedFileName.isEmpty { return resolvedFileName }
        if !suggestedFileName.isEmpty { return suggestedFileName }
        return "未命名文件"
    }

    /// Ported from the size formatter in `DownloadManagementPage`.
    public var displaySize: String {
        if totalBytes > 0 {
            return "\(Self.formatBytes(receivedBytes)) / \(Self.formatBytes(totalBytes))"
        }
        return Self.formatBytes(receivedBytes)
    }

    public static func formatBytes(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        formatter.allowedUnits = [.useKB, .useMB, .useGB]
        return formatter.string(fromByteCount: bytes)
    }

    public var destinationUrl: URL? {
        guard !destinationPath.isEmpty else { return nil }
        return URL(fileURLWithPath: destinationPath)
    }
}

/// Where a download is written. iOS sandboxing limits the choice to "inside the
/// app container" or "the system Files picker", which is what the two cases
/// below express.
public enum DownloadDirectoryPreference: String, Codable, Sendable, CaseIterable, Identifiable {
    /// `Documents/Downloads` in the app container, visible in the Files app.
    case appDownloads = "app_downloads"
    /// Remembered security-scoped bookmark chosen through the Files picker.
    case userSelected = "user_selected"

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .appDownloads: return "Vela 下载文件夹"
        case .userSelected: return "自选文件夹"
        }
    }

    public var detail: String {
        switch self {
        case .appDownloads:
            return "保存在 Vela 的下载文件夹中，可在「文件」App 的「我的 iPhone ▸ Vela」里看到。"
        case .userSelected:
            return "每次下载时由你在「文件」App 中选择保存位置。"
        }
    }
}

/// Ported from the download prompt decision in
/// `BrowserDownloadConfirmOverlayCoordinator` / `DownloadSettingsPage`.
public struct DownloadSettings: Codable, Equatable, Sendable {
    public var directoryPreference: DownloadDirectoryPreference
    /// Ask before starting a download instead of starting immediately.
    public var confirmBeforeDownload: Bool
    /// Keep private-mode downloads out of the visible list.
    public var separatePrivateDownloads: Bool
    /// Clear the record automatically once a download completes.
    public var autoRemoveCompleted: Bool

    public init(
        directoryPreference: DownloadDirectoryPreference = .appDownloads,
        confirmBeforeDownload: Bool = true,
        separatePrivateDownloads: Bool = true,
        autoRemoveCompleted: Bool = false
    ) {
        self.directoryPreference = directoryPreference
        self.confirmBeforeDownload = confirmBeforeDownload
        self.separatePrivateDownloads = separatePrivateDownloads
        self.autoRemoveCompleted = autoRemoveCompleted
    }

    public static let `default` = DownloadSettings()
}
