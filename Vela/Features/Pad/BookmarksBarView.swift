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
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

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
                // screen settle into their new places with the same give the
                // bar itself has.
                .animation(BrowserMotion.jelly(reduceMotion), value: bookmarks.map(\.id))
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
            moduleButton(symbol: "book", label: "书签管理", action: onOpenManager)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(bookmarks) { node in
                        bookmarkButton(node)
                    }
                }
                .padding(.vertical, 4)
            }

            Spacer(minLength: 0)

            moduleButton(symbol: "chevron.right", label: "更多书签", action: onOpenManager)
        }
        .padding(.horizontal, 12)
        .frame(height: 36)
    }

    /// A fixed control as its own glass module, the shape every bookmark in
    /// the row wears.
    private func moduleButton(
        symbol: String,
        label: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: symbol == "book" ? 12 : 10, weight: .semibold))
                .foregroundStyle(palette.secondaryText)
                .frame(width: 30, height: 28)
                .contentShape(Rectangle())
                .bookmarkGlassModule()
        }
        .buttonStyle(BookmarkBarButtonStyle())
        .accessibilityLabel(label)
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
            .padding(.horizontal, 8)
            .frame(height: 28)
            .contentShape(Rectangle())
            .bookmarkGlassModule()
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

/// The press feedback for a bookmark module: the jelly gives under the finger
/// and springs back, with a highlight laid over its glass the way a Safari
/// bookmark lights up. A tap that only navigates afterwards leaves the row
/// feeling dead until the page arrives; the jelly is what says it was hit.
private struct BookmarkBarButtonStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.browserPalette) private var palette

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .overlay {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(palette.controlFill.opacity(configuration.isPressed ? 0.45 : 0))
                    .allowsHitTesting(false)
            }
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.9 : 1)
            .opacity(configuration.isPressed ? 0.82 : 1)
            .animation(BrowserMotion.jellyPress(reduceMotion), value: configuration.isPressed)
    }
}

private extension View {
    /// One bookmark's own piece of glass.
    ///
    /// The row is a shelf of separate jelly modules rather than one continuous
    /// strip: each bookmark carries the same material, the same light and the
    /// same shadow as the toolbar's pills above it, and the page shows through
    /// the gaps between them.
    func bookmarkGlassModule() -> some View {
        browserFloatingChrome(
            radius: 14,
            material: .thinMaterial,
            tintStrength: 0.2,
            elevation: BrowserElevation(radius: 10, y: 4, opacity: 0.08),
            interactive: false
        )
        .luminousSheen(shape: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}
