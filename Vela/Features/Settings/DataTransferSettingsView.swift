//
//  DataTransferSettingsView.swift
//  Vela
//
//  导入与导出: bookmarks and history as files, in the formats other browsers
//  already read. The current distribution carries no cloud entitlement, so a
//  file the user saves is the migration path between devices.
//

import SwiftUI
import UniformTypeIdentifiers

struct DataTransferSettingsView: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.browserPalette) private var palette

    @State private var shareFile: ShareFile?
    @State private var showingBookmarkImporter = false
    @State private var showingHistoryImporter = false
    @State private var summary: String?

    private var transfer: DataTransferService {
        DataTransferService(bookmarks: env.bookmarks, history: env.history)
    }

    var body: some View {
        List {
            Section {
                Button {
                    exportBookmarks()
                } label: {
                    Label("导出书签（HTML）", systemImage: "square.and.arrow.up")
                }

                Button {
                    showingBookmarkImporter = true
                } label: {
                    Label("导入书签（HTML）", systemImage: "square.and.arrow.down")
                }
            } header: {
                Text("书签")
            } footer: {
                Text("Netscape 书签格式，Safari、Chrome、Firefox、Edge 都能导入。导入的书签会放进「其他书签」下的新文件夹，重复的地址会跳过。")
            }

            Section {
                Button {
                    exportHistory()
                } label: {
                    Label("导出历史（JSON）", systemImage: "square.and.arrow.up")
                }

                Button {
                    showingHistoryImporter = true
                } label: {
                    Label("导入历史（JSON）", systemImage: "square.and.arrow.down")
                }
            } header: {
                Text("历史记录")
            } footer: {
                Text("历史以 Vela 自己的 JSON 格式导出；导入的记录会按「导入」来源写进历史列表。")
            }

            if let summary, !summary.isEmpty {
                Section {
                    Text(summary)
                        .font(.footnote)
                        .foregroundStyle(palette.secondaryText)
                }
            }
        }
        .navigationTitle("导入与导出")
        .navigationBarTitleDisplayMode(.inline)
        .settingsList()
        .sheet(item: $shareFile) { file in
            ShareSheet(items: [file.url])
        }
        .fileImporter(
            isPresented: $showingBookmarkImporter,
            allowedContentTypes: [.html, .plainText],
            allowsMultipleSelection: false
        ) { result in
            importBookmarks(result)
        }
        .fileImporter(
            isPresented: $showingHistoryImporter,
            allowedContentTypes: [.json, .data],
            allowsMultipleSelection: false
        ) { result in
            importHistory(result)
        }
    }

    // MARK: Export

    private func exportBookmarks() {
        let html = transfer.bookmarksHTML()
        guard let url = writeTemporary(html, name: "Vela书签", fileExtension: "html") else {
            summary = "无法生成书签文件。"
            return
        }
        shareFile = ShareFile(url: url)
    }

    private func exportHistory() {
        let data = transfer.historyJSON()
        guard let url = writeTemporary(data, name: "Vela历史", fileExtension: "json") else {
            summary = "无法生成历史文件。"
            return
        }
        shareFile = ShareFile(url: url)
    }

    private func writeTemporary(_ text: String, name: String, fileExtension suffix: String) -> URL? {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(name).\(suffix)")
        do {
            try text.write(to: url, atomically: true, encoding: .utf8)
            return url
        } catch {
            return nil
        }
    }

    private func writeTemporary(_ data: Data, name: String, fileExtension suffix: String) -> URL? {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(name).\(suffix)")
        do {
            try data.write(to: url, options: .atomic)
            return url
        } catch {
            return nil
        }
    }

    // MARK: Import

    private func importBookmarks(_ result: Result<[URL], Error>) {
        guard case let .success(urls) = result, let url = urls.first else {
            if case let .failure(error) = result { summary = error.localizedDescription }
            return
        }
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }
        guard isWithinSizeLimit(url, bytes: 20 * 1024 * 1024) else {
            summary = "文件超过 20 MB，已拒绝导入。"
            return
        }
        guard let html = try? String(contentsOf: url, encoding: .utf8) else {
            summary = "无法读取这个文件。"
            return
        }
        summary = transfer.importBookmarks(html: html).message
    }

    /// A user-supplied file is parsed in memory, so its size is checked before
    /// it is read. A bookmark file is a few kilobytes; anything this large is
    /// not what the format is for.
    private func isWithinSizeLimit(_ url: URL, bytes limit: Int) -> Bool {
        let values = try? url.resourceValues(forKeys: [.fileSizeKey])
        guard let size = values?.fileSize else { return true }
        return size <= limit
    }

    private func importHistory(_ result: Result<[URL], Error>) {
        guard case let .success(urls) = result, let url = urls.first else {
            if case let .failure(error) = result { summary = error.localizedDescription }
            return
        }
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }
        guard isWithinSizeLimit(url, bytes: 50 * 1024 * 1024) else {
            summary = "文件超过 50 MB，已拒绝导入。"
            return
        }
        guard let data = try? Data(contentsOf: url) else {
            summary = "无法读取这个文件。"
            return
        }
        do {
            summary = try transfer.importHistory(data).message
        } catch {
            summary = "不是有效的 Vela 历史文件。"
        }
    }
}

/// A file handed to the share sheet. `URL` is not `Identifiable`, and the sheet
/// needs an item to key its presentation on.
private struct ShareFile: Identifiable {
    let id = UUID()
    let url: URL
}
