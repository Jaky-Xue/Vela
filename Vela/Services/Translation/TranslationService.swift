//
//  TranslationService.swift
//  Vela
//
//  Turns a loaded page into translated text without reloading it.
//
//  The three steps are deliberately separate: `WebPageScripts.textExtractionScript`
//  walks the document and returns the segments it indexed, this service sends
//  those segments to a provider in batches, and `textApplicationScript` writes
//  the answers back into the same text nodes. Nothing here parses HTML, because
//  the document is already the parsed form and re-serialising it would lose the
//  page's own layout and event handlers.
//
//  The originals are kept on each text node by the extraction script, which is
//  what makes 显示原文 a restore rather than a reload — the user does not lose
//  their scroll position to undo a translation.
//

import Foundation
import WebKit
import Observation

@MainActor
@Observable
public final class TranslationService {
    public enum Phase: Equatable, Sendable {
        case idle
        case extracting
        case translating(done: Int, total: Int)
        case finished(segments: Int)
        case failed(String)
    }

    public private(set) var phase: Phase = .idle
    /// The language the page was most recently translated into, or nil when no
    /// translation is applied.
    public private(set) var appliedTarget: TranslationTargetLanguage?
    /// The page URL the current translation belongs to. A tab switch or a
    /// navigation makes the applied translation stale, and the sheet uses this
    /// to avoid offering 显示原文 for a document it did not touch.
    public private(set) var appliedUrl: String?

    public init() {}

    public var isBusy: Bool {
        switch phase {
        case .extracting, .translating: return true
        case .idle, .finished, .failed: return false
        }
    }

    public var isTranslated: Bool {
        if case .finished = phase { return appliedTarget != nil }
        return false
    }

    public var progress: Double {
        switch phase {
        case let .translating(done, total):
            guard total > 0 else { return 0 }
            return min(1, max(0, Double(done) / Double(total)))
        case .finished:
            return 1
        case .extracting:
            return 0
        case .idle, .failed:
            return 0
        }
    }

    public var statusText: String {
        switch phase {
        case .idle:
            return "尚未翻译"
        case .extracting:
            return "正在读取页面正文…"
        case let .translating(done, total):
            return "正在翻译 \(done)/\(total) 段…"
        case let .finished(segments):
            return "已翻译 \(segments) 段"
        case let .failed(message):
            return message
        }
    }

    // MARK: - Translation

    /// Translates the document in `webView` in place.
    ///
    /// A translation already applied to this document is restored first, so
    /// changing the target language re-extracts the original text rather than
    /// translating a translation.
    public func translate(
        webView: WKWebView,
        settings: TranslationSettings,
        target: TranslationTargetLanguage
    ) async {
        guard settings.isUsable else {
            phase = .failed(TranslationError.notConfigured.localizedDescription)
            return
        }
        // Two batches writing into the same text nodes would interleave their
        // results; a second tap while the first run is going is ignored.
        guard !isBusy else { return }

        phase = .extracting
        appliedTarget = nil
        appliedUrl = nil

        // Undo a previous translation on this document. The script is a no-op
        // when nothing has been applied.
        _ = try? await webView.evaluateJavaScript(WebPageScripts.textRestoreScript)

        let extractionJSON: String
        do {
            let raw = try await webView.evaluateJavaScript(WebPageScripts.textExtractionScript)
            guard let value = raw as? String else {
                phase = .failed(TranslationError.scriptUnavailable.localizedDescription)
                return
            }
            extractionJSON = value
        } catch {
            phase = .failed(error.localizedDescription)
            return
        }

        guard let data = extractionJSON.data(using: .utf8),
              let extraction = try? JSONDecoder().decode(Extraction.self, from: data) else {
            phase = .failed(TranslationError.badResponse(extractionJSON).localizedDescription)
            return
        }

        let segments = extraction.segments.filter { !$0.text.isEmpty }
        guard !segments.isEmpty else {
            phase = .failed(TranslationError.noSegments.localizedDescription)
            return
        }

        // Define the writer before the first batch, so a long page starts
        // showing translations as they arrive rather than after every batch
        // has been paid for.
        do {
            _ = try await webView.evaluateJavaScript(WebPageScripts.textApplicationScript)
        } catch {
            phase = .failed(TranslationError.scriptUnavailable.localizedDescription)
            return
        }

        let sourceUrl = extraction.url
        let total = segments.count
        var applied = 0
        phase = .translating(done: 0, total: total)

        do {
            for batch in makeBatches(segments, settings: settings) {
                try Task.checkCancellation()
                let texts = batch.map(\.text)
                let translations = try await requestTranslations(
                    texts,
                    settings: settings,
                    target: target
                )
                guard translations.count == batch.count else {
                    throw TranslationError.alignment
                }
                try await apply(
                    zip(batch, translations).map { (index: $0.0.index, text: $0.1) },
                    to: webView
                )
                applied += batch.count
                phase = .translating(done: applied, total: total)
            }
        } catch is CancellationError {
            phase = .failed("翻译已取消。")
            return
        } catch {
            let message = error.localizedDescription
            if applied > 0 {
                phase = .failed("已写入 \(applied)/\(total) 段后停止：\(message)")
            } else {
                phase = .failed(message)
            }
            return
        }

        appliedTarget = target
        appliedUrl = sourceUrl
        phase = .finished(segments: applied)
    }

