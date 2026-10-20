//
//  OfflinePageService.swift
//  Vela
//
//  Saving and opening pages without a network.
//
//  A save asks WebKit for a web archive — the same container Safari's
//  "Save to Files" uses — so the HTML and the resources the document actually
//  loaded travel together. The archive is written beside a preview image and a
//  small JSON manifest, and the row in `offline_pages` points at all three.
//  Opening a saved page loads that archive into a tab; no request is made.
//

import Foundation
import UIKit
import WebKit
import Observation
import CryptoKit

@MainActor
@Observable
public final class OfflinePageService {
    public private(set) var pages: [OfflinePageRecord] = []
    public private(set) var isSaving = false
    /// Set when the most recent save failed, for the shell's alert.
    public private(set) var lastError: String?

    private let repository: OfflinePageRepository

    public init(repository: OfflinePageRepository) {
        self.repository = repository
        reload()
    }

    public var count: Int { pages.count }

    public func reload() {
        pages = (try? repository.pages()) ?? []
    }

    // MARK: - Saving

    /// Saves the document currently on screen.
    ///
    /// Saving the same address twice updates the existing entry rather than
    /// stacking a second copy: the list is a shelf of pages, not a log of save
    /// actions.
    public func save(
        webView: WKWebView,
        urlString: String,
        title: String,
        faviconUrl: String = ""
    ) async -> Result<OfflinePageRecord, Error> {
        guard let url = URL(string: urlString),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https" else {
            return .failure(OfflinePageError.invalidUrl)
        }

        isSaving = true
        lastError = nil
        defer { isSaving = false }

        let preview = await capturePreview(of: webView)

        let archive: Data
        do {
            archive = try await Self.webArchiveData(of: webView)
        } catch {
            let failure = OfflinePageError.archiveFailed(error.localizedDescription)
            lastError = failure.localizedDescription
            return .failure(failure)
        }
        guard !archive.isEmpty else {
            let failure = OfflinePageError.noDocument
            lastError = failure.localizedDescription
            return .failure(failure)
        }

        let normalized = Self.normalizedUrlString(url.absoluteString)
        let existing = try? repository.page(normalizedUrl: normalized)
        let id = existing?.id ?? UUID().uuidString
        let directory = Self.directory(for: id)
        let snapshotURL = directory.appendingPathComponent("snapshot.webarchive")
        let manifestURL = directory.appendingPathComponent("manifest.json")
        let previewURL = directory.appendingPathComponent("preview.png")

        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try archive.write(to: snapshotURL, options: .atomic)
        } catch {
            let failure = OfflinePageError.writeFailed(error.localizedDescription)
            lastError = failure.localizedDescription
            return .failure(failure)
        }

        var previewPath: String?
        if let preview, let png = preview.pngData() {
            if (try? png.write(to: previewURL, options: .atomic)) != nil {
                previewPath = previewURL.path
            }
        } else if let existing, let old = existing.previewImageUri,
                  FileManager.default.fileExists(atPath: old) {
            previewPath = old
        }

        let resourceCount = Self.resourceCount(in: archive)
        let manifest = OfflinePageManifest(
            url: url.absoluteString,
            title: title,
            resourceCount: resourceCount,
            totalBytes: Int64(archive.count)
        )
        if let data = try? JSONEncoder().encode(manifest) {
            try? data.write(to: manifestURL, options: .atomic)
        }

        let host = url.host ?? ""
        let siteName = host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
        let record = OfflinePageRecord(
            id: id,
            originalUrl: url.absoluteString,
            normalizedUrl: normalized,
            urlHash: Self.hash(normalized),
            title: title,
            siteName: siteName,
            host: host,
            savedAt: Date(),
            updatedAt: Date(),
            snapshotPath: snapshotURL.path,
            manifestPath: manifestURL.path,
            previewImageUri: previewPath,
            faviconUri: faviconUrl.isEmpty ? existing?.faviconUri : faviconUrl,
            totalBytes: Int64(archive.count),
            resourceCount: resourceCount,
            failedResourceCount: 0,
            saveStatus: .complete,
            openStatus: .unread
        )

        do {
            try repository.upsert(record)
        } catch {
            lastError = error.localizedDescription
            return .failure(error)
        }

        reload()
        return .success(record)
    }

    // MARK: - Reading

    /// The archive bytes for a saved page, or nil when the file has gone
    /// missing since it was saved.
    public func archiveData(for page: OfflinePageRecord) -> Data? {
        try? Data(contentsOf: URL(fileURLWithPath: page.snapshotPath))
    }

    /// Marks a page as opened. The list sorts by save time, so this is a badge
    /// rather than an ordering change.
    public func markOpened(_ page: OfflinePageRecord) {
        try? repository.markOpened(id: page.id)
        if let index = pages.firstIndex(where: { $0.id == page.id }) {
            var updated = pages[index]
            updated.openStatus = .opened
            updated.updatedAt = Date()
            pages[index] = updated
        }
    }

    public func delete(_ page: OfflinePageRecord) {
        try? repository.remove(id: page.id)
        try? FileManager.default.removeItem(at: Self.directory(for: page.id))
        reload()
    }

    public func deleteAll() {
        for page in pages {
            try? FileManager.default.removeItem(at: Self.directory(for: page.id))
        }
        try? repository.clearAll()
        reload()
    }

    // MARK: - Files

    /// `Application Support/Vela/OfflinePages`, one directory per saved page.
    public static var rootDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let directory = base.appendingPathComponent("Vela/OfflinePages", isDirectory: true)
        if !FileManager.default.fileExists(atPath: directory.path) {
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        return directory
    }

    public static func directory(for id: String) -> URL {
        rootDirectory.appendingPathComponent(id, isDirectory: true)
    }

    // MARK: - Helpers

    /// Bridges the completion-handler form explicitly.
    ///
    /// The handler carries a `Result`, and the archive is the only output, so
    /// wrapping it here keeps the save path independent of which async import
    /// shape an SDK happens to expose.
    private static func webArchiveData(of webView: WKWebView) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            webView.createWebArchiveData { result in
                continuation.resume(with: result)
            }
        }
    }

    private func capturePreview(of webView: WKWebView) async -> UIImage? {
        await withCheckedContinuation { continuation in
            webView.takeSnapshot(with: nil) { image, _ in
                continuation.resume(returning: image)
            }
        }
    }

    /// The number of resources WebKit actually packed into the archive.
    ///
    /// A web archive is a property list whose `WebSubresources` array holds
    /// every image, stylesheet and script that was captured. The count is read
    /// from there rather than guessed, because the list shows it next to the
    /// file size.
    public static func resourceCount(in archive: Data) -> Int {
        guard let plist = try? PropertyListSerialization.propertyList(
            from: archive,
            options: [],
            format: nil
        ) as? [String: Any],
        let resources = plist["WebSubresources"] as? [[String: Any]] else {
            return 0
        }
        return resources.count
    }

    /// A URL with its fragment removed and its scheme/host lowercased, which
    /// is what makes "the same page" compare equal across two saves.
    public static func normalizedUrlString(_ raw: String) -> String {
        guard var components = URLComponents(string: raw) else { return raw }
        components.fragment = nil
        components.scheme = components.scheme?.lowercased()
        components.host = components.host?.lowercased()
        if (components.path.isEmpty) { components.path = "/" }
        return components.string ?? raw
    }

    public static func hash(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }
}
