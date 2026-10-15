//
//  BookmarkRepository.swift
//  Vela
//
//  Persistence for the bookmark tree.
//
//  Deletion is a stamp on `deleted_at`, never a row removal. A tombstone has to
//  outlive the local delete so a sync peer can observe it, which is why every
//  read in this file filters `deleted_at IS NULL`.
//

import Foundation

public final class BookmarkRepository: @unchecked Sendable {
    private let database: SQLiteDatabase

    public init(database: SQLiteDatabase) {
        self.database = database
    }

    // MARK: - Roots

    /// Ensures the two shipped roots exist and returns them.
    ///
    /// The check is "does a root row exist", not "is the table empty", so a user
    /// who deleted every bookmark still gets their roots back on next launch.
    @discardableResult
    public func ensureRoots() throws -> [BookmarkRoot] {
        var roots = try loadRoots()
        for (index, role) in [BookmarkRootRole.toolbar, .other].enumerated() {
            guard !roots.contains(where: { $0.role == role }) else { continue }
            let node = BookmarkNode(type: .folder, title: role.displayName)
            try insertNode(node)
            try database.execute(
                """
                INSERT OR REPLACE INTO \(BrowserSchema.bookmarkRootsTable)
                (role, node_id, title, position, sync_enabled) VALUES (?, ?, ?, ?, 0)
                """,
                [.text(role.rawValue), .text(node.id), .text(role.displayName), .integer(Int64(index))]
            )
            roots.append(
                BookmarkRoot(
                    role: role,
                    nodeId: node.id,
                    title: role.displayName,
                    position: index
                )
            )
        }
        return roots.sorted { $0.position < $1.position }
    }

    public func loadRoots() throws -> [BookmarkRoot] {
        try database.query(
            """
            SELECT role, node_id, title, position, sync_enabled
            FROM \(BrowserSchema.bookmarkRootsTable) ORDER BY position
            """
        ) { statement in
            BookmarkRoot(
                role: BookmarkRootRole(rawValue: statement.string(at: 0)) ?? .other,
                nodeId: statement.string(at: 1),
                title: statement.string(at: 2),
                position: Int(statement.int(at: 3)),
                syncEnabled: statement.bool(at: 4)
            )
        }
    }

    public func rootRole(forNodeId nodeId: String) throws -> BookmarkRootRole? {
        try loadRoots().first { $0.nodeId == nodeId }?.role
    }

    // MARK: - Nodes

    private static let nodeColumns = """
    id, scope, type, title, url, created_at, updated_at, sync_state, sync_source, \
    last_modified_at, last_modified_by, device_id, origin_id, deleted_at
    """

    private func node(from statement: SQLiteStatement) -> BookmarkNode {
        BookmarkNode(
            id: statement.string(at: 0),
            scope: BookmarkStorageScope(rawValue: statement.string(at: 1)) ?? .regular,
            type: BookmarkNodeType(rawValue: statement.string(at: 2)) ?? .bookmark,
            title: statement.string(at: 3),
            url: statement.optionalString(at: 4),
            createdAt: Date(milliseconds: statement.int(at: 5)),
            updatedAt: Date(milliseconds: statement.int(at: 6)),
            syncState: SyncState(rawValue: statement.string(at: 7)) ?? .localOnly,
            syncSource: BrowserDataSource(rawValue: statement.string(at: 8)) ?? .local,
            lastModifiedAt: Date(milliseconds: statement.int(at: 9)),
            lastModifiedBy: statement.string(at: 10),
            deviceId: statement.string(at: 11),
            originId: statement.optionalString(at: 12),
            deletedAt: statement.optionalInt(at: 13).map { Date(milliseconds: $0) }
        )
    }

    public func insertNode(_ node: BookmarkNode) throws {
        try database.execute(
            """
            INSERT INTO \(BrowserSchema.bookmarkNodesTable)
            (\(Self.nodeColumns)) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """,
            [
                .text(node.id),
                .text(node.scope.rawValue),
                .text(node.type.rawValue),
                .text(node.title),
                node.url.map { SQLiteValue.text($0) } ?? .null,
                .integer(node.createdAt.milliseconds),
                .integer(node.updatedAt.milliseconds),
                .text(node.syncState.rawValue),
                .text(node.syncSource.rawValue),
                .integer(node.lastModifiedAt.milliseconds),
                .text(node.lastModifiedBy.isEmpty ? BrowserIdentity.deviceId : node.lastModifiedBy),
                .text(node.deviceId),
                node.originId.map { SQLiteValue.text($0) } ?? .null,
                node.deletedAt.map { SQLiteValue.integer($0.milliseconds) } ?? .null
            ]
        )
    }

