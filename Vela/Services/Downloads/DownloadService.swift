//
//  DownloadService.swift
//  Vela
//
//  Download handling: a queue, segmented transfers and a WebKit fallback.
//
//  A download WebKit identifies is taken over by `SegmentedDownloadSession`,
//  which can split an https file into several range requests and writes the
//  parts next to the destination. A queue limits how many files transfer at
//  once. Requests that URLSession cannot serve faithfully — a plain-http file
//  under ATS, or a site that answers with a login page instead of the file —
//  fall back to WebKit's own `WKDownload`, which shares the web view's cookies
//  and ATS exception. WebKit's resume blob is still the resume path for that
//  fallback; segmented tasks resume from their manifest and part files.
//
//  Segmented transfers run on a background URLSession, so they continue while
//  the app is suspended and are reattached at launch if the system kept their
//  tasks. Queued transfers are started when the app goes to the background for
//  the same reason. What remains out of scope: bandwidth throttling, and
//  background continuation for the WebKit fallback, which has no URLSession to
//  put in the background.
//

import Foundation
import WebKit
import Observation

@MainActor
@Observable
public final class DownloadService: NSObject {
    public private(set) var tasks: [DownloadTask] = []
    public private(set) var activeCount: Int = 0
    public private(set) var pendingPrompt: DownloadTask?

    private let repository: DownloadRepository
    private let settings: SettingsService

    /// Live WebKit transfers keyed by task guid.
    private var downloads: [String: WKDownload] = [:]
    /// The task guid each in-flight `WKDownload` belongs to. WebKit identifies a
    /// download by object identity, not by a string, so the map is kept both
    /// ways.
    private var guidByDownload: [ObjectIdentifier: String] = [:]
    private var progressObservations: [String: NSKeyValueObservation] = [:]

    // MARK: Queue and segmented transfers

    /// A download that has a request but no transfer yet.
    private final class QueuedDownload {
        var task: DownloadTask
        var request: URLRequest
        weak var webView: WKWebView?
        /// A manifest loaded for a resume; when present the probe is skipped.
        var manifest: SegmentedDownloadManifest?

        init(
            task: DownloadTask,
            request: URLRequest,
            webView: WKWebView?,
            manifest: SegmentedDownloadManifest? = nil
        ) {
            self.task = task
            self.request = request
            self.webView = webView
            self.manifest = manifest
        }
    }

    /// Downloads waiting for a slot. Segmented transfers are fully driven here;
    /// a WebKit fallback counts against the same slots but starts immediately,
    /// because WebKit has no way to hold a transfer at the gate.
    private var queued: [String: QueuedDownload] = [:]
    /// Live segmented transfers.
    private var segmentedSessions: [String: SegmentedDownloadSession] = [:]
    /// Every transfer occupying a concurrency slot, whichever engine runs it.
    private var activeGuids: Set<String> = []
    /// The web view each task came from, kept weakly for the WebKit fallback.
    private var sourceWebViews: [String: WeakWebView] = [:]
    /// The confirmation sheet's payload.
    private var pendingPromptPayload: QueuedDownload?
    /// The enriched request each active transfer is using, for the WebKit fallback.
    private var preparedRequests: [String: URLRequest] = [:]
    /// Progress is written to SQLite at most this often per task.
    private var lastProgressPersist: [String: Date] = [:]

