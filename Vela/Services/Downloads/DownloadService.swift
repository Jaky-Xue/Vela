//
//  DownloadService.swift
//  Vela
//
//  Download handling over `WKDownload`.
//
//  WebKit moves the bytes. `WKNavigationDelegate` offers a `WKDownload` for any
//  response it would otherwise render, `WKDownloadDelegate` chooses the
//  destination, and cancelling hands back resume data — so this file drives the
//  status machine and the UI, and lets WebKit own the transfer.
//
//  What the user gives up for that: chunked multi-connection downloading, a
//  per-task driver and queue model, and a bandwidth throttle have no iOS
//  equivalent and are not implemented. Single-connection transfers with resume
//  are.
//

import Foundation
import WebKit
import Observation

@MainActor
@Observable
public final class DownloadService: NSObject {
    public private(set) var tasks: [DownloadTask] = []
    public private(set) var activeCount: Int = 0
    public var pendingPrompt: DownloadTask?

    private let repository: DownloadRepository
    private let settings: SettingsService

    /// Live WebKit transfers keyed by task guid.
    private var downloads: [String: WKDownload] = [:]
    /// The task guid each in-flight `WKDownload` belongs to. WebKit identifies a
    /// download by object identity, not by a string, so the map is kept both
    /// ways.
    private var guidByDownload: [ObjectIdentifier: String] = [:]
    private var progressObservations: [String: NSKeyValueObservation] = [:]

    public init(repository: DownloadRepository, settings: SettingsService) {
        self.repository = repository
        self.settings = settings
        super.init()
    }

    // MARK: - Listing

    public func reload(privacyMode: BrowserSessionPrivacyMode = .regular) {
        tasks = (try? repository.tasks(privacyMode: privacyMode)) ?? []
        activeCount = (try? repository.activeCount(privacyMode: privacyMode)) ?? 0
    }

    /// Transfers interrupted by an app termination, offered for resume at launch.
    /// terminal records for this purpose.
    @discardableResult
    public func reconcileInterruptedTasks() -> [DownloadTask] {
        let interrupted = (try? repository.interruptedTasks()) ?? []
        for var task in interrupted where task.status == .running {
            // WebKit does not survive app termination, so a task that was
            // running is now resumable, not running.
            task.status = .paused
            task.updatedAt = Date()
            try? repository.upsert(task)
        }
        reload()
        return interrupted
    }

    // MARK: - Destination

