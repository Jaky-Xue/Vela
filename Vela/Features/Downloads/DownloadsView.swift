//
//  DownloadsView.swift
//  Vela
//
//  The download list.
//
//  The row actions map onto the transfer engine's state: pause keeps the
//  segmented parts or WebKit's resume blob, resume continues from them, and a
//  pending row is a queued download that will start when a concurrency slot
//  frees. Deletion is the only action that discards partial data.
//

import SwiftUI
import UIKit
import QuickLook

struct DownloadsView: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.browserPalette) private var palette
    @Environment(\.dismiss) private var dismiss

    @State private var showPrivate = false
    @State private var previewUrl: URL?
    @State private var entryToDelete: DownloadTask?
    @State private var showDeleteConfirm = false

    private var downloads: DownloadService { env.downloads }

    private var visibleTasks: [DownloadTask] {
        downloads.tasks.filter { $0.privacyMode == (showPrivate ? .private : .regular) }
    }

    var body: some View {
        List {
            if visibleTasks.isEmpty {
                EmptyState(
                    systemImage: "arrow.down.circle",
                    title: "没有下载",
                    message: showPrivate ? "无痕模式下的下载会显示在这里。" : "下载的文件会保存在 Vela 的下载文件夹中。"
                )
                .listRowBackground(Color.clear)
            } else {
                ForEach(visibleTasks) { task in
                    row(task)
                }
            }
        }
        .listStyle(.insetGrouped)
        .browserListSurface()
        .navigationTitle("下载")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button("完成") { dismiss() }
            }
            ToolbarItem(placement: .principal) {
                Picker("模式", selection: $showPrivate) {
                    Text("普通").tag(false)
                    Text("无痕").tag(true)
                }
                .pickerStyle(.segmented)
                .frame(width: 160)
            }
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button("打开下载文件夹", systemImage: "folder") {
                        openDownloadsFolder()
                    }
                    Divider()
                    Button("清除已完成", systemImage: "trash") {
                        downloads.removeCompleted()
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
            }
        }
        .alert(
            "删除「\(entryToDelete?.displayName ?? "")」？",
            isPresented: $showDeleteConfirm
        ) {
            Button("取消", role: .cancel) { entryToDelete = nil }
            Button("只删除记录") {
                if let task = entryToDelete { downloads.remove(guid: task.guid, deleteFile: false) }
                entryToDelete = nil
            }
            Button("同时删除文件", role: .destructive) {
                if let task = entryToDelete { downloads.remove(guid: task.guid, deleteFile: true) }
                entryToDelete = nil
            }
        }
        .quickLookPreview($previewUrl)
        .onAppear {
            downloads.reload(privacyMode: showPrivate ? .private : .regular)
        }
        .onChange(of: showPrivate) { _, isPrivate in
            downloads.reload(privacyMode: isPrivate ? .private : .regular)
        }
    }

    // MARK: - Rows

    @ViewBuilder
    private func row(_ task: DownloadTask) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                Image(systemName: iconName(for: task))
                    .font(.system(size: 17))
                    .foregroundStyle(statusColor(task.status))
                    .frame(width: 28, height: 28)
                    .background(statusColor(task.status).opacity(0.12), in: RoundedRectangle(cornerRadius: 7, style: .continuous))

                VStack(alignment: .leading, spacing: 2) {
                    Text(task.displayName)
                        .font(.subheadline)
                        .foregroundStyle(palette.primaryText)
                        .lineLimit(2)
                    HStack(spacing: 5) {
                        Text(task.status.displayName)
                        if task.status.isTerminal || task.receivedBytes > 0 {
                            Text("·")
                            Text(task.displaySize)
                                .monospacedDigit()
                        }
                    }
                    .font(.caption)
                    .foregroundStyle(palette.secondaryText)
                }

                Spacer(minLength: 0)

                trailingAction(for: task)
            }

            if task.status == .running, let progress = task.progress {
                ProgressView(value: progress)
                    .progressViewStyle(.linear)
                    .tint(.accentColor)
            } else if task.status == .running {
                // No `Content-Length`: a determinate bar would sit at zero, so
                // the row shows an indeterminate one instead.
                ProgressView()
                    .progressViewStyle(.linear)
            }

            if let failure = task.failure, task.status == .failed {
                Text(failure.displayMessage)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .onTapGesture {
            if task.status == .completed, let url = task.destinationUrl {
                previewUrl = url
            }
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            Button(role: .destructive) {
                entryToDelete = task
                showDeleteConfirm = true
            } label: {
                Label("删除", systemImage: "trash")
            }
        }
        .contextMenu {
            if task.status == .completed, let url = task.destinationUrl {
                Button("打开", systemImage: "eye") { previewUrl = url }
                Button("分享", systemImage: "square.and.arrow.up") { share(url: url) }
                Button("在「文件」中显示", systemImage: "folder") { openDownloadsFolder() }
                Divider()
            }
            if task.status == .paused || task.status == .failed || task.status == .pending {
                Button("继续下载", systemImage: "arrow.clockwise") {
                    let webView = env.tabManager.webView(for: env.tabManager.activeTabId)
                    Task { await downloads.resume(guid: task.guid, in: webView) }
                }
            }
            if task.status == .running {
                Button("暂停", systemImage: "pause") { downloads.pause(guid: task.guid) }
            }
            Button("拷贝下载地址", systemImage: "doc.on.doc") {
                UIPasteboard.general.string = task.requestUrl
            }
            Divider()
            Button("删除", systemImage: "trash", role: .destructive) {
                entryToDelete = task
                showDeleteConfirm = true
            }
        }
    }

    @ViewBuilder
    private func trailingAction(for task: DownloadTask) -> some View {
        switch task.status {
        case .running:
            Button {
                downloads.pause(guid: task.guid)
            } label: {
                Image(systemName: "pause.circle.fill")
                    .font(.system(size: 20))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)

        case .paused, .failed:
            Button {
                let webView = env.tabManager.webView(for: env.tabManager.activeTabId)
                Task { await downloads.resume(guid: task.guid, in: webView) }
            } label: {
                Image(systemName: "arrow.clockwise.circle.fill")
                    .font(.system(size: 20))
                    .foregroundStyle(.tint)
            }
            .buttonStyle(.plain)

        case .completed:
            if let url = task.destinationUrl {
                Button {
                    previewUrl = url
                } label: {
                    Image(systemName: "eye.circle.fill")
                        .font(.system(size: 20))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }

        case .pending:
            Button {
                let webView = env.tabManager.webView(for: env.tabManager.activeTabId)
                Task { await downloads.resume(guid: task.guid, in: webView) }
            } label: {
                Image(systemName: "play.circle.fill")
                    .font(.system(size: 20))
                    .foregroundStyle(.tint)
            }
            .buttonStyle(.plain)

        case .cancelled:
            EmptyView()
        }
    }

    // MARK: - Helpers

    private func statusColor(_ status: DownloadStatus) -> Color {
        switch status {
        case .completed: return .green
        case .failed: return .red
        case .cancelled: return .secondary
        case .paused: return .orange
        case .running, .pending: return .accentColor
        }
    }

    private func iconName(for task: DownloadTask) -> String {
        switch task.status {
        case .completed: return "checkmark.circle"
        case .failed: return "exclamationmark.triangle"
        case .cancelled: return "xmark.circle"
        case .paused: return "pause.circle"
        case .running: return "arrow.down.circle"
        case .pending: return "clock"
        }
    }

    /// Opens the downloads folder in the Files app.
    ///
    /// `shareddocuments://` is the undocumented-but-stable scheme the Files app
    /// registers; the fallback is the generic Files root, because a dead tap is
    /// worse than landing one level up.
    private func openDownloadsFolder() {
        let path = downloads.downloadsDirectory.path
        if let encoded = path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
           let url = URL(string: "shareddocuments://\(encoded)"),
           UIApplication.shared.canOpenURL(url) {
            UIApplication.shared.open(url)
            return
        }
        if let root = URL(string: "shareddocuments://"), UIApplication.shared.canOpenURL(root) {
            UIApplication.shared.open(root)
        }
    }

    private func share(url: URL) {
        guard let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
              let root = scene.keyWindow?.rootViewController else { return }
        let controller = UIActivityViewController(activityItems: [url], applicationActivities: nil)
        // A popover presentation is required on iPad or the sheet traps.
        controller.popoverPresentationController?.sourceView = root.view
        root.present(controller, animated: true)
    }
}