    public func updateNode(_ node: BookmarkNode) throws {
        try database.execute(
            """
            UPDATE \(BrowserSchema.bookmarkNodesTable)
            SET scope = ?, type = ?, title = ?, url = ?, updated_at = ?,
                sync_state = ?, sync_source = ?, last_modified_at = ?,
                last_modified_by = ?, origin_id = ?, deleted_at = ?
            WHERE id = ?
            """,
            [
                .text(node.scope.rawValue),
                .text(node.type.rawValue),
                .text(node.title),
                node.url.map { SQLiteValue.text($0) } ?? .null,
                .integer(node.updatedAt.milliseconds),
                .text(node.syncState.rawValue),
                .text(node.syncSource.rawValue),
                .integer(node.lastModifiedAt.milliseconds),
                .text(node.lastModifiedBy.isEmpty ? BrowserIdentity.deviceId : node.lastModifiedBy),
                node.originId.map { SQLiteValue.text($0) } ?? .null,
                node.deletedAt.map { SQLiteValue.integer($0.milliseconds) } ?? .null,
                .text(node.id)
            ]
        )
    }

    public func node(id: String) throws -> BookmarkNode? {
        try database.query(
            "SELECT \(Self.nodeColumns) FROM \(BrowserSchema.bookmarkNodesTable) WHERE id = ? AND deleted_at IS NULL",
            [.text(id)],
            row: node(from:)
        ).first
    }

    /// Soft-deletes a node and every descendant.
    ///
    /// A folder tombstone alone would leave its children live and visible to a
    /// sync peer, so the whole subtree is stamped in one transaction.
    public func softDeleteSubtree(rootId: String) throws {
        let allOrders = try loadOrders()
        let allNodes = try loadAllNodesIncludingDeleted()

        var doomed: Set<String> = [rootId]
        var frontier = [rootId]
        while let current = frontier.popLast() {
            let children = allOrders.filter { $0.parentId == current }.map(\.childId)
            for child in children where !doomed.contains(child) {
                doomed.insert(child)
                frontier.append(child)
            }
        }

        let now = Date()
        try database.transaction {
            for id in doomed {
                guard var node = allNodes.first(where: { $0.id == id }) else { continue }
                node.deletedAt = now
                node.updatedAt = now
                node.lastModifiedAt = now
                node.syncState = .pendingPush
                try updateNode(node)
            }
            for id in doomed {
                try database.execute(
                    "DELETE FROM \(BrowserSchema.bookmarkOrdersTable) WHERE child_id = ?",
                    [.text(id)]
                )
            }
        }
    }

    public func deleteAll(inRootNodeId rootNodeId: String) throws {
        try softDeleteSubtree(rootId: rootNodeId)
    }

    // MARK: - Orders

    public struct BookmarkOrder: Equatable, Sendable {
        public var parentId: String?
        public var childId: String
        public var position: Int
        public var updatedAt: Date
    }

    public func loadOrders() throws -> [BookmarkOrder] {
        try database.query(
            """
            SELECT parent_id, child_id, position, updated_at
            FROM \(BrowserSchema.bookmarkOrdersTable) ORDER BY position
            """
        ) { statement in
            BookmarkOrder(
                parentId: statement.optionalString(at: 0),
                childId: statement.string(at: 1),
                position: Int(statement.int(at: 2)),
                updatedAt: Date(milliseconds: statement.int(at: 3))
            )
        }
    }

    /// Appends a node to the end of its parent's child list.
    ///
    /// Order is dense, so the new position is `max + 1` within the parent rather
    /// than a global counter.
    public func appendToParent(parentId: String?, childId: String) throws {
        let next = try nextPosition(inParent: parentId)
        try database.execute(
            """
            INSERT OR REPLACE INTO \(BrowserSchema.bookmarkOrdersTable)
            (parent_id, child_id, position, updated_at) VALUES (?, ?, ?, ?)
            """,
            [
                parentId.map { SQLiteValue.text($0) } ?? .null,
                .text(childId),
                .integer(Int64(next)),
                .integer(Date().milliseconds)
            ]
        )
    }

