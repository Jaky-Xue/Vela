//
//  BookmarkService.swift
//  Vela
//
//  Observable bookmark state over `BookmarkRepository`.
//
//  The service holds no state beyond the trees it publishes: every mutation goes
//  to the repository and then re-reads. That is slower than patching an in-memory
//  model, but it makes the tree impossible to drift from the database — which
//  matters because the same rows are what the sync providers push.
//

import Foundation
import Observation

@MainActor
@Observable
public final class BookmarkService {
    public private(set) var toolbarTree: BookmarkTreeItem?
    public private(set) var otherTree: BookmarkTreeItem?
    public private(set) var allBookmarks: [BookmarkNode] = []
    public private(set) var lastError: String?

    private let repository: BookmarkRepository
    private var roots: [BookmarkRoot] = []

    public init(repository: BookmarkRepository) {
        self.repository = repository
    }

    /// Loads the roots and both trees. Called once at launch and after every
    /// mutation.
    public func reload() {
        do {
            roots = try repository.ensureRoots()
            toolbarTree = try repository.loadTree(rootNodeId: rootNodeId(for: .toolbar) ?? "").flatMap { $0 }
            otherTree = try repository.loadTree(rootNodeId: rootNodeId(for: .other) ?? "").flatMap { $0 }
            allBookmarks = try repository.allBookmarks()
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
    }

    public func rootNodeId(for role: BookmarkRootRole) -> String? {
        roots.first { $0.role == role }?.nodeId
    }

    public var toolbarRootNodeId: String? { rootNodeId(for: .toolbar) }
    public var otherRootNodeId: String? { rootNodeId(for: .other) }

    // MARK: - Reading

    /// Children of a folder, ordered.
    public func children(of parentNodeId: String) -> [BookmarkTreeItem] {
        for tree in [toolbarTree, otherTree].compactMap({ $0 }) {
            if let found = findChildren(in: tree, parentId: parentNodeId) {
                return found
            }
        }
        return []
    }

    private func findChildren(in item: BookmarkTreeItem, parentId: String) -> [BookmarkTreeItem]? {
        if item.node.id == parentId { return item.children }
        for child in item.children {
            if let found = findChildren(in: child, parentId: parentId) { return found }
        }
        return nil
    }

    public func search(_ query: String) -> [BookmarkNode] {
        (try? repository.search(query)) ?? []
    }

    /// The bookmark for a URL, if any — what the toolbar's star reflects.
    public func bookmark(for url: String) -> BookmarkNode? {
        try? repository.isBookmarked(url: url)
    }

    public func isBookmarked(_ url: String) -> Bool {
        bookmark(for: url) != nil
    }

    public func folderPickerItems(excludingSubtreeOf nodeId: String?) -> [BookmarkFolderPickerItem] {
        (try? repository.folderPickerItems(excludingSubtreeOf: nodeId)) ?? []
    }

    // MARK: - Writing

    /// Adds a bookmark to a folder. Ported from
    /// `BrowserBookmarkActionCoordinator`: a bookmark added with no explicit
    /// folder lands in the root the user is browsing, defaulting to "其他书签"
    /// for a mobile-sized surface.
    @discardableResult
    public func addBookmark(
        url: String,
        title: String,
        parentNodeId: String? = nil
    ) -> BookmarkNode? {
        guard let normalized = HistoryUrlNormalizer.normalize(url) else { return nil }
        // Adding the same URL twice is a no-op rather than a second row, which
        // is the guard the star button relies on.
        if bookmark(for: normalized) != nil { return nil }

        let parent = parentNodeId ?? otherRootNodeId
        let node = BookmarkNode(
            type: .bookmark,
            title: title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? (URL(string: normalized)?.host ?? normalized)
                : title,
            url: normalized
        )
        do {
            try repository.insertNode(node)
            try repository.appendToParent(parentId: parent, childId: node.id)
            reload()
            return node
        } catch {
            lastError = error.localizedDescription
            return nil
        }
    }

    @discardableResult
    public func addFolder(title: String, parentNodeId: String? = nil) -> BookmarkNode? {
        let node = BookmarkNode(type: .folder, title: title)
        do {
            try repository.insertNode(node)
            try repository.appendToParent(parentId: parentNodeId ?? otherRootNodeId, childId: node.id)
            reload()
            return node
        } catch {
            lastError = error.localizedDescription
            return nil
        }
    }

    /// Removes a bookmark by URL — what the star button does on a second tap.
    public func removeBookmark(url: String) {
        guard let node = bookmark(for: url) else { return }
        removeNode(id: node.id)
    }

    /// Soft-deletes a node and its subtree.
    public func removeNode(id: String) {
        do {
            try repository.softDeleteSubtree(rootId: id)
            reload()
        } catch {
            lastError = error.localizedDescription
        }
    }

    public func rename(id: String, title: String) {
        guard var node = try? repository.node(id: id) else { return }
        node.title = title
        node.updatedAt = Date()
        node.lastModifiedAt = Date()
        node.syncState = .pendingPush
        do {
            try repository.updateNode(node)
            reload()
        } catch {
            lastError = error.localizedDescription
        }
    }

    public func updateUrl(id: String, url: String) {
        guard var node = try? repository.node(id: id),
              let normalized = HistoryUrlNormalizer.normalize(url) else { return }
        node.url = normalized
        node.updatedAt = Date()
        node.lastModifiedAt = Date()
        node.syncState = .pendingPush
        do {
            try repository.updateNode(node)
            reload()
        } catch {
            lastError = error.localizedDescription
        }
    }

    public func move(nodeId: String, toParent parentNodeId: String?) {
        do {
            try repository.move(childId: nodeId, toParent: parentNodeId)
            reload()
        } catch {
            lastError = error.localizedDescription
        }
    }

    public func reorder(parentNodeId: String?, orderedChildIds: [String]) {
        do {
            try repository.reorder(parentId: parentNodeId, orderedChildIds: orderedChildIds)
            reload()
        } catch {
            lastError = error.localizedDescription
        }
    }

    /// Empties a root folder. Ported from the "清空" action in the bookmark
    /// manager, which is scoped to one root so it can never take the whole tree.
    public func clearRoot(_ role: BookmarkRootRole) {
        guard let nodeId = rootNodeId(for: role) else { return }
        do {
            try repository.deleteAll(inRootNodeId: nodeId)
            reload()
        } catch {
            lastError = error.localizedDescription
        }
    }
}
