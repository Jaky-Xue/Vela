//
//  AddBookmarkChoiceSheet.swift
//  Vela
//
//  The sheet the "添加书签" menu tile opens: what to create, and where.
//
//  Two inventories sit behind this sheet — the bookmark roots and the home's
//  own favourite shelf — and they are independent stores. The sheet therefore
//  offers both directions: save a bookmark (optionally carried to the home as
//  a copy), or add a tile to the home and no bookmark at all. The previous
//  version made the bookmark mandatory and the home tile a toggle on it, which
//  left "I just want this page on my home screen" impossible.
//
//  The choice is the whole point of the sheet — a destination is a decision
//  the user makes once, at save time, not something to reorganise later.
//

import SwiftUI

struct AddBookmarkChoiceSheet: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.browserPalette) private var palette
    @Environment(\.dismiss) private var dismiss

    var url: String
    var title: String

    /// What 添加 creates. The bookmark roots carry an optional home copy; the
    /// third choice creates only the home tile.
    private enum SaveTarget: Hashable {
        case bookmark(BookmarkRootRole)
        case homeOnly
    }

    @State private var target: SaveTarget = .bookmark(.toolbar)
    // A bookmark saved to a root is carried to the home by default: the home
    // is where the user starts, so the shelf is the useful default.
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
                        .browserFloatingChrome(radius: 20, elevation: .card)
                }
                .accessibilityLabel("关闭")

                Text("添加书签或收藏")
                    .font(.system(size: 19, weight: .bold))

                Spacer(minLength: 0)
            }
            .padding(.horizontal, BrowserSpacing.regular)
            .padding(.top, BrowserSpacing.regular)

            // The sheet opens at 400 pt in portrait, but a landscape iPhone
            // has less height than that: the destination rows and the home
            // toggle scroll rather than being clipped, and the 添加 button
            // stays pinned where the thumb expects it.
            ScrollView {
                VStack(spacing: 0) {
                    VStack(spacing: 0) {
                        ForEach([BookmarkRootRole.toolbar, .other]) { role in
                            folderRow(role)

                            Rectangle()
                                .fill(palette.separator)
                                .frame(height: 0.5)
                                .padding(.leading, 64)
                        }

                        homeOnlyRow
                    }
                    .browserCard()
                    .padding(.horizontal, BrowserSpacing.regular)
                    .padding(.top, BrowserSpacing.loose)

                    if case .bookmark = target {
                        HStack(spacing: BrowserSpacing.compact) {
                            Image(systemName: "house")
                                .font(.system(size: 14, weight: .medium))
                                .frame(width: 36, height: 36)
                                .browserFloatingChrome(radius: 18, elevation: .card)

                            VStack(alignment: .leading, spacing: 1) {
                                Text("同时添加到主页收藏")
                                    .font(.system(size: 15, weight: .medium))
                                Text("主页收藏与书签分开保存")
                                    .font(.caption)
                                    .foregroundStyle(palette.secondaryText)
                            }

                            Spacer(minLength: 0)

                            Toggle("", isOn: $addToHome)
                                .labelsHidden()
                        }
                        .padding(.horizontal, BrowserSpacing.regular)
                        .padding(.top, BrowserSpacing.loose)
                        .padding(.bottom, BrowserSpacing.regular)
                    }
                }
                .frame(maxWidth: .infinity)
            }
            .scrollBounceBehavior(.basedOnSize)

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
        .browserSurfaceBackground(opacity: 0.72)
        .presentationDetents([.height(400), .large])
        .presentationDragIndicator(.hidden)
    }

    /// One bookmark root: the folder, its bookmark count, and a check when it
    /// is the chosen destination.
    @ViewBuilder
    private func folderRow(_ role: BookmarkRootRole) -> some View {
        let isChosen = target == .bookmark(role)
        Button {
            target = .bookmark(role)
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

    /// The third destination: the home's shelf and nothing else.
    @ViewBuilder
    private var homeOnlyRow: some View {
        let isChosen = target == .homeOnly
        Button {
            target = .homeOnly
        } label: {
            HStack(spacing: BrowserSpacing.compact) {
                Image(systemName: "house.fill")
                    .font(.system(size: 17))
                    .foregroundStyle(.blue)
                    .frame(width: 34)

                VStack(alignment: .leading, spacing: 1) {
                    Text("仅添加到主页收藏")
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(palette.primaryText)
                    Text("不创建书签")
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
        switch target {
        case let .bookmark(role):
            let parentNodeId = env.bookmarks.rootNodeId(for: role)
            let node = env.bookmarks.addBookmark(url: url, title: title, parentNodeId: parentNodeId)
            if addToHome, let saved = node ?? env.bookmarks.bookmark(for: url) {
                // The tile gets a copy of the name and address. Editing it later
                // is a home affair; the bookmark stays the bookmark list's.
                env.homeFavorites.add(
                    url: saved.url ?? url,
                    title: saved.title
                )
            }
        case .homeOnly:
            // The shelf is its own inventory: this creates exactly one tile and
            // leaves the bookmark tree untouched.
            env.homeFavorites.add(url: url, title: title)
        }
        dismiss()
    }
}
