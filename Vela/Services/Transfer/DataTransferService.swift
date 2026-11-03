//
//  DataTransferService.swift
//  Vela
//
//  Import and export for the two lists a user most wants to carry between
//  devices: bookmarks and history.
//
//  Everything here is explicit file transfer. The app has no cloud entitlement
//  in its current distribution, so a file the user saves is the migration
//  path; the formats are the ones other browsers already speak.
//

import Foundation

@MainActor
public struct DataTransferService {
    public struct Summary: Sendable {
        public var added: Int
        public var skipped: Int
        public var message: String

        public init(added: Int, skipped: Int, message: String) {
            self.added = added
            self.skipped = skipped
            self.message = message
        }
    }

    private let bookmarks: BookmarkService
    private let history: HistoryService

    public init(bookmarks: BookmarkService, history: HistoryService) {
        self.bookmarks = bookmarks
        self.history = history
    }

    // MARK: Bookmarks

    public func bookmarksHTML() -> String {
        var roots: [(title: String, items: [BookmarkTreeItem])] = []
        if let tree = bookmarks.toolbarTree {
            roots.append(("书签栏", tree.children))
        }
        if let tree = bookmarks.otherTree {
            roots.append(("其他书签", tree.children))
        }
        return BookmarkExchange.netscapeHTML(roots: roots)
    }

    public func importBookmarks(html: String) -> Summary {
        let nodes = BookmarkExchange.parseNetscapeHTML(html)
        guard !nodes.isEmpty else {
            return Summary(added: 0, skipped: 0, message: "文件里没有可导入的书签。")
        }
        let stamp = Date().formatted(date: .numeric, time: .omitted)
        let folder = bookmarks.addFolder(title: "导入的书签 \(stamp)")
        let parent = folder?.id ?? bookmarks.otherRootNodeId
        let counts = add(nodes, parent: parent)
        bookmarks.reload()
        return Summary(
            added: counts.added,
            skipped: counts.skipped,
            message: "已导入 \(counts.added) 个书签" + (counts.skipped > 0 ? "，跳过 \(counts.skipped) 个（已存在或地址无效）。" : "。")
        )
    }

    private func add(_ nodes: [ImportedBookmarkNode], parent: String?) -> (added: Int, skipped: Int) {
        var added = 0
        var skipped = 0
        for node in nodes {
            if let url = node.url, !url.isEmpty {
                if bookmarks.addBookmark(url: url, title: node.title, parentNodeId: parent) != nil {
                    added += 1
                } else {
                    skipped += 1
                }
            } else {
                let title = node.title.isEmpty ? "未命名文件夹" : node.title
                guard let folder = bookmarks.addFolder(title: title, parentNodeId: parent) else {
                    skipped += 1
                    continue
                }
                added += 1
                let counts = add(node.children, parent: folder.id)
                added += counts.added
                skipped += counts.skipped
            }
        }
        return (added, skipped)
    }

    // MARK: History

    public func historyJSON() -> Data {
        HistoryExchange.json(from: history.allVisited())
    }

    public func importHistory(_ data: Data) throws -> Summary {
        let entries = try HistoryExchange.parse(data)
        var added = 0
        var skipped = 0
        for entry in entries {
            guard let url = URL(string: entry.url), url.scheme != nil else {
                skipped += 1
                continue
            }
            history.recordVisit(
                url: url,
                title: entry.title,
                tabId: "import-\(UUID().uuidString)",
                boundary: .persistent,
                transition: .autoBookmark
            )
            added += 1
        }
        history.reload()
        return Summary(
            added: added,
            skipped: skipped,
            message: "已导入 \(added) 条历史记录" + (skipped > 0 ? "，跳过 \(skipped) 条无效地址。" : "。")
        )
    }
}
