//
//  SegmentedDownloadSession.swift
//  Vela
//
//  A multi-connection download over URLSession.
//
//  One file is split into contiguous byte ranges, each fetched by its own
//  `URLSessionDownloadTask`. Completed ranges are kept as hidden part files
//  next to the destination, so pausing or a restart only re-fetches the ranges
//  that were still in flight. When every part is present they are concatenated
//  into the final file.
//
//  Servers are inconsistent about Range support. The `DownloadService` probes
//  with a HEAD request and only builds a segmented plan when the server
//  advertises `Accept-Ranges: bytes`; otherwise the same session runs a single
//  stream, which is also the path for an unknown Content-Length.
//
//  The class is a URLSession delegate, so its state mutates on the session's
//  serial delegate queue. Public entry points take the same lock. Callbacks to
//  the service are dispatched to the main queue.
//

import Foundation

// MARK: - Manifest

/// One byte range of a file.
struct DownloadSegment: Codable, Equatable, Sendable {
    var start: Int64
    var end: Int64
    var completed: Bool

    var length: Int64 { max(0, end - start + 1) }
}

/// The on-disk state of an in-progress segmented download.
struct SegmentedDownloadManifest: Codable, Equatable, Sendable {
    var guid: String
    var url: String
    var mimeType: String
    var suggestedFileName: String
    var destinationPath: String
    var totalBytes: Int64
    var segments: [DownloadSegment]
    /// A single stream has one segment but no Range header.
    var singleStream: Bool
    /// The identifier of the background URLSession carrying this transfer.
    ///
    /// Written when the transfer starts and stored with the manifest, because
    /// after an app termination the system hands the app an identifier and the
    /// app has to reconnect to exactly that session. A pause/resume gets a new
    /// identifier (and overwrites this), so a stale one is never reused.
    var backgroundIdentifier: String? = nil

    var completedBytes: Int64 {
        segments.reduce(into: 0) { total, segment in
            if segment.completed { total += segment.length }
        }
    }

    var isComplete: Bool { segments.allSatisfy(\.completed) }
}

// MARK: - Errors

enum SegmentedDownloadError: LocalizedError {
    case unexpectedStatus(Int)
    case missingBody
    case incompleteFile
    case noSpaceOrWriteFailure
    /// The background session kept no task for this transfer. The parts on
    /// disk are still good, so the record becomes resumable rather than failed.
    case interrupted

    var errorDescription: String? {
        switch self {
        case let .unexpectedStatus(status): return "服务器返回了 \(status)，无法下载。"
        case .missingBody: return "服务器没有返回文件内容。"
        case .incompleteFile: return "下载的文件不完整。"
        case .noSpaceOrWriteFailure: return "无法写入下载文件。"
        case .interrupted: return "下载在后台中断，已完成的部分已保留。"
        }
    }
}

// MARK: - Session

