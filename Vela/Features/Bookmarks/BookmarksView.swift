//
//  BookmarksView.swift
//  Vela
//
//  The bookmark manager. Ported from `AiraBrowser/entry/src/main/ets/app/pages/BookmarkManagerPage.ets`,
//  `BrowserBookmarkScopeService.ets` and `BookmarkFolderSelectionViewModel.ets`
//  (Aira Browser 3.7.4, GPL-3.0).
//
//  Two roots, one list. A folder opens in place rather than pushing a screen,
//  which is what Aira's ArkUI list does and what keeps the toolbar counts
//  meaningful at every depth.
//

import SwiftUI
import UIKit

struct BookmarksView: View {
    @EnvironmentObject private var env: AppEnvironment
    @Environment(\.dismiss) private var dismiss

    @State private var path: [String] = []
    @State private var searchText = ""
    @State private var editingNode: BookmarkNode?
    @State private var showingNewFolder = false
    @State private var newFolderName = ""
    @State private var nodeToDelete: BookmarkNode?

    private var bookmarks: BookmarkService { env.bookmarks }

    private var isSearching: Bool {
        !searchText.trimmingCharacters(in: .whitespaces).isEmpty
    }

    /// The folder currently being browsed, or nil at a root.
    private var currentFolderId: String? {
        path.last
    }

    private var currentItems: [BookmarkTreeItem] {
        if isSearching {
            return bookmarks.search(searchText).map {
                BookmarkTreeItem(node: $0, position: 0)
            }
        }
        guard let folderId = currentFolderId else {
            return [bookmarks.toolbarTree, bookmarks.otherTree].compactMap { $0 }
        }
        return bookmarks.children(of: folderId)
    }

    private var currentTitle: String {
        guard let folderId = currentFolderId else { return "书签" }
        return bookmarks.allBookmarks.first { $0.id == folderId }?.title ?? "书签"
    }

    var body: some View {
        List {
            if currentItems.isEmpty {
                BrowserEmptyState(
                    systemImage: "bookmark",
                    title: isSearching ? "没有匹配的书签" : "还没有书签",
                    message: isSearching
                        ? "换个关键词试试。"
                        : "浏览网页时点菜单里的「添加到书签」。"
                )
                .listRowBackground(Color.clear)
            } else {
                ForEach(currentItems) { item in
                    row(for: item)
                }
                .onDelete(perform: deleteItems)
                .onMove(perform: moveItems)
            }
        }
        .listStyle(.plain)
        .searchable(text: $searchText, prompt: "搜索书签")
        .navigationTitle(isSearching ? "搜索结果" : currentTitle)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                if !path.isEmpty, !isSearching {
                    Button {
                        path.removeLast()
                    } label: {
                        Image(systemName: "chevron.left")
                    }
                } else {
                    Button("完成") { dismiss() }
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    if let folderId = currentFolderId {
                        Button("新建文件夹", systemImage: "folder.badge.plus") {
                            newFolderName = ""
                            showingNewFolder = true
                        }
                        Button("清空此文件夹", systemImage: "trash", role: .destructive) {
                            bookmarks.reorder(parentNodeId: folderId, orderedChildIds: [])
                            for item in currentItems {
                                bookmarks.removeNode(id: item.node.id)
                            }
                        }
                    }
                    Divider()
                    Button("清空书签栏", systemImage: "trash", role: .destructive) {
                        bookmarks.clearRoot(.toolbar)
                    }
                    Button("清空其他书签", systemImage: "trash", role: .destructive) {
                        bookmarks.clearRoot(.other)
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
            }
        }
        .editModeSupport()
        .alert("新建文件夹", isPresented: $showingNewFolder) {
            TextField("名称", text: $newFolderName)
            Button("取消", role: .cancel) {}
            Button("创建") {
                let name = newFolderName.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !name.isEmpty else { return }
                bookmarks.addFolder(title: name, parentNodeId: currentFolderId)
            }
        }
        .alert(
            "删除「\(nodeToDelete?.title ?? "")」？",
            isPresented: Binding(
                get: { nodeToDelete != nil },
                set: { if !$0 { nodeToDelete = nil } }
            )
        ) {
            Button("取消", role: .cancel) { nodeToDelete = nil }
            Button("删除", role: .destructive) {
                if let node = nodeToDelete { bookmarks.removeNode(id: node.id) }
                nodeToDelete = nil
            }
        } message: {
            if nodeToDelete?.isFolder == true {
                Text("文件夹里的内容会一起删除。")
            }
        }
        .sheet(item: $editingNode) { node in
            BookmarkEditSheet(node: node) { title, url in
                bookmarks.rename(id: node.id, title: title)
                if let url, url != node.url {
                    bookmarks.updateUrl(id: node.id, url: url)
                }
            }
        }
    }

