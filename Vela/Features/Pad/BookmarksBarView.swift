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

    private var bookmarks: [BookmarkNode] {
        guard let rootId = env.bookmarks.rootNodeId(for: .toolbar) else { return [] }
        return flatten(env.bookmarks.children(of: rootId))
    }

    private func flatten(_ items: [BookmarkTreeItem]) -> [BookmarkNode] {
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
            .buttonStyle(.plain)
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
            .buttonStyle(.plain)
            .accessibilityLabel("更多书签")
        }
        .padding(.horizontal, 10)
        .frame(height: 36)
        .background {
            ZStack {
                palette.chromeBackground.opacity(0.78)
                Rectangle().fill(.regularMaterial)
            }
        }
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(palette.separator)
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
        .buttonStyle(.plain)
    }
}
