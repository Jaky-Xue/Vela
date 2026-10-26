//
//  SearchSuggestionClient.swift
//  Vela
//
//  The network half of 联网搜索推荐.
//
//  A suggestion endpoint is a property of the engine's own web service, not of
//  the search URL template a user can edit, so the table lives here rather than
//  on `SearchEngineRecord`. An engine with no entry simply offers local
//  suggestions: the feature degrades to the list it had before instead of
//  inventing a URL.
//
//  Everything here is best effort. A missing network, a captive portal, a
//  provider that has changed its shape, a rate limit — none of them is an error
//  the user needs to see while typing. `suggestions` answers `[]` on every one
//  of them, and the omnibox keeps the rows it can build locally.
//
//  The request carries the query, so it is only ever made for a regular tab and
//  only when the user has turned 联网搜索推荐 on; see
//  `OmniboxViewModel.startRemoteSuggestions`. This type deliberately has no
//  opinion about that policy — one owner for privacy, one owner for transport.
//

import CoreFoundation
import Foundation

// MARK: - Provider table

/// The engines whose suggestion endpoint this app knows about.
enum SearchSuggestionProvider: String, CaseIterable, Sendable {
    case bing
    case google
    case duckduckgo
    case baidu
    case qihoo
    case sogou
    case shenma
    case yandex

    init?(engineId: SearchEngineId) {
        self.init(rawValue: engineId)
    }

    /// The suggestion endpoint for a query, or nil when the engine's service
    /// has no endpoint this app knows.
    ///
    /// `URLComponents` does the percent-encoding, which is why the query is
    /// never concatenated into a template by hand.
    func url(for query: String) -> URL? {
        switch self {
        case .bing:
            return Self.makeURL(
                "https://www.bing.com/OSjson.aspx",
                items: [URLQueryItem(name: "query", value: query)]
            )
        case .google:
            return Self.makeURL(
                "https://suggestqueries.google.com/complete/search",
                items: [
                    URLQueryItem(name: "client", value: "firefox"),
                    URLQueryItem(name: "q", value: query)
                ]
            )
        case .duckduckgo:
            return Self.makeURL(
                "https://duckduckgo.com/ac/",
                items: [
                    URLQueryItem(name: "type", value: "list"),
                    URLQueryItem(name: "q", value: query)
                ]
            )
        case .baidu:
            // `json=1` is the variant that answers with quoted keys; the
            // default response is a JavaScript call with bare keys, which no
            // JSON reader can take.
            return Self.makeURL(
                "https://suggestion.baidu.com/su",
                items: [
                    URLQueryItem(name: "json", value: "1"),
                    URLQueryItem(name: "wd", value: query)
                ]
            )
        case .qihoo:
            return Self.makeURL(
                "https://sug.so.360.cn/suggest",
                items: [URLQueryItem(name: "word", value: query)]
            )
        case .sogou:
            return Self.makeURL(
                "https://sor.html5.qq.com/api/getsug",
                items: [URLQueryItem(name: "key", value: query)]
            )
        case .shenma:
            return Self.makeURL(
                "https://sugs.m.sm.cn/web",
                items: [
                    URLQueryItem(name: "t", value: "w"),
                    URLQueryItem(name: "q", value: query)
                ]
            )
        case .yandex:
            return Self.makeURL(
                "https://suggest.yandex.com/suggest-ff.cgi",
                items: [URLQueryItem(name: "part", value: query)]
            )
        }
    }

    private static func makeURL(_ base: String, items: [URLQueryItem]) -> URL? {
        guard var components = URLComponents(string: base) else { return nil }
        components.queryItems = (components.queryItems ?? []) + items
        return components.url
    }
}

// MARK: - Response parsing

/// Pulls suggestion strings out of the provider shapes this app supports.
///
/// Four shapes cover the table: a bare JSON pair whose second element is the
/// list (Bing, Google, DuckDuckGo with `type=list`, Yandex, Sogou's callback),
/// Baidu's object with an `s` array, 360's object with `result[].word`, and the
/// phrase-object array DuckDuckGo returns without `type=list`. A first `[` or
/// `{` and last `]` or `}` bracket the JSON in a callback response, which is
/// how the JSONP-shaped answers are read without a JavaScript parser.
enum SearchSuggestionParser {
    static func parse(data: Data, charset: String?) -> [String] {
        guard let text = decode(data, charset: charset) else { return [] }
        guard let root = jsonObject(from: text) else { return [] }
        return candidates(from: root)
    }

    /// Trims, de-duplicates, drops the query itself and caps the list.
    ///
    /// The typed query already has its own row, so returning it again would
    /// put two identical lines in the search section.
    static func sanitize(_ raw: [String], query: String, limit: Int = 8) -> [String] {
        let normalizedQuery = query
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        var seen = Set<String>()
        var result: [String] = []

        for candidate in raw {
            let value = candidate
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .replacingOccurrences(of: "\n", with: " ")
            guard !value.isEmpty, value.count <= 120 else { continue }
            let key = value.lowercased()
            guard key != normalizedQuery, seen.insert(key).inserted else { continue }
            result.append(value)
            if result.count >= limit { break }
        }
        return result
    }

    private static func decode(_ data: Data, charset: String?) -> String? {
        if let charset, let encoding = encoding(named: charset) {
            if let text = String(data: data, encoding: encoding) { return text }
            // A provider that names GBK may still answer with a byte the
            // narrower codec rejects; GB18030 is its superset.
            if charset.lowercased().hasPrefix("gb"),
               let fallback = encoding(named: "GB18030"),
               let text = String(data: data, encoding: fallback) {
                return text
            }
        }
        return String(data: data, encoding: .utf8)
    }

