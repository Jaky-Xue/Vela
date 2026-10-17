//
//  BookmarksView.swift
//  Vela
//
//  The bookmark manager.
//
//  Two roots, one list. A folder opens in place rather than pushing a screen,
//  which is what keeps the toolbar counts meaningful at every depth.
//

import SwiftUI
import UIKit

struct BookmarksView: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.browserPalette) private var palette
    @Environment(\.dismiss) private var dismiss

    @State private var path: [String] = []
    @State private var searchText = ""
    @State private var editingNode: BookmarkNode?
    @State private var showingNewFolder = false
    @State private var newFolderName = ""
    @State private var nodeToDelete: BookmarkNode?
    /// Whether the current folder's contents are unfolded. A `@AppStorage`
    /// value rather than `@State`, so the choice survives leaving the screen,
    /// which is what makes it a preference rather than an accident.
    @AppStorage("org.vela.browser.bookmarks-contents-expanded") private var contentsExpanded = true

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
                EmptyState(
                    systemImage: "bookmark",
                    title: isSearching ? "没有匹配的书签" : "还没有书签",
                    message: isSearching
                        ? "换个关键词试试。"
                        : "点菜单里的「添加到书签」即可保存。"
                )
                .listRowBackground(Color.clear)
            } else {
                Section {
                    // Search results show regardless of the fold: the fold is
                    // the folder view's control, and hiding rows a search just
                    // found is a list that answers a question with nothing.
                    if isSearching || contentsExpanded || currentFolderId == nil {
                        ForEach(currentItems) { item in
                            row(for: item)
                        }
                        .onDelete(perform: deleteItems)
                        .onMove(perform: moveItems)
                    }
                } header: {
                    contentsHeader
                }
            }
        }
        .listStyle(.plain)
        // A plain list rather than grouped, so the rows are cards at the root of
        // the screen and the folder hierarchy shows as indentation-free depth
        // rather than as a stack of nested panels.
        .browserListSurface(rowsAreCards: false)
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

    /// The section header.
    ///
    /// Inside a folder the header folds the contents away, which is the case
    /// that matters: a folder is the only place this list can run long. At a
    /// root it is a plain label, because the list *is* the two roots and folding
    /// it would hide the only two rows there are.
    @ViewBuilder
    private var contentsHeader: some View {
        if currentFolderId == nil && !isSearching {
            Text("书签")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(palette.secondaryText)
                .textCase(nil)
                .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            CollapsibleSectionHeader(
                title: isSearching ? "搜索结果" : currentTitle,
                count: currentItems.count,
                isExpanded: contentsExpanded,
                onToggle: {
                    withAnimation(.snappy(duration: 0.22)) { contentsExpanded.toggle() }
                }
            )
            .textCase(nil)
        }
    }

    @ViewBuilder
    private func row(for item: BookmarkTreeItem) -> some View {
        let node = item.node
        Button {
            if node.isFolder {
                path.append(node.id)
            } else if let url = Self.resolvedUrl(node.url) {
                openInBrowser(url)
            }
        } label: {
            HStack(spacing: 12) {
                if node.isFolder {
                    Image(systemName: "folder.fill")
                        .font(.system(size: 16))
                        .foregroundStyle(palette.accent)
                        .frame(width: 28, height: 28)
                } else {
                    SiteIconView(host: node.displayHost, size: 28)
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text(node.title)
                        .font(.body)
                        .lineLimit(1)
                        .foregroundStyle(palette.primaryText)
                    if !node.isFolder {
                        Text(node.displayHost)
                            .font(.caption)
                            .lineLimit(1)
                            .foregroundStyle(palette.secondaryText)
                    } else {
                        Text("\(item.descendantCount) 项")
                            .font(.caption)
                            .foregroundStyle(palette.secondaryText)
                    }
                }

                Spacer(minLength: 0)

                if node.isFolder {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(palette.secondaryText.opacity(0.6))
                }
            }
            .contentShape(Rectangle())
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
                    guard let url = Self.resolvedUrl(node.url) else { return }
                    env.tabManager.openTab(
                        url: url,
                        privacyMode: .regular,
                        openSource: .bookmark,
                        activate: false
                    )
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
        env.tabManager.load(url: url, in: tab)
        dismiss()
    }

    /// The address a stored bookmark opens, repaired when it does not parse
    /// as stored.
    ///
    /// A `URL(string:)` refusal is silent at every point after it: the row
    /// simply does nothing when tapped, which reads as the bookmark list being
    /// broken rather than as one malformed address. Trimming whitespace and
    /// assuming `https` for a scheme-less host turns the rows that used to be
    /// dead into rows that open.
    static func resolvedUrl(_ raw: String?) -> URL? {
        guard var text = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else {
            return nil
        }
        if !text.contains("://") { text = "https://" + text }
        return URL(string: text)
    }

    private func deleteItems(at offsets: IndexSet) {
        for index in offsets {
            bookmarks.removeNode(id: currentItems[index].node.id)
        }
    }

    /// Drag-reorder inside the current folder.
    ///
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
            .browserListSurface()
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