    private func nextPosition(inParent parentId: String?) throws -> Int {
        let sql: String
        let values: [SQLiteValue]
        if let parentId {
            sql = """
            SELECT COALESCE(MAX(position), -1) FROM \(BrowserSchema.bookmarkOrdersTable) WHERE parent_id = ?
            """
            values = [.text(parentId)]
        } else {
            sql = """
            SELECT COALESCE(MAX(position), -1) FROM \(BrowserSchema.bookmarkOrdersTable) WHERE parent_id IS NULL
            """
            values = []
        }
        return Int(try database.scalarInt(sql, values)) + 1
    }

    /// Rewrites the child order under one parent.
    ///
    /// Positions are written densely from the
    /// array order, so an interrupted reorder can only lose the tail of the
    /// move, never scatter positions.
    public func reorder(parentId: String?, orderedChildIds: [String]) throws {
        let now = Date().milliseconds
        try database.transaction {
            for (index, childId) in orderedChildIds.enumerated() {
                try database.execute(
                    """
                    INSERT OR REPLACE INTO \(BrowserSchema.bookmarkOrdersTable)
                    (parent_id, child_id, position, updated_at) VALUES (?, ?, ?, ?)
                    """,
                    [
                        parentId.map { SQLiteValue.text($0) } ?? .null,
                        .text(childId),
                        .integer(Int64(index)),
                        .integer(now)
                    ]
                )
            }
        }
    }

    public func move(childId: String, toParent parentId: String?) throws {
        let now = Date().milliseconds
        try database.transaction {
            try database.execute(
                """
                UPDATE \(BrowserSchema.bookmarkOrdersTable)
                SET parent_id = ?, updated_at = ? WHERE child_id = ?
                """,
                [parentId.map { SQLiteValue.text($0) } ?? .null, .integer(now), .text(childId)]
            )
            let siblings = try database.query(
                """
                SELECT child_id FROM \(BrowserSchema.bookmarkOrdersTable)
                WHERE parent_id IS ? ORDER BY position
                """,
                [parentId.map { SQLiteValue.text($0) } ?? .null]
            ) { $0.string(at: 0) }
            let reordered = siblings.filter { $0 != childId } + [childId]
            try reorder(parentId: parentId, orderedChildIds: reordered)
        }
    }

    // MARK: - Tree

    private func loadAllNodesIncludingDeleted() throws -> [BookmarkNode] {
        try database.query(
            "SELECT \(Self.nodeColumns) FROM \(BrowserSchema.bookmarkNodesTable)",
            row: node(from:)
        )
    }

    /// Loads the whole live tree under a root.
    ///
    /// then a recursive build. The order map is keyed by parent so the build is
    /// linear in node count rather than quadratic.
    public func loadTree(rootNodeId: String) throws -> BookmarkTreeItem? {
        let nodes = try database.query(
            "SELECT \(Self.nodeColumns) FROM \(BrowserSchema.bookmarkNodesTable) WHERE deleted_at IS NULL",
            row: node(from:)
        )
        let orders = try loadOrders()

        let nodesById = Dictionary(uniqueKeysWithValues: nodes.map { ($0.id, $0) })
        guard let root = nodesById[rootNodeId] else { return nil }

        var ordersByParent: [String: [BookmarkOrder]] = [:]
        for order in orders {
            guard let parentId = order.parentId else { continue }
            ordersByParent[parentId, default: []].append(order)
        }

        func build(node: BookmarkNode, depth: Int) -> BookmarkTreeItem {
            guard node.isFolder, depth < 32 else {
                return BookmarkTreeItem(node: node, position: 0)
            }
            let children = (ordersByParent[node.id] ?? [])
                .sorted { $0.position < $1.position }
                .compactMap { order -> BookmarkTreeItem? in
                    guard let child = nodesById[order.childId] else { return nil }
                    return build(node: child, depth: depth + 1)
                }
            return BookmarkTreeItem(node: node, position: 0, children: children)
        }

        return build(node: root, depth: 0)
    }