    // MARK: - Rows

    @ViewBuilder
    private func row(for item: BookmarkTreeItem) -> some View {
        let node = item.node
        Button {
            if node.isFolder {
                path.append(node.id)
            } else if let urlString = node.url, let url = URL(string: urlString) {
                openInBrowser(url)
            }
        } label: {
            HStack(spacing: 12) {
                if node.isFolder {
                    Image(systemName: "folder.fill")
                        .font(.system(size: 16))
                        .foregroundStyle(.tint)
                        .frame(width: 28, height: 28)
                } else {
                    SiteIconView(host: node.displayHost, size: 28)
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text(node.title)
                        .font(.body)
                        .lineLimit(1)
                        .foregroundStyle(.primary)
                    if !node.isFolder {
                        Text(node.displayHost)
                            .font(.caption)
                            .lineLimit(1)
                            .foregroundStyle(.secondary)
                    } else {
                        Text("\(item.descendantCount) 项")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Spacer(minLength: 0)

                if node.isFolder {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .buttonStyle(.plain)
        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
            Button(role: .destructive) {
                nodeToDelete = node
            } label: {
                Label("删除", systemImage: "trash")
            }
            if !node.isFolder {
                Button {
                    editingNode = node
                } label: {
                    Label("编辑", systemImage: "pencil")
                }
                .tint(.orange)
            }
        }
        .contextMenu {
            if !node.isFolder {
                Button("在新标签页打开", systemImage: "plus.square.on.square") {
                    guard let urlString = node.url, let url = URL(string: urlString) else { return }
                    let tab = env.tabManager.createTab(
                        url: url.absoluteString,
                        privacyMode: .regular,
                        openSource: .bookmark,
                        activate: false
                    )
                    _ = env.tabManager.ensureWebView(for: tab)
                }
                Button("拷贝网址", systemImage: "doc.on.doc") {
                    UIPasteboard.general.string = node.url
                }
                Divider()
            }
            Button("编辑", systemImage: "pencil") { editingNode = node }
            Button("删除", systemImage: "trash", role: .destructive) { nodeToDelete = node }
        }
    }

    private func openInBrowser(_ url: URL) {
        guard let tab = env.tabManager.activeTab else { return }
        tab.isHome = false
        tab.url = url.absoluteString
        let webView = env.tabManager.ensureWebView(for: tab)
        webView.load(URLRequest(url: url))
        dismiss()
    }

    private func deleteItems(at offsets: IndexSet) {
        for index in offsets {
            bookmarks.removeNode(id: currentItems[index].node.id)
        }
    }

    /// Drag-reorder inside the current folder.
    ///
    /// Ported from `BookmarkOrdersTable`: the whole child list is rewritten
    /// densely, because a partial rewrite is what leaves gaps that make a later
    /// insert land in the wrong place.
    private func moveItems(from source: IndexSet, to destination: Int) {
        guard !isSearching else { return }
        var items = currentItems
        items.move(fromOffsets: source, toOffset: destination)
        bookmarks.reorder(
            parentNodeId: currentFolderId,
            orderedChildIds: items.map(\.node.id)
        )
    }
}

/// Editing one bookmark.
private struct BookmarkEditSheet: View {
    @Environment(\.dismiss) private var dismiss

    var node: BookmarkNode
    var onSave: (String, String?) -> Void

    @State private var title: String
    @State private var url: String

    init(node: BookmarkNode, onSave: @escaping (String, String?) -> Void) {
        self.node = node
        self.onSave = onSave
        _title = State(initialValue: node.title)
        _url = State(initialValue: node.url ?? "")
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("名称") {
                    TextField("名称", text: $title)
                }
                if !node.isFolder {
                    Section("网址") {
                        TextField("网址", text: $url)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .keyboardType(.URL)
                    }
                }
            }
            .navigationTitle(node.isFolder ? "编辑文件夹" : "编辑书签")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") {
                        onSave(title, node.isFolder ? nil : url)
                        dismiss()
                    }
                    .disabled(title.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
    }
}

private extension View {
    /// Adds an Edit button to the navigation bar when the list can be reordered.
    ///
    /// SwiftUI's `.onMove` needs an `EditMode` to activate on iOS, and there is
    /// no automatic affordance for it.
    func editModeSupport() -> some View {
        modifier(EditModeToolbar())
    }
}

private struct EditModeToolbar: ViewModifier {
    @Environment(\.editMode) private var editMode

    func body(content: Content) -> some View {
        content.toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button(editMode?.wrappedValue == .active ? "完成" : "排序") {
                    withAnimation {
                        editMode?.wrappedValue = editMode?.wrappedValue == .active ? .inactive : .active
                    }
                }
            }
        }
    }
}