final class SegmentedDownloadSession: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    let guid: String
    private(set) var manifest: SegmentedDownloadManifest

    private let request: URLRequest
    private let onProgress: (Int64, Int64) -> Void
    private let onManifest: (SegmentedDownloadManifest) -> Void
    private let onComplete: (Result<URL, Error>) -> Void
    private let onFallback: (Error) -> Void

    private let lock = NSLock()
    private var session: URLSession?
    private var segmentByTask: [Int: Int] = [:]
    private var writtenByTask: [Int: Int64] = [:]
    private var activeTasks: Set<Int> = []
    private var completedBytes: Int64 = 0
    private var finished = false
    private var paused = false
    private var wholeFileReceived = false
    /// True when this object was attached to a session created by an earlier
    /// process. Those sessions may still be delivering callbacks for ranges
    /// that finished while the app was gone, so the merge waits for them.
    private var reconnected = false
    private var mergeScheduled = false

    init(
        manifest: SegmentedDownloadManifest,
        request: URLRequest,
        onProgress: @escaping (Int64, Int64) -> Void,
        onManifest: @escaping (SegmentedDownloadManifest) -> Void,
        onComplete: @escaping (Result<URL, Error>) -> Void,
        onFallback: @escaping (Error) -> Void
    ) {
        self.guid = manifest.guid
        self.manifest = manifest
        self.request = request
        self.onProgress = onProgress
        self.onManifest = onManifest
        self.onComplete = onComplete
        self.onFallback = onFallback
        self.completedBytes = manifest.completedBytes
        super.init()
    }

    // MARK: - Lifecycle

    func start() {
        lock.lock()
        guard !finished, !paused else {
            lock.unlock()
            return
        }
        let initial = completedBytes
        let total = manifest.totalBytes
        lock.unlock()

        onProgress(initial, total)

        lock.lock()
        if manifest.segments.allSatisfy(\.completed) {
            lock.unlock()
            mergeAndFinish()
            return
        }

        // A background configuration is the difference between "downloads
        // while the app is on screen" and "downloads while the app is
        // suspended": the transfer is owned by a system daemon, not by the
        // process, and the delegate is woken to deliver its events.
        // A fresh attempt always gets a fresh identifier: the previous
        // session may still be unwinding from a pause, and creating a second
        // URLSession under its identifier would attach this transfer to the
        // one that is being cancelled.
        let identifier = Self.makeIdentifier(guid: guid)
        manifest.backgroundIdentifier = identifier
        let configuration = Self.backgroundConfiguration(identifier: identifier)
        let session = URLSession(
            configuration: configuration,
            delegate: self,
            delegateQueue: Self.delegateQueue(guid: guid)
        )
        self.session = session
        let snapshot = manifest
        lock.unlock()
        onManifest(snapshot)

        lock.lock()
        for (index, segment) in manifest.segments.enumerated() where !segment.completed {
            var segmentRequest = request
            if !manifest.singleStream {
                segmentRequest.setValue(
                    "bytes=\(segment.start)-\(segment.end)",
                    forHTTPHeaderField: "Range"
                )
            }
            let task = session.downloadTask(with: segmentRequest)
            // The task outlives the process. Its description is how a
            // relaunched app maps the callback back to the byte range it
            // belongs to; task identifiers are new in every process.
            task.taskDescription = Self.taskDescription(index: index)
            segmentByTask[task.taskIdentifier] = index
            writtenByTask[task.taskIdentifier] = 0
            activeTasks.insert(task.taskIdentifier)
            task.resume()
        }
        lock.unlock()
    }

    // MARK: - Background session reconnection

    /// The prefix every background session identifier shares.
    static let identifierPrefix = "org.vela.download.segment."

    static func makeIdentifier(guid: String) -> String {
        "\(identifierPrefix)\(guid).\(UUID().uuidString.prefix(8).lowercased())"
    }

    /// The guid inside a session identifier, ignoring the attempt suffix.
    static func guid(fromIdentifier identifier: String) -> String? {
        guard identifier.hasPrefix(identifierPrefix) else { return nil }
        let rest = identifier.dropFirst(identifierPrefix.count)
        let guid = rest.split(separator: ".", maxSplits: 1).first.map(String.init) ?? ""
        return guid.isEmpty ? nil : guid
    }

    static func backgroundConfiguration(identifier: String) -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.background(withIdentifier: identifier)
        configuration.sessionSendsLaunchEvents = true
        configuration.isDiscretionary = false
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 60 * 60 * 24
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.httpMaximumConnectionsPerHost = 8
        return configuration
    }

    static func delegateQueue(guid: String) -> OperationQueue {
        let queue = OperationQueue()
        queue.name = "org.vela.download.\(guid)"
        queue.maxConcurrentOperationCount = 1
        return queue
    }

    private static let segmentPrefix = "vela-segment-"

    private static func taskDescription(index: Int) -> String {
        "\(segmentPrefix)\(index)"
    }

    private static func segmentIndex(from description: String?) -> Int? {
        guard let description, description.hasPrefix(segmentPrefix) else { return nil }
        return Int(description.dropFirst(segmentPrefix.count))
    }

    /// Connects to the background session that outlived the app.
    ///
    /// The tasks were created by a previous process, so their identifiers are
    /// unrelated to the ones this object would assign. getAllTasks plus the
    /// description stored on each task rebuilds the map; the session itself is
    /// created with the same identifier, which is what makes the system hand
    /// us the queued events.
    func reattach(identifier: String? = nil) {
        lock.lock()
        guard !finished, !paused, session == nil else {
            lock.unlock()
            return
        }
        let identifier = identifier ?? manifest.backgroundIdentifier ?? Self.makeIdentifier(guid: guid)
        manifest.backgroundIdentifier = identifier
        reconnected = true
        let configuration = Self.backgroundConfiguration(identifier: identifier)
        let session = URLSession(
            configuration: configuration,
            delegate: self,
            delegateQueue: Self.delegateQueue(guid: guid)
        )
        self.session = session
        let snapshot = manifest
        lock.unlock()

        onManifest(snapshot)
        onProgress(completedBytes, manifest.totalBytes)

        session.getAllTasks { [weak self] tasks in
            guard let self else { return }
            self.adopt(tasks: tasks)
        }
    }

    private func adopt(tasks: [URLSessionTask]) {
        lock.lock()
        guard !finished, !paused else {
            lock.unlock()
            return
        }
        for task in tasks {
            guard let index = Self.segmentIndex(from: task.taskDescription),
                  manifest.segments.indices.contains(index),
                  !manifest.segments[index].completed else { continue }
            segmentByTask[task.taskIdentifier] = index
            writtenByTask[task.taskIdentifier] = 0
            activeTasks.insert(task.taskIdentifier)
        }
        let pending = activeTasks.count
        lock.unlock()

        guard pending == 0 else { return }

        // No task survived. That can mean two very different things: every
        // range finished while the app was dead (its callbacks are queued and
        // about to arrive), or the system dropped the session altogether. Give
        // the queued callbacks a moment before declaring the transfer
        // interrupted — the parts on disk are not lost either way.
        DispatchQueue.global().asyncAfter(deadline: .now() + 4) { [weak self] in
            guard let self else { return }
            self.lock.lock()
            let shouldStop = !self.finished && !self.paused
                && self.activeTasks.isEmpty
                && !self.manifest.isComplete
            self.lock.unlock()
            if shouldStop {
                self.finish(.failure(SegmentedDownloadError.interrupted))
            }
        }
    }

    /// Stops the transfer but keeps completed parts and the manifest.
    func pause() {
        lock.lock()
        paused = true
        let session = self.session
        self.session = nil
        lock.unlock()
        session?.invalidateAndCancel()
    }

    private func finish(_ result: Result<URL, Error>) {
        lock.lock()
        guard !finished else {
            lock.unlock()
            return
        }
        finished = true
        let session = self.session
        self.session = nil
        lock.unlock()

        session?.finishTasksAndInvalidate()
        let completion = onComplete
        DispatchQueue.main.async {
            completion(result)
        }
    }

    // MARK: - Parts

    private var destination: URL {
        URL(fileURLWithPath: manifest.destinationPath)
    }

    private func partURL(_ index: Int) -> URL {
        destination
            .deletingLastPathComponent()
            .appendingPathComponent(".vela-\(guid)-part\(index)")
    }

    /// Removes every part file and the manifest for a task. Called when a
    /// download is deleted or falls back to WebKit.
    static func discardArtifacts(guid: String, destinationPath: String) {
        let fm = FileManager.default
        if !destinationPath.isEmpty {
            let directory = URL(fileURLWithPath: destinationPath).deletingLastPathComponent()
            if let contents = try? fm.contentsOfDirectory(atPath: directory.path) {
                for name in contents where name.hasPrefix(".vela-\(guid)-part") {
                    try? fm.removeItem(at: directory.appendingPathComponent(name))
                }
            }
        }
        ManifestStore.remove(guid: guid)
    }

    static func removeParts(manifest: SegmentedDownloadManifest) {
        let fm = FileManager.default
        let directory = URL(fileURLWithPath: manifest.destinationPath).deletingLastPathComponent()
        for index in manifest.segments.indices {
            try? fm.removeItem(
                at: directory.appendingPathComponent(".vela-\(manifest.guid)-part\(index)")
            )
        }
        ManifestStore.remove(guid: manifest.guid)
    }

    // MARK: - Merging

    private func mergeAndFinish() {
        lock.lock()
        let manifest = self.manifest
        lock.unlock()

        let fm = FileManager.default
        let outputURL = URL(fileURLWithPath: manifest.destinationPath)
        let directory = outputURL.deletingLastPathComponent()
        try? fm.createDirectory(at: directory, withIntermediateDirectories: true)

        if fm.fileExists(atPath: outputURL.path) {
            try? fm.removeItem(at: outputURL)
        }
        guard fm.createFile(atPath: outputURL.path, contents: nil) else {
            finish(.failure(SegmentedDownloadError.noSpaceOrWriteFailure))
            return
        }

        do {
            let output = try FileHandle(forWritingTo: outputURL)
            defer { try? output.close() }

            for (index, segment) in manifest.segments.enumerated() {
                let part = partURL(index)
                let input = try FileHandle(forReadingFrom: part)
                defer { try? input.close() }

                var written: Int64 = 0
                while true {
                    let data = try input.read(upToCount: 1_048_576) ?? Data()
                    if data.isEmpty { break }
                    try output.write(contentsOf: data)
                    written += Int64(data.count)
                }
                if written != segment.length {
                    throw SegmentedDownloadError.incompleteFile
                }
            }
            try output.synchronize()
        } catch {
            finish(.failure(error))
            return
        }

        if manifest.totalBytes > 0 {
            let size = (try? fm.attributesOfItem(atPath: outputURL.path)[.size] as? Int64) ?? 0
            guard size == manifest.totalBytes else {
                finish(.failure(SegmentedDownloadError.incompleteFile))
                return
            }
        }

        for index in manifest.segments.indices {
            try? fm.removeItem(at: partURL(index))
        }
        ManifestStore.remove(guid: guid)
        finish(.success(outputURL))
    }

    /// A server that ignores Range answers 200 with the whole file. That single
    /// response is a complete download; the other segment tasks are cancelled.
    private func adoptWholeFile(at location: URL) {
        lock.lock()
        guard !wholeFileReceived else {
            lock.unlock()
            return
        }
        wholeFileReceived = true
        paused = true
        let session = self.session
        self.session = nil
        lock.unlock()

        session?.invalidateAndCancel()

        let fm = FileManager.default
        let destination = URL(fileURLWithPath: manifest.destinationPath)
        try? fm.createDirectory(
            at: destination.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try? fm.removeItem(at: destination)
        do {
            try fm.moveItem(at: location, to: destination)
            ManifestStore.remove(guid: guid)
            finish(.success(destination))
        } catch {
            finish(.failure(error))
        }
    }

    /// Stops this transfer and asks the service to retry it through WebKit.
    ///
    /// Used when URLSession is looking at something that is not the file — a
    /// login page, a challenge — or failed before a byte arrived. The service
    /// owns the fallback because it holds the web view and the task record.
    private func requestFallback(_ error: Error) {
        lock.lock()
        guard !finished else {
            lock.unlock()
            return
        }
        finished = true
        paused = true
        let session = self.session
        self.session = nil
        lock.unlock()

        session?.invalidateAndCancel()
        let fallback = onFallback
        DispatchQueue.main.async {
            fallback(error)
        }
    }

    // MARK: - URLSessionDownloadDelegate

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        lock.lock()
        guard !finished, !paused else {
            lock.unlock()
            return
        }
        if let index = Self.segmentIndex(from: downloadTask.taskDescription),
           segmentByTask[downloadTask.taskIdentifier] == nil {
            segmentByTask[downloadTask.taskIdentifier] = index
        }
        if segmentByTask[downloadTask.taskIdentifier] != nil {
            writtenByTask[downloadTask.taskIdentifier] = totalBytesWritten
        }
        let inFlight = writtenByTask.values.reduce(0, +)
        let received = completedBytes + inFlight
        let total = manifest.totalBytes > 0 ? manifest.totalBytes : totalBytesExpectedToWrite
        lock.unlock()

        onProgress(received, max(0, total))
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        lock.lock()
        guard !finished, !paused else {
            lock.unlock()
            return
        }
        let index = segmentByTask[downloadTask.taskIdentifier]
            ?? Self.segmentIndex(from: downloadTask.taskDescription)
        guard let index, manifest.segments.indices.contains(index) else {
            lock.unlock()
            return
        }
        segmentByTask[downloadTask.taskIdentifier] = index
        let status = (downloadTask.response as? HTTPURLResponse)?.statusCode ?? 0
        let single = manifest.singleStream
        let segment = manifest.segments[index]
        let responseMime = (downloadTask.response?.mimeType ?? "").lowercased()
        lock.unlock()

        // A site that answered with a login or challenge page instead of the
        // file still returns 200 and bytes. WebKit may have the session that
        // URLSession lacks, so hand it the retry.
        if responseMime.contains("text/html"),
           !manifest.mimeType.lowercased().contains("html") {
            requestFallback(SegmentedDownloadError.unexpectedStatus(status))
            return
        }

        if single {
            let fm = FileManager.default
            let destination = URL(fileURLWithPath: manifest.destinationPath)
            do {
                try? fm.createDirectory(
                    at: destination.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                try? fm.removeItem(at: destination)
                try fm.moveItem(at: location, to: destination)
                ManifestStore.remove(guid: guid)
                finish(.success(destination))
            } catch {
                finish(.failure(error))
            }
            return
        }

        if status == 200 {
            adoptWholeFile(at: location)
            return
        }

        guard status == 206 || status == 0 else {
            finish(.failure(SegmentedDownloadError.unexpectedStatus(status)))
            return
        }

        let part = partURL(index)
        let fm = FileManager.default
        do {
            try? fm.removeItem(at: part)
            try fm.moveItem(at: location, to: part)
            let size = (try? fm.attributesOfItem(atPath: part.path)[.size] as? Int64) ?? 0
            guard size == segment.length else {
                throw SegmentedDownloadError.incompleteFile
            }
        } catch {
            finish(.failure(error))
            return
        }

        lock.lock()
        if manifest.segments.indices.contains(index) {
            manifest.segments[index].completed = true
        }
        completedBytes = manifest.completedBytes
        let snapshot = manifest
        let done = manifest.isComplete
        lock.unlock()

        onManifest(snapshot)
        if done {
            finishAllTasksThenMerge()
        }
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        lock.lock()
        activeTasks.remove(task.taskIdentifier)
        writtenByTask[task.taskIdentifier] = 0
        segmentByTask.removeValue(forKey: task.taskIdentifier)
        let remaining = activeTasks.count
        let allComplete = manifest.isComplete
        let paused = self.paused
        let finished = self.finished
        let anyReceived = completedBytes > 0
        lock.unlock()

        if finished || paused { return }

        if let error {
            if !anyReceived {
                requestFallback(error)
            } else {
                finish(.failure(error))
            }
            return
        }

        if remaining == 0 {
            if allComplete {
                scheduleMerge()
            } else if reconnected {
                // A reconnected session can report its adopted tasks complete
                // while callbacks for ranges that finished in the previous
                // process are still queued. Wait for them before deciding the
                // file is short.
                DispatchQueue.global().asyncAfter(deadline: .now() + 4) { [weak self] in
                    guard let self else { return }
                    self.lock.lock()
                    let complete = self.manifest.isComplete
                    let stopped = self.finished || self.paused
                    self.lock.unlock()
                    guard !stopped else { return }
                    if complete {
                        self.scheduleMerge()
                    } else {
                        self.finish(.failure(SegmentedDownloadError.interrupted))
                    }
                }
            } else {
                finish(.failure(SegmentedDownloadError.incompleteFile))
            }
        }
    }

    /// Tells UIKit that every event for a background session has been
    /// delivered, which releases the system's completion handler.
    func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        BackgroundDownloadRegistry.shared.complete(
            identifier: session.configuration.identifier ?? ""
        )
    }

    /// `didFinishDownloadingTo` fires before the matching completion callback.
    /// Merging there would stop the session we are still unwinding, so the
    /// merge happens on the next turn once the last task has completed.
    private func finishAllTasksThenMerge() {
        lock.lock()
        let remaining = activeTasks.count
        lock.unlock()
        if remaining == 0 {
            scheduleMerge()
        }
    }

    /// Runs the merge once the session has finished delivering its events.
    ///
    /// A reconnected session can report every adopted task as complete while
    /// callbacks for ranges that finished in the previous process are still
    /// queued. Merging immediately would find their part files missing and
    /// call a complete download incomplete, so the reconnected path waits
    /// briefly first.
    private func scheduleMerge() {
        lock.lock()
        if mergeScheduled || finished {
            lock.unlock()
            return
        }
        mergeScheduled = true
        let delay: TimeInterval = reconnected ? 3 : 0
        lock.unlock()

        DispatchQueue.global().asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self else { return }
            self.lock.lock()
            let stillFinished = self.finished
            self.lock.unlock()
            guard !stillFinished else { return }
            self.mergeAndFinish()
        }
    }

    // MARK: - Probe

    /// Whether `request` can be split into ranges, and the total length.
    ///
    /// Uses HEAD, which has no body to download. A server that rejects HEAD or
    /// omits `Accept-Ranges` gets the single-stream path.
    static func probe(request: URLRequest) async -> (supportsRanges: Bool, totalBytes: Int64, contentType: String?) {
        var head = request
        head.httpMethod = "HEAD"
        do {
            let (_, response) = try await URLSession.shared.data(for: head)
            guard let http = response as? HTTPURLResponse else {
                return (false, 0, nil)
            }
            let total = http.expectedContentLength > 0
                ? http.expectedContentLength
                : Int64(http.value(forHTTPHeaderField: "Content-Length") ?? "") ?? 0
            let accept = (http.value(forHTTPHeaderField: "Accept-Ranges") ?? "").lowercased()
            let supports = http.statusCode / 100 == 2
                && accept.contains("bytes")
                && total > 1_048_576
            return (supports, max(total, 0), http.mimeType)
        } catch {
            return (false, 0, nil)
        }
    }

    /// Splits `totalBytes` into at most `count` contiguous ranges.
    static func makeSegments(totalBytes: Int64, count: Int) -> [DownloadSegment] {
        guard totalBytes > 0 else {
            return [DownloadSegment(start: 0, end: 0, completed: false)]
        }
        let pieces = max(1, min(count, 8))
        let chunk = (totalBytes + Int64(pieces) - 1) / Int64(pieces)
        var segments: [DownloadSegment] = []
        var start: Int64 = 0
        while start < totalBytes {
            let end = min(start + chunk - 1, totalBytes - 1)
            segments.append(DownloadSegment(start: start, end: end, completed: false))
            start = end + 1
        }
        return segments
    }
}