    /// Puts the document's own text back.
    public func restoreOriginal(webView: WKWebView) async {
        _ = try? await webView.evaluateJavaScript(WebPageScripts.textRestoreScript)
        appliedTarget = nil
        appliedUrl = nil
        phase = .idle
    }

    /// Forgets the last result without touching a page. Called when the shell
    /// moves to a different tab.
    public func reset() {
        phase = .idle
        appliedTarget = nil
        appliedUrl = nil
    }

    // MARK: - Document bridge

    private struct Extraction: Decodable {
        struct Segment: Decodable {
            let index: Int
            let text: String
            let tag: String
        }

        let segments: [Segment]
        let url: String
        let title: String
    }

    private func makeBatches(
        _ segments: [Extraction.Segment],
        settings: TranslationSettings
    ) -> [[Extraction.Segment]] {
        var batches: [[Extraction.Segment]] = []
        var current: [Extraction.Segment] = []
        var characters = 0

        for segment in segments {
            let cost = segment.text.count + 1
            if !current.isEmpty,
               characters + cost > settings.provider.batchCharacterLimit
                   || current.count >= settings.provider.batchItemLimit {
                batches.append(current)
                current = []
                characters = 0
            }
            current.append(segment)
            characters += cost
        }
        if !current.isEmpty { batches.append(current) }
        return batches
    }

    private func apply(_ pairs: [(index: Int, text: String)], to webView: WKWebView) async throws {
        let payload = pairs.map { ["index": $0.index, "text": $0.text] as [String: Any] }
        let data = try JSONSerialization.data(withJSONObject: ["segments": payload])
        guard var literal = String(data: data, encoding: .utf8) else {
            throw TranslationError.badResponse("无法编码译文")
        }
        // JSON is almost valid JavaScript; these two line separators are the
        // exception, so they are escaped before the literal is embedded.
        literal = literal
            .replacingOccurrences(of: "\u{2028}", with: "\\u2028")
            .replacingOccurrences(of: "\u{2029}", with: "\\u2029")
        _ = try await webView.evaluateJavaScript("window.__velaApplyTranslation(\(literal));")
    }

    // MARK: - Providers

    private func requestTranslations(
        _ texts: [String],
        settings: TranslationSettings,
        target: TranslationTargetLanguage
    ) async throws -> [String] {
        guard !texts.isEmpty else { return [] }
        switch settings.provider {
        case .google:
            return try await google(texts, settings: settings, target: target)
        case .deepL:
            return try await deepL(texts, settings: settings, target: target)
        case .openAICompatible:
            return try await openAI(texts, settings: settings, target: target)
        }
    }

    private func google(
        _ texts: [String],
        settings: TranslationSettings,
        target: TranslationTargetLanguage
    ) async throws -> [String] {
        guard let url = googleUrl(settings: settings, target: target, text: texts.joined(separator: "\n")) else {
            throw TranslationError.failed("翻译接口地址无效。")
        }
        let data = try await send(URLRequest(url: url))
        let joined = try parseGoogle(data)

        // The endpoint returns sentences, not the lines that were sent. When a
        // line became several sentences — or two lines became one — the batch
        // cannot be aligned, so each segment is asked for on its own. That is
        // slower but it is the only way to put the right text in the right
        // node.
        let lines = joined.components(separatedBy: "\n")
        if lines.count == texts.count {
            return lines
        }

        var results: [String] = []
        for text in texts {
            try Task.checkCancellation()
            guard let single = googleUrl(settings: settings, target: target, text: text) else {
                throw TranslationError.failed("翻译接口地址无效。")
            }
            let singleData = try await send(URLRequest(url: single))
            results.append(try parseGoogle(singleData))
        }
        return results
    }

    private func googleUrl(
        settings: TranslationSettings,
        target: TranslationTargetLanguage,
        text: String
    ) -> URL? {
        guard var components = URLComponents(string: settings.resolvedEndpoint) else { return nil }
        var items = components.queryItems ?? []
        items.append(URLQueryItem(name: "client", value: "gtx"))
        items.append(URLQueryItem(name: "sl", value: "auto"))
        items.append(URLQueryItem(name: "tl", value: target.googleCode))
        items.append(URLQueryItem(name: "dt", value: "t"))
        items.append(URLQueryItem(name: "q", value: text))
        components.queryItems = items
        return components.url
    }