    /// Every live bookmark, newest first — the flat list the search index and
    /// the omnibox suggestions read.
    public func allBookmarks() throws -> [BookmarkNode] {
        try database.query(
            """
            SELECT \(Self.nodeColumns) FROM \(BrowserSchema.bookmarkNodesTable)
            WHERE deleted_at IS NULL AND type = 'bookmark'
            ORDER BY created_at DESC
            """,
            row: node(from:)
        )
    }

    /// Searches titles and URLs.
    ///
    /// The index is the `title` and
    /// `url` indexes rather than a full-text table, which is adequate at the
    /// scale a personal bookmark set reaches.
    public func search(_ query: String, limit: Int = 30) throws -> [BookmarkNode] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        let pattern = "%\(trimmed.replacingOccurrences(of: "%", with: "\\%"))%"
        return try database.query(
            """
            SELECT \(Self.nodeColumns) FROM \(BrowserSchema.bookmarkNodesTable)
            WHERE deleted_at IS NULL AND type = 'bookmark'
              AND (title LIKE ? OR url LIKE ?)
            ORDER BY updated_at DESC LIMIT ?
            """,
            [.text(pattern), .text(pattern), .integer(Int64(limit))],
            row: node(from:)
        )
    }

    public func isBookmarked(url: String) throws -> BookmarkNode? {
        guard let normalized = HistoryUrlNormalizer.normalize(url) else { return nil }
        return try database.query(
            """
            SELECT \(Self.nodeColumns) FROM \(BrowserSchema.bookmarkNodesTable)
            WHERE deleted_at IS NULL AND url = ? LIMIT 1
            """,
            [.text(normalized)],
            row: node(from:)
        ).first
    }

    /// Folders a node may be moved into, excluding its own subtree.
    ///
    public func folderPickerItems(excludingSubtreeOf excludedId: String?) throws -> [BookmarkFolderPickerItem] {
        // Orders are read once and grouped by parent. Reading them inside the
        // walk would make the picker quadratic in the number of folders, and a
        // bookmark tree of a few thousand entries is not unusual.
        let allOrders = try loadOrders()
        var ordersByParent: [String: [BookmarkOrder]] = [:]
        for order in allOrders {
            guard let parentId = order.parentId else { continue }
            ordersByParent[parentId, default: []].append(order)
        }

        var excluded: Set<String> = []
        if let excludedId {
            var frontier = [excludedId]
            excluded.insert(excludedId)
            while let current = frontier.popLast() {
                for order in ordersByParent[current] ?? [] where !excluded.contains(order.childId) {
                    excluded.insert(order.childId)
                    frontier.append(order.childId)
                }
            }
        }

        let liveNodes = try database.query(
            "SELECT \(Self.nodeColumns) FROM \(BrowserSchema.bookmarkNodesTable) WHERE deleted_at IS NULL",
            row: node(from:)
        )
        let nodesById = Dictionary(uniqueKeysWithValues: liveNodes.map { ($0.id, $0) })

        var items: [BookmarkFolderPickerItem] = []

        func walk(_ nodeId: String, depth: Int) {
            guard depth < 32 else { return }
            for order in (ordersByParent[nodeId] ?? []).sorted(by: { $0.position < $1.position }) {
                guard !excluded.contains(order.childId),
                      let child = nodesById[order.childId],
                      child.isFolder else { continue }
                items.append(BookmarkFolderPickerItem(node: child, depth: depth))
                walk(child.id, depth: depth + 1)
            }
        }

        for root in try ensureRoots() {
            guard !excluded.contains(root.nodeId),
                  let rootNode = nodesById[root.nodeId] else { continue }
            items.append(BookmarkFolderPickerItem(node: rootNode, depth: 0))
            walk(root.nodeId, depth: 1)
        }
        return items
    }
}

// MARK: - Timestamp helpers

extension Date {
    /// Milliseconds since the epoch. Every timestamp column in the schema is an
    /// INTEGER in milliseconds, which is what an imported database holds too.
    public var milliseconds: Int64 {
        Int64((timeIntervalSince1970 * 1000).rounded())
    }

    public init(milliseconds: Int64) {
        self.init(timeIntervalSince1970: Double(milliseconds) / 1000)
    }
}