// MARK: - Manifest storage

enum ManifestStore {
    static var directory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let directory = base.appendingPathComponent("Vela/DownloadSegments", isDirectory: true)
        if !FileManager.default.fileExists(atPath: directory.path) {
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        return directory
    }

    static func url(guid: String) -> URL {
        directory.appendingPathComponent("\(guid).json")
    }

    static func load(guid: String) -> SegmentedDownloadManifest? {
        guard let data = try? Data(contentsOf: url(guid: guid)),
              var manifest = try? JSONDecoder().decode(SegmentedDownloadManifest.self, from: data) else {
            return nil
        }

        // A completed part that is missing from disk (cleanup, a failed move)
        // must be fetched again rather than trusted from the manifest.
        let directory = URL(fileURLWithPath: manifest.destinationPath).deletingLastPathComponent()
        for index in manifest.segments.indices where manifest.segments[index].completed {
            let part = directory.appendingPathComponent(".vela-\(guid)-part\(index)")
            let size = (try? FileManager.default.attributesOfItem(atPath: part.path)[.size] as? Int64) ?? 0
            if size != manifest.segments[index].length {
                manifest.segments[index].completed = false
            }
        }
        return manifest
    }

    static func save(_ manifest: SegmentedDownloadManifest) {
        guard let data = try? JSONEncoder().encode(manifest) else { return }
        try? data.write(to: url(guid: manifest.guid), options: .atomic)
    }

    static func remove(guid: String) {
        try? FileManager.default.removeItem(at: url(guid: guid))
    }
}
