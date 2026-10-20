//
//  OfflinePagesView.swift
//  Vela
//
//  The shelf of saved pages.
//
//  A row is opened, not previewed: tapping it hands the archive to the browser,
//  which loads it into a tab as an ordinary document. That keeps offline pages
//  inside the same back/forward, find-in-page, reader and translation surfaces
//  as the live web, instead of becoming a second, smaller viewer.
//

import SwiftUI
import UIKit

struct OfflinePagesView: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.browserPalette) private var palette
    @Environment(\.dismiss) private var dismiss

    let onOpen: (OfflinePageRecord) -> Void

    @State private var pendingDelete: OfflinePageRecord?
    @State private var showDeleteAll = false

    private var pages: [OfflinePageRecord] { env.offlinePages.pages }

    var body: some View {
        List {
            if pages.isEmpty {
                EmptyState(
                    systemImage: "arrow.down.doc",
                    title: "没有离线页面",
                    message: "在网页上打开菜单，选择「保存离线页面」后，页面会出现在这里，没有网络时也能继续阅读。"
                )
                .listRowBackground(Color.clear)
            } else {
                ForEach(pages) { page in
                    Button {
                        onOpen(page)
                    } label: {
                        row(page)
                    }
                    .buttonStyle(.plain)
                    .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                        Button(role: .destructive) {
                            pendingDelete = page
                        } label: {
                            Label("删除", systemImage: "trash")
                        }
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .browserListSurface()
        .navigationTitle("离线页面")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("完成") { dismiss() }
            }
            if !pages.isEmpty {
                ToolbarItem(placement: .topBarLeading) {
                    Menu {
                        Button(role: .destructive) {
                            showDeleteAll = true
                        } label: {
                            Label("删除全部离线页面", systemImage: "trash")
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                }
            }
        }
        .onAppear { env.offlinePages.reload() }
        .alert(
            "删除「\(pendingDelete?.displayTitle ?? "")」？",
            isPresented: Binding(
                get: { pendingDelete != nil },
                set: { if !$0 { pendingDelete = nil } }
            )
        ) {
            Button("取消", role: .cancel) { pendingDelete = nil }
            Button("删除", role: .destructive) {
                if let page = pendingDelete { env.offlinePages.delete(page) }
                pendingDelete = nil
            }
        } message: {
            Text("已保存的网页文件会一起删除。")
        }
        .alert("删除全部离线页面？", isPresented: $showDeleteAll) {
            Button("取消", role: .cancel) {}
            Button("全部删除", role: .destructive) {
                env.offlinePages.deleteAll()
            }
        } message: {
            Text("所有已保存的网页文件都会一起删除，此操作无法撤销。")
        }
    }

    // MARK: - Row

    private func row(_ page: OfflinePageRecord) -> some View {
        HStack(alignment: .top, spacing: 12) {
            OfflinePreview(path: page.previewImageUri)
                .frame(width: 64, height: 84)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(palette.separator.opacity(0.5), lineWidth: 0.5)
                }

            VStack(alignment: .leading, spacing: 5) {
                Text(page.displayTitle)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(palette.primaryText)
                    .lineLimit(3)
                    .multilineTextAlignment(.leading)

                HStack(spacing: 6) {
                    Text(page.displaySiteName)
                        .lineLimit(1)
                    if page.openStatus == .unread {
                        Text("未读")
                            .font(.caption2.weight(.semibold))
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(palette.accent.opacity(0.16), in: Capsule())
                            .foregroundStyle(palette.accent)
                    }
                }
                .font(.caption)
                .foregroundStyle(palette.secondaryText)

                Text("\(page.savedAt.formatted(date: .abbreviated, time: .shortened)) · \(page.displaySize) · \(page.resourceCount) 个资源")
                    .font(.caption2)
                    .foregroundStyle(palette.secondaryText)
            }

            Spacer(minLength: 0)
        }
        .padding(.vertical, 3)
        .contentShape(Rectangle())
    }
}

/// The saved page's snapshot, or a document glyph when it has none.
private struct OfflinePreview: View {
    @Environment(\.browserPalette) private var palette
    let path: String?

    @State private var image: UIImage?

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                ZStack {
                    palette.surface
                    Image(systemName: "doc.richtext")
                        .font(.system(size: 20))
                        .foregroundStyle(palette.secondaryText)
                }
            }
        }
        .clipped()
        .task(id: path) {
            guard let path, image == nil else { return }
            image = UIImage(contentsOfFile: path)
        }
    }
}