    private func parseGoogle(_ data: Data) throws -> String {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [Any],
              let sentences = root.first as? [Any] else {
            throw TranslationError.badResponse(String(data: data.prefix(240), encoding: .utf8) ?? "")
        }
        let pieces: [String] = sentences.compactMap { entry in
            guard let sentence = entry as? [Any], let text = sentence.first as? String else { return nil }
            return text
        }
        let joined = pieces.joined()
        guard !joined.isEmpty else {
            throw TranslationError.badResponse(String(data: data.prefix(240), encoding: .utf8) ?? "")
        }
        return joined
    }

    private func deepL(
        _ texts: [String],
        settings: TranslationSettings,
        target: TranslationTargetLanguage
    ) async throws -> [String] {
        guard let url = URL(string: settings.resolvedEndpoint) else {
            throw TranslationError.failed("翻译接口地址无效。")
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("DeepL-Auth-Key \(settings.apiKey.trimmingCharacters(in: .whitespacesAndNewlines))",
                         forHTTPHeaderField: "Authorization")
        request.setValue("application/x-www-form-urlencoded; charset=utf-8",
                         forHTTPHeaderField: "Content-Type")

        var fields = texts.map { "text=\(formEncode($0))" }
        fields.append("target_lang=\(target.deepLCode)")
        request.httpBody = fields.joined(separator: "&").data(using: .utf8)

        let data = try await send(request)
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let translations = root["translations"] as? [[String: Any]] else {
            throw TranslationError.badResponse(String(data: data.prefix(240), encoding: .utf8) ?? "")
        }
        let values = translations.compactMap { $0["text"] as? String }
        guard values.count == texts.count else { throw TranslationError.alignment }
        return values
    }

    private func openAI(
        _ texts: [String],
        settings: TranslationSettings,
        target: TranslationTargetLanguage
    ) async throws -> [String] {
        var endpoint = settings.resolvedEndpoint
        if !endpoint.hasSuffix("/chat/completions") {
            endpoint = endpoint.trimmingCharacters(in: CharacterSet(charactersIn: "/")) + "/chat/completions"
        }
        guard let url = URL(string: endpoint) else {
            throw TranslationError.failed("翻译接口地址无效。")
        }

        let system = """
        You are a translation engine inside a web browser. Translate every \
        string in the JSON array the user sends into \(target.naturalName). The \
        strings are text fragments of one web page in reading order: translate \
        each fragment on its own, keep its tone, and do not merge, split, \
        summarise or annotate them. Return only a JSON array of strings with \
        exactly the same number of elements, in the same order.
        """
        let input = try JSONSerialization.data(
            withJSONObject: texts,
            options: [.fragmentsAllowed]
        )
        let inputText = String(data: input, encoding: .utf8) ?? "[]"

        let body: [String: Any] = [
            "model": settings.resolvedModel,
            "temperature": 0,
            "messages": [
                ["role": "system", "content": system],
                ["role": "user", "content": inputText]
            ]
        ]

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(settings.apiKey.trimmingCharacters(in: .whitespacesAndNewlines))",
                         forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let data = try await send(request)
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = root["choices"] as? [[String: Any]],
              let message = choices.first?["message"] as? [String: Any],
              let content = message["content"] as? String else {
            throw TranslationError.badResponse(String(data: data.prefix(240), encoding: .utf8) ?? "")
        }

        let json = stripCodeFence(content)
        guard let jsonData = json.data(using: .utf8),
              let values = try? JSONDecoder().decode([String].self, from: jsonData) else {
            throw TranslationError.badResponse(String(content.prefix(240)))
        }
        guard values.count == texts.count else { throw TranslationError.alignment }
        return values
    }

    /// Sends a request and turns a non-2xx answer into an error whose message
    /// names the status. `URLSession` itself treats 4xx/5xx as a successful
    /// transfer, so without this a rejected key would arrive as a decode error.
    private func send(_ request: URLRequest) async throws -> Data {
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw TranslationError.failed(error.localizedDescription)
        }
        if let http = response as? HTTPURLResponse,
           !(200...299).contains(http.statusCode) {
            throw TranslationError.http(http.statusCode)
        }
        return data
    }

    private func formEncode(_ value: String) -> String {
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "&+=?#")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? ""
    }

    private func stripCodeFence(_ raw: String) -> String {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.hasPrefix("```") else { return text }
        if let firstNewline = text.firstIndex(of: "\n") {
            text = String(text[text.index(after: firstNewline)...])
        }
        if text.hasSuffix("```") {
            text = String(text.dropLast(3))
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
