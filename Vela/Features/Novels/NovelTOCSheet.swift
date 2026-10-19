//
//  NovelTOCSheet.swift
//  Vela
//
//  The chapter list for the novel reader.
//
//  Entries come from the book's cached TOC, fetched from the site's TOC page
//  when the reader opens. The current chapter is marked, and a tap loads that
//  chapter in place — it is the way to jump around a book whose chapter pages
//  do not carry previous/next links.
//

import SwiftUI

struct NovelTOCSheet: View {
    @Environment(\.browserPalette) private var palette
    @Environment(\.dismiss) private var dismiss

    @Binding var entries: [NovelTOCEntry]
    var currentUrl: String
    @Binding var isLoading: Bool
    var onSelect: (NovelTOCEntry) -> Void
    var onClose: () -> Void

    var body: some View {
        NavigationStack {
            Group {
                if entries.isEmpty {
                    if isLoading {
                        VStack(spacing: 12) {
                            ProgressView()
                            Text("正在载入目录…")
                                .font(.footnote)
                                .foregroundStyle(palette.secondaryText)
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else {
                        EmptyState(
                            systemImage: "list.bullet.rectangle",
                            title: "没有找到目录",
                            message: "这个网站可能没有可解析的目录页，或目录需要在网页里打开。"
                        )
                    }
                } else {
                    List(entries) { entry in
                        Button {
                            onSelect(entry)
                        } label: {
                            HStack(spacing: 10) {
                                Text(entry.title)
                                    .font(.system(size: 14))
                                    .foregroundStyle(palette.primaryText)
                                    .lineLimit(2)
                                Spacer(minLength: 6)
                                if entry.url == currentUrl {
                                    Image(systemName: "checkmark.circle.fill")
                                        .foregroundStyle(palette.accent)
                                }
                            }
                            .padding(.vertical, 2)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                    .listStyle(.plain)
                    .browserListSurface(rowsAreCards: false)
                }
            }
            .navigationTitle("目录")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") {
                        onClose()
                        dismiss()
                    }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
}
