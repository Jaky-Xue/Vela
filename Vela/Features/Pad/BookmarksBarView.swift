//
//  BookmarksBarView.swift
//  Vela
//
//  The iPad layout's bookmarks bar.
//
//  It shows the toolbar root's bookmarks as a horizontal shelf. Folders are
//  flattened for the bar — the bar's job is one-tap destinations, and a
//  hierarchical menu belongs in the bookmark manager — while the leading book
//  button opens that manager.
//

import SwiftUI

struct BookmarksBarView: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.browserPalette) private var palette

    var onNavigate: (URL) -> Void
    var onOpenManager: () -> Void
    /// The iPad top bar collapses on a downward scroll; the bookmarks strip
    /// collapses with it, so the page takes the space back.
    var isHidden: Bool = false

    /// Long-pressing a bookmark edits it in place: the bar is the one place a
    /// bookmarked site is already in reach, so renaming or fixing its address
    /// should not require opening the manager.
    @State private var editingNode: BookmarkNode?
    @State private var nodeToDelete: BookmarkNode?

    private var bookmarks: [BookmarkNode] {
        guard let rootId = env.bookmarks.rootNodeId(for: .toolbar) else { return [] }
        return Self.flatten(env.bookmarks.children(of: rootId))
    }

    /// Whether the strip has anything to show. The shell asks this to size the
    /// page's top content inset: an empty bar must not hold a 36-point band of
    /// the page away from the glass.
    @MainActor
    static func hasVisibleBookmarks(in env: AppEnvironment) -> Bool {
        guard let rootId = env.bookmarks.rootNodeId(for: .toolbar) else { return false }
        return !flatten(env.bookmarks.children(of: rootId)).isEmpty
    }

    private static func flatten(_ items: [BookmarkTreeItem]) -> [BookmarkNode] {
        var result: [BookmarkNode] = []
        for item in items {
            if item.node.isFolder {
                result.append(contentsOf: flatten(item.children))
            } else if item.node.url != nil {
                result.append(item.node)
            }
        }
        return result
    }

    @ViewBuilder
    var body: some View {
        if bookmarks.isEmpty {
            EmptyView()
        } else {
            bar
                .frame(height: isHidden ? 0 : 36)
                .clipped()
                .opacity(isHidden ? 0 : 1)
                .allowsHitTesting(!isHidden)
                // Bookmarks added, removed or reordered while the bar is on
                // screen settle into their new places instead of snapping.
                .animation(.snappy(duration: 0.24), value: bookmarks.map(\.id))
                .sheet(item: $editingNode) { node in
                    BookmarkEditSheet(node: node) { title, url in
                        env.bookmarks.rename(id: node.id, title: title)
                        if let url, !url.isEmpty {
                            env.bookmarks.updateUrl(id: node.id, url: url)
                        }
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
                        if let node = nodeToDelete {
                            env.bookmarks.removeNode(id: node.id)
                        }
                        nodeToDelete = nil
                    }
                } message: {
                    Text("书签会从所有列表和设备中移除。")
                }
        }
    }

    private var bar: some View {
        HStack(spacing: 6) {
            Button(action: onOpenManager) {
                Image(systemName: "book")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(palette.secondaryText)
                    .frame(width: 26, height: 26)
                    .contentShape(Rectangle())
            }
            .buttonStyle(BookmarkBarButtonStyle())
            .accessibilityLabel("书签管理")

            Rectangle()
                .fill(palette.separator)
                .frame(width: 0.5, height: 16)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 2) {
                    if bookmarks.isEmpty {
                        Text("书签栏")
                            .font(.system(size: 11))
                            .foregroundStyle(palette.secondaryText)
                            .padding(.horizontal, 6)
                    } else {
                        ForEach(bookmarks) { node in
                            bookmarkButton(node)
                        }
                    }
                }
            }

            Spacer(minLength: 0)

            Button(action: onOpenManager) {
                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(palette.secondaryText.opacity(0.7))
                    .frame(width: 24, height: 26)
                    .contentShape(Rectangle())
            }
            .buttonStyle(BookmarkBarButtonStyle())
            .accessibilityLabel("更多书签")
        }
        .padding(.horizontal, 10)
        .frame(height: 36)
        // Thin material, not an opaque palette fill: the page scrolls under
        // this strip, and a fill would make it a solid band of colour across
        // the top of the document. The tint is only enough to keep the text
        // legible over a bright page.
        .background {
            ZStack {
                Rectangle().fill(.thinMaterial)
                palette.chromeBackground.opacity(0.10)
            }
        }
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(palette.separator.opacity(0.55))
                .frame(height: 0.5)
        }
    }

    private func bookmarkButton(_ node: BookmarkNode) -> some View {
        Button {
            guard let url = BrowserUrlResolver.storedUrl(node.url) else { return }
            onNavigate(url)
        } label: {
            HStack(spacing: 5) {
                SiteIconView(host: node.displayHost, size: 14)
                Text(node.title.isEmpty ? node.displayHost : node.title)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(palette.primaryText)
                    .lineLimit(1)
            }
            .padding(.horizontal, 6)
            .frame(height: 26)
            .contentShape(Rectangle())
        }
        .buttonStyle(BookmarkBarButtonStyle())
        .contextMenu {
            Button("编辑书签", systemImage: "pencil") {
                editingNode = node
            }
            Button("在新标签页打开", systemImage: "plus.square.on.square") {
                guard let url = BrowserUrlResolver.storedUrl(node.url) else { return }
                env.tabManager.openTab(
                    url: url,
                    openSource: .shortcut,
                    activate: false
                )
            }
            Divider()
            Button("删除书签", systemImage: "trash", role: .destructive) {
                nodeToDelete = node
            }
        }
    }
}

/// The press feedback for a bookmark chip: a short scale and fade under the
/// finger, the same weight the chrome buttons use. A tap that only navigates
/// afterwards leaves the row feeling dead until the page arrives.
private struct BookmarkBarButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.94 : 1)
            .opacity(configuration.isPressed ? 0.65 : 1)
            .animation(
                .spring(response: 0.22, dampingFraction: 0.75),
                value: configuration.isPressed
            )
    }
}
