import Foundation

enum UserScriptHTTP {
    /// Receive off the UI actor. Progress carries deltas, never cumulative bodies.
    static func load(_ request: URLRequest, script: InstalledUserScriptState, origin: URL, buffered: Bool,
                     progress: (@MainActor @Sendable (Data, HTTPURLResponse?, Int) -> Void)?) async throws -> (Data, URLResponse) {
        let worker = Task.detached(priority: .utility) { () async throws -> (Data, URLResponse) in
            let config = URLSessionConfiguration.ephemeral
            config.httpCookieStorage = nil; config.httpShouldSetCookies = false
            config.urlCredentialStorage = nil; config.urlCache = nil
            let session = URLSession(configuration: config, delegate: UserScriptRedirectPolicy(script: script, origin: origin), delegateQueue: nil)
            defer { session.invalidateAndCancel() }
            let (bytes, response) = try await session.bytes(for: request)
            guard response.expectedContentLength <= 24_000_000 else { throw URLError(.dataLengthExceedsMaximum) }
            let http = response as? HTTPURLResponse
            if let progress { await progress(Data(), http, 0) }
            var body = Data(), chunk = Data(), received = 0
            var reported = Date()
            for try await byte in bytes {
                received += 1
                guard received <= 24_000_000 else { throw URLError(.dataLengthExceedsMaximum) }
                if buffered { body.append(byte) }
                if progress != nil { chunk.append(byte) }
                if received % 16_384 == 0 {
                    try Task.checkCancellation()
                    if let progress, Date().timeIntervalSince(reported) >= 0.05 || chunk.count >= 65_536 {
                        await progress(chunk, http, received); chunk.removeAll(keepingCapacity: true); reported = Date()
                    }
                }
            }
            try Task.checkCancellation()
            if let progress, !chunk.isEmpty { await progress(chunk, http, received) }
            return (body, response)
        }
        return try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
    }
}