    /// The directory downloads land in.
    ///
    /// `Documents/Downloads` rather than `tmp`: a file the user asked to keep
    /// must survive the next launch, and the Documents directory is what makes
    /// it visible under "我的 iPhone ▸ Vela" in the Files app, which is the
    /// closest iOS gets to a user-chosen save path.
    public var downloadsDirectory: URL {
        let base = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let directory = base.appendingPathComponent("Downloads", isDirectory: true)
        if !FileManager.default.fileExists(atPath: directory.path) {
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        return directory
    }

    /// Resolves a non-colliding destination for a filename.
    ///
    /// download of the same name becomes `report (1).pdf` rather than
    /// overwriting the first.
    public func resolveDestination(suggestedFileName: String) -> URL {
        let directory = downloadsDirectory
        let sanitized = Self.sanitizeFileName(suggestedFileName)
        var candidate = directory.appendingPathComponent(sanitized)
        guard FileManager.default.fileExists(atPath: candidate.path) else { return candidate }

        let base = (sanitized as NSString).deletingPathExtension
        let ext = (sanitized as NSString).pathExtension
        var index = 1
        while FileManager.default.fileExists(atPath: candidate.path) {
            let name = ext.isEmpty ? "\(base) (\(index))" : "\(base) (\(index)).\(ext)"
            candidate = directory.appendingPathComponent(name)
            index += 1
            if index > 9999 { break }
        }
        return candidate
    }

    /// Strips path separators and control characters from a server-supplied
    /// filename. A filename is untrusted input: without this, a crafted
    /// `Content-Disposition` can escape the downloads directory.
    static func sanitizeFileName(_ raw: String) -> String {
        let forbidden = CharacterSet(charactersIn: "/\\:*?\"<>|\u{0}")
        let cleaned = raw
            .components(separatedBy: forbidden)
            .joined(separator: "_")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let withoutLeadingDots = cleaned.drop { $0 == "." }
        let result = String(withoutLeadingDots)
        return result.isEmpty ? "download" : String(result.prefix(200))
    }

    // MARK: - Starting

    /// Registers a transfer WebKit has already begun.
    ///
    /// Called from the navigation delegate's download policy callback. The task
    /// record is created here so the destination decision, which happens a moment
    /// later, already has a guid to attach to.
    @discardableResult
    public func register(
        download: WKDownload,
        request: URLRequest,
        boundary: BrowserDataBoundary,
        suggestedFileName: String
    ) -> DownloadTask {
        // WebKit does not report a suggested name at this point; the delegate
        // supplies one when it asks for the destination. Seed it from the URL so
        // the record has something to show if the delegate never fires.
        let seeded = suggestedFileName.isEmpty
            ? (request.url?.lastPathComponent ?? "download")
            : suggestedFileName

        let task = DownloadTask(
            profileId: boundary.profileId,
            privacyMode: boundary.privacyMode,
            dataScope: boundary.dataScope,
            requestUrl: request.url?.absoluteString ?? "",
            suggestedFileName: seeded,
            status: .running
        )

        downloads[task.guid] = download
        guidByDownload[ObjectIdentifier(download)] = task.guid
        try? repository.upsert(task)
        observeProgress(download: download, guid: task.guid)
        reload(privacyMode: task.privacyMode)
        return task
    }

    /// Observes `WKDownload.progress`.
    ///
    /// `WKDownload` conforms to `NSProgressReporting` from iOS 17, which is the
    /// deployment target, so byte counts come from WebKit rather than from
    /// polling the destination file.
    private func observeProgress(download: WKDownload, guid: String) {
        let observation = download.progress.observe(\.fractionCompleted, options: [.new]) { [weak self] progress, _ in
            let received = progress.completedUnitCount
            let total = progress.totalUnitCount
            Task { @MainActor [weak self] in
                self?.updateProgress(guid: guid, receivedBytes: received, totalBytes: total)
            }
        }
        progressObservations[guid] = observation
    }

    private func updateProgress(guid: String, receivedBytes: Int64, totalBytes: Int64) {
        guard var task = try? repository.task(guid: guid) else { return }
        task.receivedBytes = receivedBytes
        // `totalUnitCount` is -1 while the length is unknown, so a chunked
        // response keeps `totalBytes` at zero and the UI stays indeterminate.
        task.totalBytes = totalBytes > 0 ? totalBytes : 0
        task.updatedAt = Date()
        try? repository.upsert(task)

        if let index = tasks.firstIndex(where: { $0.guid == guid }) {
            tasks[index] = task
        } else {
            reload(privacyMode: task.privacyMode)
        }
    }

    // MARK: - Completion

    /// Records a finished transfer.
    public func complete(guid: String, destinationPath: String, resolvedFileName: String) {
        guard var task = try? repository.task(guid: guid) else { return }
        task.status = .completed
        task.destinationPath = destinationPath
        task.resolvedFileName = resolvedFileName
        task.completedAt = Date()
        task.updatedAt = Date()
        if task.totalBytes == 0 {
            task.totalBytes = task.receivedBytes
        }
        task.writtenBytes = task.receivedBytes
        try? repository.upsert(task)
        releaseTracking(guid: guid)
        reload(privacyMode: task.privacyMode)

        if settings.downloadSettings.autoRemoveCompleted {
            // The file stays on disk; only the record goes.
            try? repository.remove(guid: guid, deleteFile: false)
            reload(privacyMode: task.privacyMode)
        }
    }

    /// Records a failure, keeping the resume blob when WebKit supplied one.
    ///
    /// `resumeCapability` alongside the error. Here the capability is derived
    /// from whether resume data actually came back.
    public func fail(guid: String, error: Error, resumeData: Data?) {
        guard var task = try? repository.task(guid: guid) else { return }
        let nsError = error as NSError
        task.status = resumeData != nil ? .paused : .failed
        task.failure = DownloadFailure(
            reason: resumeData != nil ? "下载中断，可继续。" : "",
            errorCode: nsError.code
        )
        task.updatedAt = Date()
        try? repository.upsert(task)
        try? repository.storeResumeData(resumeData, guid: guid)
        releaseTracking(guid: guid)
        reload(privacyMode: task.privacyMode)
    }

    /// Cancels a transfer, storing resume data so it can be continued.
    public func cancel(guid: String) {
        guard let download = downloads[guid] else {
            // Not in flight: mark the record so the list stops showing it as
            // running.
            if var task = try? repository.task(guid: guid) {
                task.status = .cancelled
                task.updatedAt = Date()
                try? repository.upsert(task)
                reload(privacyMode: task.privacyMode)
            }
            return
        }
        download.cancel { [weak self] resumeData in
            Task { @MainActor [weak self] in
                guard let self else { return }
                guard var task = try? self.repository.task(guid: guid) else { return }
                task.status = .cancelled
                task.updatedAt = Date()
                try? self.repository.upsert(task)
                try? self.repository.storeResumeData(resumeData, guid: guid)
                self.releaseTracking(guid: guid)
                self.reload(privacyMode: task.privacyMode)
            }
        }
    }

    /// Resumes a paused transfer from its stored blob.
    ///
    /// The only way back in is `WKWebView.resumeDownload(fromResumeData:)`, which
    /// needs a web view to attach the transfer to, so the caller passes one.
    public func resume(guid: String, in webView: WKWebView) async {
        guard let data = try? repository.resumeData(guid: guid) else { return }
        guard var task = try? repository.task(guid: guid) else { return }

        // WebKit only offers the completion-handler form of this call, which
        // Swift imports as async. The download it hands back is non-optional —
        // a resume that cannot be started reports through the delegate instead.
        let download = await webView.resumeDownload(fromResumeData: data)
        download.delegate = self
        task.status = .running
        task.failure = nil
        task.updatedAt = Date()
        try? repository.upsert(task)

        downloads[guid] = download
        guidByDownload[ObjectIdentifier(download)] = guid
        observeProgress(download: download, guid: guid)
        reload(privacyMode: task.privacyMode)
    }

    private func releaseTracking(guid: String) {
        if let download = downloads.removeValue(forKey: guid) {
            guidByDownload.removeValue(forKey: ObjectIdentifier(download))
        }
        progressObservations[guid]?.invalidate()
        progressObservations.removeValue(forKey: guid)
    }

    // MARK: - Deleting

    public func remove(guid: String, deleteFile: Bool) {
        if downloads[guid] != nil { cancel(guid: guid) }
        try? repository.remove(guid: guid, deleteFile: deleteFile)
        reload()
    }

    public func removeCompleted() {
        try? repository.removeCompleted(privacyMode: .regular)
        reload()
    }

    /// Clears private download records at the end of a private session.
    public func clearPrivateRecords() {
        for (guid, download) in downloads {
            guard let task = try? repository.task(guid: guid), task.privacyMode == .private else { continue }
            download.cancel(nil)
            releaseTracking(guid: guid)
        }
        try? repository.clearPrivateRecords()
        reload()
    }

    func guid(for download: WKDownload) -> String? {
        guidByDownload[ObjectIdentifier(download)]
    }
}

// MARK: - WKDownloadDelegate

extension DownloadService: WKDownloadDelegate {
    /// Chooses the destination file.
    ///
    /// `WKDownloadDelegate` is a plain (non-`@MainActor`) protocol, so the body
    /// hops to the main actor before touching repository state.
    public nonisolated func download(
        _ download: WKDownload,
        decideDestinationUsing response: URLResponse,
        suggestedFilename: String,
        completionHandler: @escaping (URL?) -> Void
    ) {
        let mimeType = response.mimeType ?? ""
        let expectedLength = response.expectedContentLength
        let finalUrl = response.url?.absoluteString ?? ""

        Task { @MainActor in
            guard let guid = self.guid(for: download),
                  var task = try? self.repository.task(guid: guid) else {
                // Without a record there is nowhere to attribute the file, so
                // the download is refused rather than written somewhere the user
                // cannot find it.
                completionHandler(nil)
                return
            }

            let destination = self.resolveDestination(suggestedFileName: suggestedFilename)
            task.suggestedFileName = suggestedFilename
            task.resolvedFileName = destination.lastPathComponent
            task.destinationPath = destination.path
            task.mimeType = mimeType
            task.finalUrl = finalUrl
            task.totalBytes = expectedLength > 0 ? expectedLength : 0
            task.updatedAt = Date()
            try? self.repository.upsert(task)

            if let index = self.tasks.firstIndex(where: { $0.guid == guid }) {
                self.tasks[index] = task
            }
            completionHandler(destination)
        }
    }

    public nonisolated func downloadDidFinish(_ download: WKDownload) {
        Task { @MainActor in
            guard let guid = self.guid(for: download),
                  let task = try? self.repository.task(guid: guid) else { return }
            self.complete(
                guid: guid,
                destinationPath: task.destinationPath,
                resolvedFileName: task.resolvedFileName
            )
        }
    }

    public nonisolated func download(_ download: WKDownload, didFailWithError error: Error, resumeData: Data?) {
        Task { @MainActor in
            guard let guid = self.guid(for: download) else { return }
            self.fail(guid: guid, error: error, resumeData: resumeData)
        }
    }

    /// Follows redirects, updating the record so the list shows the URL the
    /// file actually came from rather than the one that was clicked.
    public nonisolated func download(
        _ download: WKDownload,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        decisionHandler: @escaping (WKDownload.RedirectPolicy) -> Void
    ) {
        Task { @MainActor in
            if let guid = self.guid(for: download),
               var task = try? self.repository.task(guid: guid),
               let url = request.url?.absoluteString {
                task.finalUrl = url
                task.updatedAt = Date()
                try? self.repository.upsert(task)
            }
            decisionHandler(.allow)
        }
    }
}