    private final class WeakWebView {
        weak var view: WKWebView?
        init(_ view: WKWebView?) { self.view = view }
    }

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
            // A segmented transfer may still be running in the system's
            // background daemon, with its identifier recorded in the manifest.
            // Reattaching is what lets that transfer finish without the user
            // pressing resume. Anything with no live session behind it — a
            // WebKit fallback, or a manifest written by a build that did not
            // use background sessions — becomes resumable.
            if let manifest = ManifestStore.load(guid: task.guid),
               let identifier = manifest.backgroundIdentifier,
               !manifest.isComplete,
               let url = URL(string: manifest.url) {
                activeGuids.insert(task.guid)
                // The registry may already have reconnected this session when
                // UIKit delivered its launch event before boot finished.
                if segmentedSessions[task.guid] == nil {
                    beginSegmented(
                        manifest: manifest,
                        request: URLRequest(url: url),
                        reattaching: identifier
                    )
                }
            } else {
                task.status = .paused
                task.updatedAt = Date()
                try? repository.upsert(task)
            }
        }
        reload()
        refreshActiveCount()
        pumpQueue()
        return interrupted
    }

    /// Installs the bridge that lets a relaunch find its background sessions.
    ///
    /// Called once at boot, before the first window exists. The registry may
    /// already be holding identifiers from `handleEventsForBackgroundURLSession`;
    /// installing the reconnector drains them, so an event delivered before
    /// the environment was built is not lost.
    public func prepareBackgroundSessionReconnection() {
        BackgroundDownloadRegistry.shared.setReconnector { [weak self] identifier in
            Task { @MainActor in
                self?.reattachBackgroundSession(identifier: identifier)
            }
        }
    }

    /// Starts every queued transfer so it can continue on the background
    /// session after the app is suspended.
    ///
    /// The concurrency limit exists to keep the *foreground* responsive; a
    /// suspended process is not rendering anything, and a queued file the user
    /// asked for should not sit still until they come back. The limit resumes
    /// applying as soon as the queue is pumped again.
    public func continueQueuedInBackground() {
        guard !queued.isEmpty else { return }
        let pending = queued.values.filter { $0.task.status == .pending }
        for item in pending {
            queued.removeValue(forKey: item.task.guid)
            activeGuids.insert(item.task.guid)
            Task { @MainActor [weak self] in
                await self?.startQueued(item)
            }
        }
        refreshActiveCount()
    }

    /// Reconnects a background session named by UIKit.
    private func reattachBackgroundSession(identifier: String) {
        guard let guid = SegmentedDownloadSession.guid(fromIdentifier: identifier) else {
            // Not a session this service owns. The system is still waiting on
            // the handler, so it is released even though there is no work.
            BackgroundDownloadRegistry.shared.complete(identifier: identifier)
            return
        }

        if let existing = segmentedSessions[guid] {
            existing.reattach(identifier: identifier)
            return
        }

        guard let manifest = ManifestStore.load(guid: guid),
              !manifest.isComplete,
              let url = URL(string: manifest.url) else {
            // Nothing on disk belongs to this session any more. Releasing the
            // handler is still required, or the system keeps waiting.
            BackgroundDownloadRegistry.shared.complete(identifier: identifier)
            return
        }

        if var task = try? repository.task(guid: guid) {
            task.status = .running
            task.failure = nil
            task.updatedAt = Date()
            try? repository.upsert(task)
            updateTaskInMemory(task)
            reload(privacyMode: task.privacyMode)
        }

        activeGuids.insert(guid)
        refreshActiveCount()
        beginSegmented(
            manifest: manifest,
            request: URLRequest(url: url),
            reattaching: identifier
        )
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

    // MARK: - Web downloads and the queue

    /// Accepts a download WebKit has identified, then drives it with the
    /// browser's own transfer engine.
    ///
    /// The navigation is cancelled by the caller in favour of this path. The
    /// request has already been built (cookie and referer enrichment happens
    /// here), and the confirmation preference decides whether it is enqueued
    /// now or offered first.
    public func handleWebDownload(
        request: URLRequest,
        boundary: BrowserDataBoundary,
        webView: WKWebView,
        suggestedFileName: String,
        mimeType: String,
        totalBytes: Int64
    ) {
        let seeded = suggestedFileName.isEmpty
            ? (request.url?.lastPathComponent ?? "download")
            : suggestedFileName
        let task = DownloadTask(
            profileId: boundary.profileId,
            privacyMode: boundary.privacyMode,
            dataScope: boundary.dataScope,
            requestUrl: request.url?.absoluteString ?? "",
            suggestedFileName: seeded,
            mimeType: mimeType,
            status: .pending,
            totalBytes: max(totalBytes, 0)
        )
        let item = QueuedDownload(task: task, request: request, webView: webView)

        if settings.downloadSettings.confirmBeforeDownload {
            pendingPrompt = task
            pendingPromptPayload = item
        } else {
            enqueue(item)
        }
    }

    /// Starts a download a user script asked for with `GM_download`.
    ///
    /// The confirmation prompt is bypassed: the script's author asked for the
    /// transfer and the user installed the script. Everything else — queueing,
    /// segmented transfer, the WebKit fallback, the list entry — is the normal
    /// path.
    @discardableResult
    public func enqueueScriptDownload(
        url: URL,
        suggestedFileName: String,
        boundary: BrowserDataBoundary,
        webView: WKWebView?
    ) -> DownloadTask {
        let seeded = suggestedFileName.isEmpty
            ? (url.lastPathComponent.isEmpty ? "download" : url.lastPathComponent)
            : suggestedFileName
        let task = DownloadTask(
            profileId: boundary.profileId,
            privacyMode: boundary.privacyMode,
            dataScope: boundary.dataScope,
            requestUrl: url.absoluteString,
            suggestedFileName: Self.sanitizeFileName(seeded),
            status: .pending
        )
        let item = QueuedDownload(task: task, request: URLRequest(url: url), webView: webView)
        enqueue(item)
        return task
    }

    public func confirmPendingPrompt() {
        guard let item = pendingPromptPayload else {
            pendingPrompt = nil
            return
        }
        pendingPrompt = nil
        pendingPromptPayload = nil
        enqueue(item)
    }

    public func dismissPendingPrompt() {
        pendingPrompt = nil
        pendingPromptPayload = nil
    }

    private func enqueue(_ item: QueuedDownload) {
        var task = item.task
        if task.destinationPath.isEmpty {
            let destination = resolveDestination(suggestedFileName: task.suggestedFileName)
            task.resolvedFileName = destination.lastPathComponent
            task.destinationPath = destination.path
        }
        task.status = .pending
        task.failure = nil
        task.updatedAt = Date()
        item.task = task

        try? repository.upsert(task)
        queued[task.guid] = item
        sourceWebViews[task.guid] = WeakWebView(item.webView)
        reload(privacyMode: task.privacyMode)
        pumpQueue()
    }

    /// Starts queued downloads up to the concurrency limit, oldest first.
    private func pumpQueue() {
        let limit = settings.downloadSettings.maxConcurrentDownloadCount
        while activeGuids.count < limit {
            let next = queued.values
                .filter { $0.task.status == .pending }
                .sorted { $0.task.createdAt < $1.task.createdAt }
                .first
            guard let next else { break }
            queued.removeValue(forKey: next.task.guid)
            activeGuids.insert(next.task.guid)
            Task { @MainActor [weak self] in
                await self?.startQueued(next)
            }
        }
        refreshActiveCount()
    }

    private func refreshActiveCount() {
        activeCount = activeGuids.count
    }

    private func startQueued(_ item: QueuedDownload) async {
        let guid = item.task.guid
        guard var task = try? repository.task(guid: guid),
              let url = item.request.url else {
            activeGuids.remove(guid)
            sourceWebViews.removeValue(forKey: guid)
            refreshActiveCount()
            pumpQueue()
            return
        }

        task.status = .running
        task.failure = nil
        task.updatedAt = Date()
        item.task = task
        try? repository.upsert(task)
        updateTaskInMemory(task)
        reload(privacyMode: task.privacyMode)
        refreshActiveCount()

        let prepared = await preparedRequest(for: item)
        preparedRequests[guid] = prepared

        // URLSession sits under full ATS while web content is allowed
        // cleartext. A plain-http file would fail here, so hand it straight to
        // WebKit, whose download shares the web view's exception.
        if prepared.url?.scheme?.lowercased() != "https" {
            fallbackToWebKit(guid: guid, error: SegmentedDownloadError.unexpectedStatus(0))
            return
        }

        var plan: SegmentedDownloadManifest?
        if let existing = item.manifest {
            // A resume continues the exact plan on disk; the parts belong to
            // these ranges and this destination.
            plan = existing
        } else if settings.downloadSettings.usesSegmentedDownloads {
            let probe = await SegmentedDownloadSession.probe(request: prepared)
            if probe.supportsRanges {
                let total = probe.totalBytes > 0 ? probe.totalBytes : task.totalBytes
                if total > 0 {
                    plan = SegmentedDownloadManifest(
                        guid: guid,
                        url: prepared.url?.absoluteString ?? url.absoluteString,
                        mimeType: task.mimeType,
                        suggestedFileName: task.suggestedFileName,
                        destinationPath: task.destinationPath,
                        totalBytes: total,
                        segments: SegmentedDownloadSession.makeSegments(
                            totalBytes: total,
                            count: settings.downloadSettings.segmentCount
                        ),
                        singleStream: false
                    )
                    task.totalBytes = total
                }
            }
        }

        if plan == nil {
            plan = SegmentedDownloadManifest(
                guid: guid,
                url: prepared.url?.absoluteString ?? url.absoluteString,
                mimeType: task.mimeType,
                suggestedFileName: task.suggestedFileName,
                destinationPath: task.destinationPath,
                totalBytes: max(task.totalBytes, 0),
                segments: SegmentedDownloadSession.makeSegments(
                    totalBytes: max(task.totalBytes, 0),
                    count: 1
                ),
                singleStream: true
            )
        }

        guard let plan else {
            activeGuids.remove(guid)
            failSegmented(guid: guid, error: SegmentedDownloadError.missingBody)
            return
        }

        try? repository.upsert(task)
        updateTaskInMemory(task)
        ManifestStore.save(plan)

        beginSegmented(manifest: plan, request: prepared)
    }

    /// Builds the transfer object and either starts it or reattaches it to a
    /// background session from a previous process.
    @discardableResult
    private func beginSegmented(
        manifest: SegmentedDownloadManifest,
        request: URLRequest,
        reattaching identifier: String? = nil
    ) -> SegmentedDownloadSession {
        let guid = manifest.guid
        let session = SegmentedDownloadSession(
            manifest: manifest,
            request: request,
            onProgress: { [weak self] received, total in
                Task { @MainActor in
                    self?.applyProgress(guid: guid, received: received, total: total)
                }
            },
            onManifest: { snapshot in
                ManifestStore.save(snapshot)
            },
            onComplete: { [weak self] result in
                Task { @MainActor in
                    self?.finishSegmented(guid: guid, result: result)
                }
            },
            onFallback: { [weak self] error in
                Task { @MainActor in
                    self?.fallbackToWebKit(guid: guid, error: error)
                }
            }
        )
        segmentedSessions[guid] = session
        if let identifier {
            session.reattach(identifier: identifier)
        } else {
            session.start()
        }
        return session
    }

    /// The request the transfer engine actually sends: the original method and
    /// URL, plus the web view's cookies, referer and user agent. URLSession has
    /// no session of its own, so everything the site needs to recognise the
    /// request has to be copied into the headers.
    private func preparedRequest(for item: QueuedDownload) async -> URLRequest {
        var request = item.request
        request.httpMethod = request.httpMethod ?? "GET"
        // A compressed body cannot be range-sliced; ask for the identity encoding.
        if request.value(forHTTPHeaderField: "Accept-Encoding") == nil {
            request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        }

        guard let webView = item.webView else { return request }

        if let referer = webView.url?.absoluteString {
            request.setValue(referer, forHTTPHeaderField: "Referer")
        }
        if let userAgent = (try? await webView.evaluateJavaScript("navigator.userAgent")) as? String,
           !userAgent.isEmpty {
            request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        }

        let cookies = await cookies(from: webView.configuration.websiteDataStore)
        let fields = HTTPCookie.requestHeaderFields(with: cookies)
        for (key, value) in fields {
            if let existing = request.value(forHTTPHeaderField: key) {
                request.setValue(existing + "; " + value, forHTTPHeaderField: key)
            } else {
                request.setValue(value, forHTTPHeaderField: key)
            }
        }
        return request
    }

    private func cookies(from store: WKWebsiteDataStore) async -> [HTTPCookie] {
        await withCheckedContinuation { continuation in
            store.httpCookieStore.getAllCookies { cookies in
                continuation.resume(returning: cookies)
            }
        }
    }

    private func applyProgress(guid: String, received: Int64, total: Int64) {
        var updated: DownloadTask?
        if let index = tasks.firstIndex(where: { $0.guid == guid }) {
            var task = tasks[index]
            task.receivedBytes = max(received, task.receivedBytes)
            if total > 0 { task.totalBytes = total }
            task.updatedAt = Date()
            tasks[index] = task
            updated = task
        } else if var task = try? repository.task(guid: guid) {
            task.receivedBytes = max(received, task.receivedBytes)
            if total > 0 { task.totalBytes = total }
            task.updatedAt = Date()
            updated = task
            reload(privacyMode: task.privacyMode)
        }

        guard let task = updated else { return }
        let now = Date()
        if now.timeIntervalSince(lastProgressPersist[guid] ?? .distantPast) > 0.75 {
            lastProgressPersist[guid] = now
            try? repository.upsert(task)
        }
    }

    private func updateTaskInMemory(_ task: DownloadTask) {
        if let index = tasks.firstIndex(where: { $0.guid == task.guid }) {
            tasks[index] = task
        }
    }

    private func finishSegmented(guid: String, result: Result<URL, Error>) {
        segmentedSessions.removeValue(forKey: guid)
        activeGuids.remove(guid)
        lastProgressPersist.removeValue(forKey: guid)
        preparedRequests.removeValue(forKey: guid)
        sourceWebViews.removeValue(forKey: guid)
        refreshActiveCount()

        switch result {
        case let .success(url):
            complete(guid: guid, destinationPath: url.path, resolvedFileName: url.lastPathComponent)
        case let .failure(error):
            failSegmented(guid: guid, error: error)
        }
        pumpQueue()
    }

    private func failSegmented(guid: String, error: Error) {
        guard var task = try? repository.task(guid: guid) else { return }
        activeGuids.remove(guid)
        let manifest = ManifestStore.load(guid: guid)
        let resumable = manifest != nil && !(manifest?.isComplete ?? false)
        task.status = resumable ? .paused : .failed
        task.failure = DownloadFailure(
            reason: resumable ? "下载中断，可继续。" : error.localizedDescription,
            errorCode: (error as NSError).code
        )
        task.updatedAt = Date()
        try? repository.upsert(task)
        updateTaskInMemory(task)
        if !resumable, let manifest {
            SegmentedDownloadSession.removeParts(manifest: manifest)
        }
        segmentedSessions.removeValue(forKey: guid)
        preparedRequests.removeValue(forKey: guid)
        sourceWebViews.removeValue(forKey: guid)
        refreshActiveCount()
        reload(privacyMode: task.privacyMode)
        pumpQueue()
    }

    /// If the URLSession transfer failed before receiving any byte, let WebKit
    /// retry the same request. WebKit may succeed where URLSession cannot when a
    /// site depends on its own session state or auth challenge.
    private func fallbackToWebKit(guid: String, error: Error) {
        segmentedSessions.removeValue(forKey: guid)
        if let manifest = ManifestStore.load(guid: guid) {
            SegmentedDownloadSession.removeParts(manifest: manifest)
        }
        ManifestStore.remove(guid: guid)

        guard let webView = sourceWebViews[guid]?.view,
              let request = preparedRequests[guid] else {
            activeGuids.remove(guid)
            failSegmented(guid: guid, error: error)
            return
        }

        webView.startDownload(using: request) { [weak self] download in
            Task { @MainActor in
                guard let self else { return }
                self.attachWebKitFallback(download: download, guid: guid)
            }
        }
    }

    private func attachWebKitFallback(download: WKDownload, guid: String) {
        download.delegate = self
        downloads[guid] = download
        guidByDownload[ObjectIdentifier(download)] = guid
        observeProgress(download: download, guid: guid)

        if var task = try? repository.task(guid: guid), task.status != .running {
            task.status = .running
            task.failure = nil
            task.updatedAt = Date()
            try? repository.upsert(task)
            updateTaskInMemory(task)
            reload(privacyMode: task.privacyMode)
        }
        refreshActiveCount()
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
        activeGuids.insert(task.guid)
        try? repository.upsert(task)
        observeProgress(download: download, guid: task.guid)
        reload(privacyMode: task.privacyMode)
        refreshActiveCount()
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
        // Progress is persisted on a throttle; a finished file is complete by
        // definition, so the record must not show a byte short of it.
        if task.totalBytes > 0 {
            task.receivedBytes = task.totalBytes
        }
        task.writtenBytes = task.receivedBytes
        try? repository.upsert(task)
        releaseTracking(guid: guid)
        segmentedSessions.removeValue(forKey: guid)
        sourceWebViews.removeValue(forKey: guid)
        preparedRequests.removeValue(forKey: guid)
        lastProgressPersist.removeValue(forKey: guid)
        activeGuids.remove(guid)
        SegmentedDownloadSession.discardArtifacts(guid: guid, destinationPath: task.destinationPath)
        refreshActiveCount()
        reload(privacyMode: task.privacyMode)
        pumpQueue()

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
        segmentedSessions.removeValue(forKey: guid)
        sourceWebViews.removeValue(forKey: guid)
        preparedRequests.removeValue(forKey: guid)
        lastProgressPersist.removeValue(forKey: guid)
        activeGuids.remove(guid)
        if resumeData == nil {
            SegmentedDownloadSession.discardArtifacts(guid: guid, destinationPath: task.destinationPath)
            ManifestStore.remove(guid: guid)
        }
        refreshActiveCount()
        reload(privacyMode: task.privacyMode)
        pumpQueue()
    }

    /// Cancels a transfer, storing resume data when the engine supplies it.
    public func cancel(guid: String) {
        if let session = segmentedSessions.removeValue(forKey: guid) {
            session.pause()
            stopSegmented(guid: guid, status: .cancelled)
            if let manifest = ManifestStore.load(guid: guid) {
                SegmentedDownloadSession.removeParts(manifest: manifest)
            }
            ManifestStore.remove(guid: guid)
            return
        }

        if let item = queued.removeValue(forKey: guid) {
            var task = item.task
            task.status = .cancelled
            task.updatedAt = Date()
            try? repository.upsert(task)
            sourceWebViews.removeValue(forKey: guid)
            activeGuids.remove(guid)
            refreshActiveCount()
            reload(privacyMode: task.privacyMode)
            pumpQueue()
            return
        }

        guard let download = downloads[guid] else {
            // Not in flight: mark the record so the list stops showing it as
            // running.
            if var task = try? repository.task(guid: guid) {
                task.status = .cancelled
                task.updatedAt = Date()
                try? repository.upsert(task)
                activeGuids.remove(guid)
                refreshActiveCount()
                reload(privacyMode: task.privacyMode)
                pumpQueue()
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
                self.activeGuids.remove(guid)
                self.refreshActiveCount()
                self.reload(privacyMode: task.privacyMode)
                self.pumpQueue()
            }
        }
    }

    /// Pauses a transfer without discarding its progress.
    ///
    /// A segmented download keeps its completed parts and manifest; a paused
    /// WebKit transfer keeps its resume blob; a queued task simply leaves the
    /// queue. All three can be resumed later.
    public func pause(guid: String) {
        if let session = segmentedSessions.removeValue(forKey: guid) {
            session.pause()
            stopSegmented(guid: guid, status: .paused)
            return
        }

        if let item = queued.removeValue(forKey: guid) {
            var task = item.task
            task.status = .paused
            task.updatedAt = Date()
            try? repository.upsert(task)
            sourceWebViews.removeValue(forKey: guid)
            activeGuids.remove(guid)
            refreshActiveCount()
            reload(privacyMode: task.privacyMode)
            pumpQueue()
            return
        }

        guard let download = downloads[guid] else {
            if var task = try? repository.task(guid: guid) {
                task.status = .paused
                task.updatedAt = Date()
                try? repository.upsert(task)
                activeGuids.remove(guid)
                refreshActiveCount()
                reload(privacyMode: task.privacyMode)
                pumpQueue()
            }
            return
        }
        download.cancel { [weak self] resumeData in
            Task { @MainActor [weak self] in
                guard let self else { return }
                guard var task = try? self.repository.task(guid: guid) else { return }
                task.status = .paused
                task.updatedAt = Date()
                task.failure = DownloadFailure(reason: "已暂停，可继续。")
                try? self.repository.upsert(task)
                try? self.repository.storeResumeData(resumeData, guid: guid)
                self.releaseTracking(guid: guid)
                self.activeGuids.remove(guid)
                self.refreshActiveCount()
                self.reload(privacyMode: task.privacyMode)
                self.pumpQueue()
            }
        }
    }

    /// Marks a segmented task stopped and releases its slot.
    private func stopSegmented(guid: String, status: DownloadStatus) {
        if var task = try? repository.task(guid: guid) {
            task.status = status
            task.updatedAt = Date()
            try? repository.upsert(task)
            reload(privacyMode: task.privacyMode)
        }
        segmentedSessions.removeValue(forKey: guid)
        preparedRequests.removeValue(forKey: guid)
        sourceWebViews.removeValue(forKey: guid)
        lastProgressPersist.removeValue(forKey: guid)
        activeGuids.remove(guid)
        refreshActiveCount()
        pumpQueue()
    }

    /// Resumes a paused transfer.
    ///
    /// A segmented manifest is resumed in place; a WebKit resume blob is handed
    /// back to the web view; anything else is re-queued from its URL. The web
    /// view is optional because a segmented resume can continue without one —
    /// the manifest already has the URL and the parts.
    public func resume(guid: String, in webView: WKWebView?) async {
        guard var task = try? repository.task(guid: guid) else { return }

        let manifest = ManifestStore.load(guid: guid)
        if manifest != nil || (try? repository.resumeData(guid: guid)) == nil {
            let urlString = manifest.map { $0.url.isEmpty ? task.requestUrl : $0.url } ?? task.requestUrl
            guard let url = URL(string: urlString) else { return }
            // A record written before the destination was chosen has no path;
            // resolve one now, or the parts and the merge would have nowhere
            // to go.
            if task.destinationPath.isEmpty {
                let destination = resolveDestination(suggestedFileName: task.suggestedFileName)
                task.resolvedFileName = destination.lastPathComponent
                task.destinationPath = destination.path
            }
            task.status = .pending
            task.failure = nil
            task.updatedAt = Date()
            try? repository.upsert(task)
            let item = QueuedDownload(
                task: task,
                request: URLRequest(url: url),
                webView: webView,
                manifest: manifest
            )
            queued[guid] = item
            sourceWebViews[guid] = WeakWebView(webView)
            reload(privacyMode: task.privacyMode)
            pumpQueue()
            return
        }

        guard let webView, let data = try? repository.resumeData(guid: guid) else { return }

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
        activeGuids.insert(guid)
        observeProgress(download: download, guid: guid)
        reload(privacyMode: task.privacyMode)
        refreshActiveCount()
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
        if let session = segmentedSessions.removeValue(forKey: guid) {
            session.pause()
        }
        if let download = downloads[guid] {
            download.cancel(nil)
            releaseTracking(guid: guid)
        }
        queued.removeValue(forKey: guid)
        sourceWebViews.removeValue(forKey: guid)
        preparedRequests.removeValue(forKey: guid)
        lastProgressPersist.removeValue(forKey: guid)
        activeGuids.remove(guid)
        if let task = try? repository.task(guid: guid) {
            SegmentedDownloadSession.discardArtifacts(guid: guid, destinationPath: task.destinationPath)
        } else {
            ManifestStore.remove(guid: guid)
        }
        refreshActiveCount()
        try? repository.remove(guid: guid, deleteFile: deleteFile)
        reload()
        pumpQueue()
    }

    public func removeCompleted() {
        try? repository.removeCompleted(privacyMode: .regular)
        reload()
    }

    /// Clears private download records at the end of a private session.
    public func clearPrivateRecords() {
        let privateTasks = (try? repository.tasks(privacyMode: .private)) ?? []

        for task in privateTasks {
            if let session = segmentedSessions.removeValue(forKey: task.guid) {
                session.pause()
            }
            if let download = downloads[task.guid] {
                download.cancel(nil)
                releaseTracking(guid: task.guid)
            }
            queued.removeValue(forKey: task.guid)
            sourceWebViews.removeValue(forKey: task.guid)
            preparedRequests.removeValue(forKey: task.guid)
            lastProgressPersist.removeValue(forKey: task.guid)
            activeGuids.remove(task.guid)
            SegmentedDownloadSession.discardArtifacts(
                guid: task.guid,
                destinationPath: task.destinationPath
            )
        }

        try? repository.clearPrivateRecords()
        refreshActiveCount()
        reload()
        pumpQueue()
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
