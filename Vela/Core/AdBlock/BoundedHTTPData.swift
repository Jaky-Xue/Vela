import Foundation

enum BoundedHTTPData {
    /// Receive off the UI actor and enforce the ceiling while bytes arrive.
    static func load(_ request: URLRequest, limit: Int, session: URLSession) async throws -> (Data, URLResponse) {
        let worker = Task.detached(priority: .utility) { () async throws -> (Data, URLResponse) in
            let (bytes, response) = try await session.bytes(for: request)
            guard response.expectedContentLength <= limit else { throw URLError(.dataLengthExceedsMaximum) }
            var data = Data()
            for try await byte in bytes {
                guard data.count < limit else { throw URLError(.dataLengthExceedsMaximum) }
                data.append(byte)
                if data.count % 65_536 == 0 { try Task.checkCancellation() }
            }
            return (data, response)
        }
        return try await withTaskCancellationHandler {
            try await worker.value
        } onCancel: { worker.cancel() }
    }
}