    /// Baidu and Sogou answer in GBK; the response names it, and following the
    /// name is what keeps a Chinese suggestion from arriving as mojibake.
    private static func encoding(named name: String) -> String.Encoding? {
        let cfEncoding = CFStringConvertIANACharSetNameToEncoding(name as CFString)
        guard cfEncoding != kCFStringEncodingInvalidId else { return nil }
        let encoding = CFStringConvertEncodingToNSStringEncoding(cfEncoding)
        return String.Encoding(rawValue: encoding)
    }

    private static func jsonObject(from text: String) -> Any? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let start = trimmed.firstIndex(where: { $0 == "[" || $0 == "{" }),
              let end = trimmed.lastIndex(where: { $0 == "]" || $0 == "}" }),
              start < end else { return nil }
        let json = String(trimmed[start...end])
        guard let data = json.data(using: .utf8) else { return nil }
        return try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
    }

    private static func candidates(from root: Any) -> [String] {
        if let array = root as? [Any] {
            if array.count > 1, let list = array[1] as? [Any] {
                let words = list.compactMap { $0 as? String }
                if !words.isEmpty { return words }
            }
            // DuckDuckGo's object array: [{"phrase": "..."}]
            let phrases = array.compactMap { ($0 as? [String: Any])?["phrase"] as? String }
            if !phrases.isEmpty { return phrases }
            return array.compactMap { $0 as? String }
        }

        guard let object = root as? [String: Any] else { return [] }

        for key in ["s", "suggestions", "suggestion", "words"] {
            guard let list = object[key] as? [Any] else { continue }
            let words = list.compactMap { $0 as? String }
            if !words.isEmpty { return words }
            let phrases = list.compactMap { ($0 as? [String: Any])?["phrase"] as? String }
            if !phrases.isEmpty { return phrases }
        }

        for key in ["result", "data", "items"] {
            guard let list = object[key] as? [Any] else { continue }
            let words = list.compactMap { item -> String? in
                guard let entry = item as? [String: Any] else { return nil }
                return entry["word"] as? String
                    ?? entry["phrase"] as? String
                    ?? entry["value"] as? String
            }
            if !words.isEmpty { return words }
        }

        return []
    }
}

// MARK: - Client

@MainActor
protocol SearchSuggestionProviding {
    func suggestions(for query: String, engineId: SearchEngineId) async -> [String]
}

/// Fetches and caches one engine's suggestions for one query.
///
/// Main-actor isolated rather than an actor because the cache is small, the
/// caller is the omnibox's main-actor view model, and nothing else ever reads
/// it. The debounce lives in the view model; this type only enforces a minimum
/// spacing between requests so a fast typist cannot turn every keystroke into a
/// network call.
@MainActor
final class SearchSuggestionClient: SearchSuggestionProviding {
    private struct Cached {
        let words: [String]
        let createdAt: Date
    }

    private let session: URLSession
    private var cache: [String: Cached] = [:]
    private var lastRequestAt: Date?

    private static let cacheLifetime: TimeInterval = 5 * 60
    private static let minimumInterval: TimeInterval = 0.18
    private static let maximumResponseBytes = 256 * 1024

    /// A browser identifier, because several suggestion services answer a
    /// scripted client with an empty body or a challenge page.
    private static let userAgent = """
    Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1
    """

    init(session: URLSession? = nil) {
        self.session = session ?? Self.makeSession()
    }

    private static func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 1.6
        configuration.timeoutIntervalForResource = 2.2
        configuration.httpShouldSetCookies = false
        configuration.httpCookieAcceptPolicy = .never
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.waitsForConnectivity = false
        return URLSession(configuration: configuration)
    }

    func suggestions(for query: String, engineId: SearchEngineId) async -> [String] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let provider = SearchSuggestionProvider(engineId: engineId),
              let url = provider.url(for: trimmed) else { return [] }

        let key = "\(engineId)|\(trimmed.lowercased())"
        if let cached = cache[key],
           Date().timeIntervalSince(cached.createdAt) < Self.cacheLifetime {
            return cached.words
        }

        if let lastRequestAt {
            let elapsed = Date().timeIntervalSince(lastRequestAt)
            if elapsed < Self.minimumInterval {
                let remaining = Int((Self.minimumInterval - elapsed) * 1000)
                try? await Task.sleep(for: .milliseconds(remaining))
            }
        }
        guard !Task.isCancelled else { return [] }
        lastRequestAt = Date()

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 1.6
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("zh-CN,zh;q=0.9,en;q=0.8", forHTTPHeaderField: "Accept-Language")
        request.setValue(
            "application/json, text/javascript, */*; q=0.01",
            forHTTPHeaderField: "Accept"
        )

        do {
            let (data, response) = try await session.data(for: request)
            guard !Task.isCancelled else { return [] }
            guard let http = response as? HTTPURLResponse,
                  (200..<300).contains(http.statusCode),
                  data.count <= Self.maximumResponseBytes else { return [] }

            let words = SearchSuggestionParser.sanitize(
                SearchSuggestionParser.parse(data: data, charset: http.textEncodingName),
                query: trimmed
            )
            guard !words.isEmpty else { return [] }

            if cache.count > 128 { cache.removeAll(keepingCapacity: true) }
            cache[key] = Cached(words: words, createdAt: Date())
            return words
        } catch {
            // Offline, cancelled, timed out, provider gone. None of these is
            // something the omnibox should say out loud.
            return []
        }
    }
}
