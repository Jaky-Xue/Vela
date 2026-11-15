import Foundation

enum FilterIncludeResolver {
    /// Resolve before publication; a failed/cyclic child leaves the active snapshot untouched.
    static func expand(_ text: String, base: URL, fetch: (URL) async throws -> String) async throws -> (String, Bool) {
        var total = 0, files = 0, expanded = false
        func visit(_ body: String, url: URL, path: Set<String>, depth: Int) async throws -> String {
            guard depth <= 4, files < 24, !path.contains(url.absoluteString), body.utf8.count <= FilterValidation.sourceByteLimit else { throw FilterError.invalid("include 循环、深度或来源大小超限") }
            files += 1; total += body.utf8.count
            guard total <= FilterValidation.combinedByteLimit else { throw FilterError.invalid("include 合计超过 8 MB") }
            let lower = body.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard !lower.hasPrefix("<!doctype"), !lower.hasPrefix("<html"), !lower.contains("<body") else { throw FilterError.invalid("include 返回 HTML") }
            var output: [String] = [], chain = path
            chain.insert(url.absoluteString)
            for (lineIndex, line) in body.components(separatedBy: .newlines).enumerated() {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if trimmed.hasPrefix("!#include ") {
                    expanded = true
                    let raw = String(trimmed.dropFirst(10)).trimmingCharacters(in: .whitespaces)
                    guard let child = URL(string: raw, relativeTo: url)?.absoluteURL,
                          child.scheme == "https", child.host != nil, child.user == nil, child.password == nil,
                          child.fragment == nil else { throw FilterError.invalid("include 需要 HTTPS 地址") }
                    let content = try await fetch(child)
                    output.append("! Source: " + child.absoluteString)
                    output.append(try await visit(content, url: child, path: chain, depth: depth + 1))
                    output.append("! Source: " + url.absoluteString)
                    output.append("! Line: " + String(lineIndex + 2))
                } else if trimmed.hasPrefix("!#include") { throw FilterError.invalid("include 指令无效") }
                else { output.append(line) }
            }
            return output.joined(separator: "\n")
        }
        let result = try await visit(text, url: base, path: [], depth: 0)
        return (result, expanded)
    }
}

final class FilterHTTPSRedirectPolicy: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        guard let url = request.url, url.scheme == "https", url.user == nil, url.password == nil else { completionHandler(nil); return }
        completionHandler(request)
    }
}
