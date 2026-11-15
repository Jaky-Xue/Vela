import Foundation

private final class ScriptHTTPReceiver: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    enum Event { case response(URLResponse); case chunk(Data) }
    let script: InstalledUserScriptState
    let origin: URL
    var continuation: AsyncThrowingStream<Event, Error>.Continuation!
    var session: URLSession!
    var task: URLSessionDataTask!
    // Only the serial URLSession delegate queue changes received.
    private var received = 0
    init(script: InstalledUserScriptState, origin: URL) { self.script = script; self.origin = origin }
    func cancel() { task?.cancel(); session?.invalidateAndCancel() }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        guard response.expectedContentLength <= 24_000_000 else {
            continuation.finish(throwing: URLError(.dataLengthExceedsMaximum)); completionHandler(.cancel); return
        }
        continuation.yield(.response(response)); completionHandler(.allow)
    }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        received += data.count
        guard received <= 24_000_000 else { continuation.finish(throwing: URLError(.dataLengthExceedsMaximum)); dataTask.cancel(); return }
        continuation.yield(.chunk(data))
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error { continuation.finish(throwing: error) } else { continuation.finish() }
        session.finishTasksAndInvalidate()
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        guard let source = response.url, let target = request.url,
              source.scheme == target.scheme, source.host == target.host, source.port == target.port,
              UserScriptNativePolicy.allowsConnection(to: target, script: script, origin: origin) else { completionHandler(nil); return }
        completionHandler(request)
    }
}

enum UserScriptHTTP {
    /// Chunk reception stays off the UI actor. A ReadableStream receives deltas before completion.
    static func load(_ request: URLRequest, script: InstalledUserScriptState, origin: URL, buffered: Bool,
                     progress: (@MainActor @Sendable (Data, HTTPURLResponse?, Int) -> Void)?) async throws -> (Data, URLResponse) {
        let worker = Task.detached(priority: .utility) { () async throws -> (Data, URLResponse) in
            try Task.checkCancellation()
            let receiver = ScriptHTTPReceiver(script: script, origin: origin)
            let stream = AsyncThrowingStream<ScriptHTTPReceiver.Event, Error> { continuation in
                receiver.continuation = continuation
                let config = URLSessionConfiguration.ephemeral
                config.httpCookieStorage = nil; config.httpShouldSetCookies = false
                config.urlCredentialStorage = nil; config.urlCache = nil
                let queue = OperationQueue(); queue.maxConcurrentOperationCount = 1
                receiver.session = URLSession(configuration: config, delegate: receiver, delegateQueue: queue)
                receiver.task = receiver.session.dataTask(with: request)
                continuation.onTermination = { [weak receiver] _ in receiver?.cancel() }
                receiver.task.resume()
            }
            defer { receiver.cancel() }
            var response: URLResponse?, body = Data(), chunk = Data(), received = 0
            var reported = Date.distantPast
            for try await event in stream {
                try Task.checkCancellation()
                switch event {
                case let .response(value):
                    response = value
                    if let progress { await progress(Data(), value as? HTTPURLResponse, 0) }
                case let .chunk(data):
                    received += data.count
                    if buffered { body.append(data) }
                    if let progress {
                        chunk.append(data)
                        if Date().timeIntervalSince(reported) >= 0.05 || chunk.count >= 65_536 {
                            await progress(chunk, response as? HTTPURLResponse, received)
                            chunk.removeAll(keepingCapacity: true); reported = Date()
                        }
                    }
                }
            }
            try Task.checkCancellation()
            if let progress, !chunk.isEmpty { await progress(chunk, response as? HTTPURLResponse, received) }
            guard let response else { throw URLError(.badServerResponse) }
            return (body, response)
        }
        return try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
    }
}
