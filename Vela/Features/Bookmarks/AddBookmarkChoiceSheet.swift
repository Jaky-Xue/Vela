//
//  AddBookmarkChoiceSheet.swift
//  Vela
//
//  The sheet the "添加书签" menu tile opens: choose which root the bookmark
//  lands in, and whether the home surface carries it too.
//
//  The choice is the whole point of the sheet — a bookmark's destination is a
//  decision the user makes once, at save time, not something to reorganise
//  later from the bookmark list.
//

import SwiftUI

struct AddBookmarkChoiceSheet: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.browserPalette) private var palette
    @Environment(\.dismiss) private var dismiss

    var url: String
    var title: String

    @State private var chosenRole: BookmarkRootRole = .toolbar
    // The home carries every bookmark by default now — the surface's own add
    // tile is gone, so this toggle is the one way to keep a bookmark off it.
    @State private var addToHome = true

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: BrowserSpacing.compact) {
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(palette.primaryText)
                        .frame(width: 40, height: 40)
                        .background(palette.controlFill.opacity(0.7), in: Circle())
                }
                .accessibilityLabel("关闭")

                Text("添加书签")
                    .font(.system(size: 19, weight: .bold))

                Spacer(minLength: 0)
            }
            .padding(.horizontal, BrowserSpacing.regular)
            .padding(.top, BrowserSpacing.regular)

            VStack(spacing: 0) {
                ForEach([BookmarkRootRole.toolbar, .other]) { role in
                    folderRow(role)

                    if role != .other {
                        Rectangle()
                            .fill(palette.separator)
                            .frame(height: 0.5)
                            .padding(.leading, 64)
                    }
                }
            }
            .background(palette.controlFill.opacity(0.4))
            .clipShape(RoundedRectangle(cornerRadius: BrowserRadius.card, style: .continuous))
            .padding(.horizontal, BrowserSpacing.regular)
            .padding(.top, BrowserSpacing.loose)

            HStack(spacing: BrowserSpacing.compact) {
                Image(systemName: "house")
                    .font(.system(size: 14, weight: .medium))
                    .frame(width: 36, height: 36)
                    .background(palette.controlFill.opacity(0.7), in: Circle())

                Text("同时添加到主页")
                    .font(.system(size: 15, weight: .medium))

                Spacer(minLength: 0)

                Toggle("", isOn: $addToHome)
                    .labelsHidden()
            }
            .padding(.horizontal, BrowserSpacing.regular)
            .padding(.top, BrowserSpacing.loose)

            Spacer(minLength: 0)

            Button {
                onAdd()
            } label: {
                Text("添加")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(palette.onAccent)
                    .frame(maxWidth: .infinity)
                    .frame(height: 50)
                    .background(palette.accent, in: RoundedRectangle(cornerRadius: 25, style: .continuous))
            }
            .padding(.horizontal, BrowserSpacing.regular)
            .padding(.bottom, BrowserSpacing.regular)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(palette.surface)
        .presentationDetents([.height(400)])
        .presentationDragIndicator(.hidden)
    }

    /// One destination row: the folder, its bookmark count, and a check when it
    /// is the chosen destination.
    @ViewBuilder
    private func folderRow(_ role: BookmarkRootRole) -> some View {
        let isChosen = chosenRole == role
        Button {
            chosenRole = role
        } label: {
            HStack(spacing: BrowserSpacing.compact) {
                Image(systemName: "folder.fill")
                    .font(.system(size: 17))
                    .foregroundStyle(.blue)
                    .frame(width: 34)

                VStack(alignment: .leading, spacing: 1) {
                    Text(role == .toolbar ? "书签栏" : "其他书签")
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(palette.primaryText)
                    Text("\(bookmarkCount(in: role)) 个书签")
                        .font(.caption)
                        .foregroundStyle(palette.secondaryText)
                }

                Spacer(minLength: 8)

                Image(systemName: isChosen ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 20, weight: .light))
                    .foregroundStyle(isChosen ? Color.blue : palette.secondaryText.opacity(0.55))
            }
            .padding(.horizontal, BrowserSpacing.compact + 2)
            .frame(height: 62)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// How many bookmarks live under a root, folders counted through.
    private func bookmarkCount(in role: BookmarkRootRole) -> Int {
        guard let rootId = env.bookmarks.rootNodeId(for: role) else { return 0 }

        var count = 0
        func walk(_ items: [BookmarkTreeItem]) {
            for item in items {
                if item.node.isFolder {
                    walk(item.children)
                } else {
                    count += 1
                }
            }
        }
        walk(env.bookmarks.children(of: rootId))
        return count
    }

    private func onAdd() {
        let parentNodeId = env.bookmarks.rootNodeId(for: chosenRole)
        let node = env.bookmarks.addBookmark(url: url, title: title, parentNodeId: parentNodeId)
        if addToHome, let id = node?.id ?? env.bookmarks.bookmark(for: url)?.id {
            HomeBookmarkStore.add(id)
        }
        dismiss()
    }
}
