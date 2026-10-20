//
//  OfflineModels.swift
//  Vela
//
//  The values behind 离线页面: one saved document's metadata, and the small
//  manifest written beside its archive.
//
//  The database row is what the list reads; the manifest is what makes the
//  save self-describing on disk, so a page copied out of the app still says
//  which URL and title it came from.
//

import Foundation

public enum OfflinePageSaveStatus: String, Codable, Sendable {
    case saving
    case complete
    case failed
}

public enum OfflinePageOpenStatus: String, Codable, Sendable {
    case unread
    case opened
}

/// One saved page.
public struct OfflinePageRecord: Identifiable, Equatable, Sendable {
    public var id: String
    public var originalUrl: String
    public var normalizedUrl: String
    public var urlHash: String
    public var title: String
    public var siteName: String
    public var host: String
    public var savedAt: Date
    public var updatedAt: Date
    /// The web archive on disk. This is what the browser loads.
    public var snapshotPath: String
    /// The JSON description written next to the archive.
    public var manifestPath: String
    public var previewImageUri: String?
    public var faviconUri: String?
    public var totalBytes: Int64
    public var resourceCount: Int
    public var failedResourceCount: Int
    public var saveStatus: OfflinePageSaveStatus
    public var openStatus: OfflinePageOpenStatus

    public init(
        id: String = UUID().uuidString,
        originalUrl: String,
        normalizedUrl: String,
        urlHash: String,
        title: String,
        siteName: String,
        host: String,
        savedAt: Date = Date(),
        updatedAt: Date = Date(),
        snapshotPath: String,
        manifestPath: String,
        previewImageUri: String? = nil,
        faviconUri: String? = nil,
        totalBytes: Int64 = 0,
        resourceCount: Int = 0,
        failedResourceCount: Int = 0,
        saveStatus: OfflinePageSaveStatus = .complete,
        openStatus: OfflinePageOpenStatus = .unread
    ) {
        self.id = id
        self.originalUrl = originalUrl
        self.normalizedUrl = normalizedUrl
        self.urlHash = urlHash
        self.title = title
        self.siteName = siteName
        self.host = host
        self.savedAt = savedAt
        self.updatedAt = updatedAt
        self.snapshotPath = snapshotPath
        self.manifestPath = manifestPath
        self.previewImageUri = previewImageUri
        self.faviconUri = faviconUri
        self.totalBytes = totalBytes
        self.resourceCount = resourceCount
        self.failedResourceCount = failedResourceCount
        self.saveStatus = saveStatus
        self.openStatus = openStatus
    }

    public var displayTitle: String {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { return trimmed }
        if !host.isEmpty { return host }
        return originalUrl
    }

    public var displaySiteName: String {
        let trimmed = siteName.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? host : trimmed
    }

    public var displaySize: String {
        ByteCountFormatter.string(fromByteCount: totalBytes, countStyle: .file)
    }
}

/// The JSON written next to a saved archive.
public struct OfflinePageManifest: Codable, Equatable, Sendable {
    public var version: Int
    public var url: String
    public var title: String
    public var savedAt: Date
    public var resourceCount: Int
    public var failedResourceCount: Int
    public var totalBytes: Int64

    public init(
        version: Int = 1,
        url: String,
        title: String,
        savedAt: Date = Date(),
        resourceCount: Int,
        failedResourceCount: Int = 0,
        totalBytes: Int64
    ) {
        self.version = version
        self.url = url
        self.title = title
        self.savedAt = savedAt
        self.resourceCount = resourceCount
        self.failedResourceCount = failedResourceCount
        self.totalBytes = totalBytes
    }
}

public enum OfflinePageError: LocalizedError {
    case invalidUrl
    case noDocument
    case archiveFailed(String)
    case writeFailed(String)

    public var errorDescription: String? {
        switch self {
        case .invalidUrl:
            return "这个页面没有可以保存的网址。"
        case .noDocument:
            return "页面上还没有已加载的文档，稍后再试。"
        case let .archiveFailed(message):
            return "无法生成页面存档：\(message)"
        case let .writeFailed(message):
            return "无法写入离线文件：\(message)"
        }
    }
}
