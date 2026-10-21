//
//  NovelBookshelfView.swift
//  Vela
//
//  The shelf: every novel that has been opened with 小说模式, and where the
//  reader stopped in it.
//
//  A book joins the shelf the first time a chapter is read — there is no
//  separate "add" flow to forget, and the shelf is therefore always a history
//  of what the user actually read rather than a list they have to maintain.
//

import Foundation
import SwiftUI

struct NovelBookshelfView: View {
    @Environment(\.browserPalette) private var palette
    @Environment(\.dismiss) private var dismiss

    /// The shelf this presentation belongs to. The shell captures it when the
    /// sheet opens: an ordinary shelf reads the durable library, a private one
    /// reads the session's in-memory library.
    var library: NovelLibraryService

    /// Opens a book in the reader. The shell owns the reader layer, so the
    /// shelf reports the choice and dismisses itself.
    var onOpen: (NovelBook) -> Void

    init(library: NovelLibraryService, onOpen: @escaping (NovelBook) -> Void) {
        self.library = library
        self.onOpen = onOpen
    }

    @State private var pendingDeletion: NovelBook?

    private var books: [NovelBook] { library.books }

    var body: some View {
        NavigationStack {
            Group {
                if books.isEmpty {
                    EmptyState(
                        systemImage: "books.vertical",
                        title: "书架还是空的",
                        message: "在任意小说章节页面打开「菜单 → 小说模式」，这本书就会出现在这里，并记住你读到的位置。",
                        actionTitle: "完成",
                        action: { dismiss() }
                    )
                } else {
                    List {
                        Section {
                            ForEach(books) { book in
                                Button {
                                    onOpen(book)
                                } label: {
                                    bookRow(book)
                                }
                                .buttonStyle(.plain)
                                .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                                    Button("移出书架", role: .destructive) {
                                        pendingDeletion = book
                                    }
                                }
                                .contextMenu {
                                    Button("继续阅读", systemImage: "book") {
                                        onOpen(book)
                                    }
                                    Button("移出书架", systemImage: "trash", role: .destructive) {
                                        pendingDeletion = book
                                    }
                                }
                            }
                        } footer: {
                            Text("书架只保存在这台设备上。章节正文会缓存最近读过的部分，便于离线继续。")
                        }
                    }
                    .listStyle(.insetGrouped)
                    .browserListSurface(rowsAreCards: true)
                }
            }
            .navigationTitle("书架")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                }
            }
            .alert(
                "移出书架？",
                isPresented: Binding(
                    get: { pendingDeletion != nil },
                    set: { if !$0 { pendingDeletion = nil } }
                ),
                presenting: pendingDeletion
            ) { book in
                Button("移出", role: .destructive) {
                    library.delete(bookId: book.id)
                    pendingDeletion = nil
                }
                Button("取消", role: .cancel) { pendingDeletion = nil }
            } message: { book in
                Text("「\(book.title)」和它缓存的章节会一起删除。")
            }
        }
        .browserAmbientSheet()
    }

    private func bookRow(_ book: NovelBook) -> some View {
        HStack(spacing: 12) {
            cover(for: book)

            VStack(alignment: .leading, spacing: 4) {
                Text(book.title.isEmpty ? "未命名" : book.title)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(palette.primaryText)
                    .lineLimit(1)

                Text(book.author.isEmpty ? "作者未知" : book.author)
                    .font(.caption)
                    .foregroundStyle(palette.secondaryText)
                    .lineLimit(1)

                Text(book.currentChapterTitle.isEmpty ? "尚未开始阅读" : book.currentChapterTitle)
                    .font(.caption2)
                    .foregroundStyle(palette.secondaryText)
                    .lineLimit(1)

                HStack(spacing: 6) {
                    GeometryReader { geometry in
                        ZStack(alignment: .leading) {
                            Capsule()
                                .fill(palette.controlFill)
                            Capsule()
                                .fill(palette.accent)
                                .frame(width: max(2, geometry.size.width * book.progress))
                        }
                    }
                    .frame(height: 3)

                    Text("\(Int((book.progress * 100).rounded()))%")
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(palette.secondaryText)
                        .monospacedDigit()
                }
                .padding(.top, 2)
            }

            Spacer(minLength: 0)

            VStack(alignment: .trailing, spacing: 6) {
                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(palette.secondaryText.opacity(0.6))
                Text(Self.relativeDate(book.lastReadAt))
                    .font(.system(size: 9))
                    .foregroundStyle(palette.secondaryText)
                    .lineLimit(1)
            }
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
    }

    private func cover(for book: NovelBook) -> some View {
        let colors = coverColors(for: book)
        let initial = book.title.trimmingCharacters(in: .whitespacesAndNewlines).first.map(String.init) ?? "书"
        return ZStack {
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: colors,
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
            Text(initial)
                .font(.system(size: 22, weight: .semibold, design: .serif))
                .foregroundStyle(.white.opacity(0.94))
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .strokeBorder(.white.opacity(0.18), lineWidth: 0.5)
        }
        .frame(width: 46, height: 62)
        .shadow(color: .black.opacity(0.12), radius: 6, y: 3)
    }

    /// A deterministic cover colour: the same book keeps the same colour on
    /// every launch of the session, without storing one.
    private func coverColors(for book: NovelBook) -> [Color] {
        var hasher = Hasher()
        hasher.combine(book.title)
        hasher.combine(book.author)
        let value = UInt(bitPattern: hasher.finalize())
        let hue = Double(value % 360) / 360
        return [
            Color(hue: hue, saturation: 0.52, brightness: 0.80),
            Color(
                hue: (hue + 0.10).truncatingRemainder(dividingBy: 1),
                saturation: 0.58,
                brightness: 0.58
            )
        ]
    }

    private static let dateFormatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.locale = Locale(identifier: "zh_Hans_CN")
        formatter.unitsStyle = .short
        return formatter
    }()

    private static func relativeDate(_ date: Date) -> String {
        dateFormatter.localizedString(for: date, relativeTo: Date())
    }
}
