//
//  BookmarkModels.swift
//  Vela
//
//  The bookmark tree: folders, bookmarks and their ordering.
//
//  Folders, bookmarks and order are three tables rather than one. Keeping order
//  apart from content is what makes a drag-reorder a small update instead of a
//  rewrite of every moved subtree, and it is what lets a sync provider push
//  order changes independently of content changes.
//

import Foundation

/// Ported from `BookmarkNodeType`.
public enum BookmarkNodeType: String, Codable, Sendable, CaseIterable {
    case folder
    case bookmark
}

public enum BookmarkRootRole: String, Codable, Sendable, CaseIterable, Identifiable {
    case toolbar
    case other
    /// The mobile reading list. It is a root of its own rather than a folder
    /// under `other`, and it is written with a raw value the other roots do not
    /// use, so an export that only understands `toolbar` and `other` still
    /// round-trips it.
    case readingList = "reading_list"

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .toolbar: return "书签栏"
        case .other: return "其他书签"
        case .readingList: return "阅读列表"
        }
    }
}

/// Ported from `BookmarkStorageScope`.
public enum BookmarkStorageScope: String, Codable, Sendable, CaseIterable {
    case regular
    case `private`
}

/// Ported from the `bookmark_roots` row.
public struct BookmarkRoot: Codable, Equatable, Sendable, Identifiable {
    public var id: String { role.rawValue }
    public var role: BookmarkRootRole
    public var nodeId: String
    public var title: String
    public var position: Int
    public var syncEnabled: Bool

    public init(
        role: BookmarkRootRole,
        nodeId: String,
        title: String,
        position: Int,
        syncEnabled: Bool = false
    ) {
        self.role = role
        self.nodeId = nodeId
        self.title = title
        self.position = position
        self.syncEnabled = syncEnabled
    }
}

/// Ported from the `bookmark_nodes` row.
public struct BookmarkNode: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var scope: BookmarkStorageScope
    public var type: BookmarkNodeType
    public var title: String
    /// Nil for folders; non-nil for bookmarks.
    public var url: String?
    public var createdAt: Date
    public var updatedAt: Date
    public var syncState: SyncState
    public var syncSource: BrowserDataSource
    public var lastModifiedAt: Date
    public var lastModifiedBy: String
    public var deviceId: String
    public var originId: String?
    /// Non-nil when the node is deleted. Ported from the soft-delete column:
    /// a tombstone has to survive long enough for a sync provider to see it,
    /// so deletion is a stamp rather than a row removal.
    public var deletedAt: Date?

    public init(
        id: String = UUID().uuidString,
        scope: BookmarkStorageScope = .regular,
        type: BookmarkNodeType,
        title: String,
        url: String? = nil,
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        syncState: SyncState = .localOnly,
        syncSource: BrowserDataSource = .local,
        lastModifiedAt: Date = Date(),
        lastModifiedBy: String = "",
        deviceId: String = BrowserIdentity.deviceId,
        originId: String? = nil,
        deletedAt: Date? = nil
    ) {
        self.id = id
        self.scope = scope
        self.type = type
        self.title = title
        self.url = url
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.syncState = syncState
        self.syncSource = syncSource
        self.lastModifiedAt = lastModifiedAt
        self.lastModifiedBy = lastModifiedBy
        self.deviceId = deviceId
        self.originId = originId
        self.deletedAt = deletedAt
    }

    public var isFolder: Bool { type == .folder }
    public var isDeleted: Bool { deletedAt != nil }

    /// The host shown under the title in the bookmark list.
    public var displayHost: String {
        guard let url, let parsed = URL(string: url), let host = parsed.host else { return "" }
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }
}

/// A node together with its ordering and resolved children — the shape the
/// bookmark UI renders. Ported from `BookmarkTreeItem`.
public struct BookmarkTreeItem: Identifiable, Sendable {
    public var id: String { node.id }
    public var node: BookmarkNode
    public var position: Int
    public var children: [BookmarkTreeItem]

    public init(node: BookmarkNode, position: Int, children: [BookmarkTreeItem] = []) {
        self.node = node
        self.position = position
        self.children = children
    }

    public var childCount: Int { children.count }

    /// Total nodes underneath. The list caches this so a folder's count is not
    /// recomputed on every render.
    public var descendantCount: Int {
        children.reduce(children.count) { $0 + $1.descendantCount }
    }
}

/// The folder picker excludes the subtree being moved, so a folder cannot be
/// dropped into its own descendant.
public struct BookmarkFolderPickerItem: Identifiable, Sendable {
    public var id: String { node.id }
    public var node: BookmarkNode
    public var depth: Int
}

/// Process-wide identity values.
///
/// The device identifier is generated once and kept in `UserDefaults`. It is
/// stamped on every syncable row, so a reinstall produces a new one and rows
/// written under the old value read as another device's.
public enum BrowserIdentity {
    private static let deviceIdKey = "org.vela.browser.device-id"

    public static let deviceId: String = {
        if let existing = UserDefaults.standard.string(forKey: deviceIdKey) {
            return existing
        }
        let generated = UUID().uuidString
        UserDefaults.standard.set(generated, forKey: deviceIdKey)
        return generated
    }()
}
