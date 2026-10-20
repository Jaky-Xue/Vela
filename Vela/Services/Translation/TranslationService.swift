//
//  TranslationService.swift
//  Vela
//
//  Full-page translation with the shape Chrome gives it: recognise the page's
//  language, offer to translate, keep a bar on screen while it does, translate
//  paragraphs rather than loose text nodes, and keep translating content the
//  page adds later.
//
//  The document side lives in `WebPageScripts.translationSupportScript`. A
//  paragraph (a leaf block element) is the unit: its `innerHTML` goes to the
//  provider, so links, emphasis and inline markup survive the round trip, and
//  the writer puts the result back into the page's existing elements when the
//  translated markup still has the same shape. That last part is what keeps a
//  page's own event listeners alive — a whole-block `innerHTML` replacement
//  would recreate its links and buttons.
//

import Foundation
import NaturalLanguage
import Observation
import WebKit

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
    /// The URL the applied translation belongs to.
    public private(set) var appliedUrl: String?
    /// The page's language as far as recognition can tell. Drives the
    /// automatic offer; nil when the page is already in the target language
    /// or the sample was too short.
    public private(set) var detected: DetectedPageLanguage?
    public private(set) var detectedUrl: String?
    public private(set) var lastErrorMessage: String?

    /// A translation that is currently applied to a tab.
    ///
    /// Kept per tab so switching away and back restores the bar instead of
    /// pretending the newly translated page is untranslated. The web view is
    /// weak and identity-checked: a tab whose view the memory pool rebuilt is
    /// showing a fresh, untranslated document.
    private final class AppliedRecord {
        weak var webView: WKWebView?
        let target: TranslationTargetLanguage
        let url: String
        var segments: Int
        var detected: DetectedPageLanguage?

        init(
            webView: WKWebView,
            target: TranslationTargetLanguage,
            url: String,
            segments: Int,
            detected: DetectedPageLanguage?
        ) {
            self.webView = webView
            self.target = target
            self.url = url
            self.segments = segments
            self.detected = detected
        }
    }

    private var records: [String: AppliedRecord] = [:]
    private var syncedTabId = ""
    private var syncedUrl = ""
    /// Bumped whenever the page in front of the user changes. Work started for
    /// an older generation stops at its next boundary.
    private var generation = 0

    private struct DynamicWork {
        let payload: String
        let webView: WKWebView
        let target: TranslationTargetLanguage
        let generation: Int
    }

    private var dynamicWork: [DynamicWork] = []
    private var dynamicWorkerActive = false

    public init() {}

    // MARK: - Queries

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
            if let detected { return "此页面是\(detected.displayName)" }
            return "网页翻译"
        case .extracting:
            return "正在读取正文…"
        case let .translating(done, total):
            return "正在翻译 \(done)/\(total)…"
        case let .finished(segments):
            return "已翻译成\(appliedTarget?.displayName ?? "目标语言")（\(segments) 段）"
        case let .failed(message):
            return message
        }
    }

    /// The label the bar shows for the source language.
    public var detectedName: String? { detected?.displayName }

    // MARK: - Page lifecycle

    /// Points the service at the tab and document the user is looking at.
    ///
    /// Called when the active tab changes, its URL changes, and after a load
    /// finishes. It is what makes per-tab translation state possible without
    /// the view layer tracking any of it.
    public func sync(tabId: String, url: String, webView: WKWebView?) {
        if syncedTabId == tabId && syncedUrl == url {
            // The same page can get a new web view after the memory pool
            // discards and rebuilds it; the translation did not travel with it.
            if let record = records[tabId], record.webView !== webView {
                records.removeValue(forKey: tabId)
                phase = .idle
                appliedTarget = nil
                appliedUrl = nil
            }
            return
        }

        syncedTabId = tabId
        syncedUrl = url
        generation += 1
        dynamicWork.removeAll()
        lastErrorMessage = nil

        if let record = records[tabId], record.url == url, record.webView === webView {
            appliedTarget = record.target
            appliedUrl = record.url
            detected = record.detected
            detectedUrl = record.url
            phase = .finished(segments: record.segments)
        } else {
            if records[tabId] != nil {
                records.removeValue(forKey: tabId)
            }
            phase = .idle
            appliedTarget = nil
            appliedUrl = nil
            detected = nil
            detectedUrl = nil
        }
    }

    /// A new document is about to replace the page that was translated.
    ///
    /// A reload keeps the same tab and URL, so `sync` alone would keep showing
    /// the old translation's bar over an untranslated document. The navigation
    /// itself is the event that invalidates the record.
    public func pageWillNavigate(tabId: String) {
        records.removeValue(forKey: tabId)
        guard syncedTabId == tabId else { return }
        generation += 1
        dynamicWork.removeAll()
        lastErrorMessage = nil
        phase = .idle
        appliedTarget = nil
        appliedUrl = nil
        detected = nil
        detectedUrl = nil
    }

    /// Forgets everything. Used when the shell has no tab at all.
    public func reset() {
        generation += 1
        dynamicWork.removeAll()
        records.removeAll()
        syncedTabId = ""
        syncedUrl = ""
        phase = .idle
        appliedTarget = nil
        appliedUrl = nil
        detected = nil
        detectedUrl = nil
        lastErrorMessage = nil
    }

    // MARK: - Language detection

    /// Recognises the page's language from a short sample.
    ///
    /// This is the automatic offer: a page whose language differs from the
    /// target gets a bar that asks whether to translate it. Recognition is
    /// skipped once per URL so scrolling or a re-render does not repeat it.
    public func detectLanguage(in webView: WKWebView, target: TranslationTargetLanguage) async {
        guard !isTranslated, !isBusy else { return }

        let raw: Any?
        do {
            raw = try await webView.evaluateJavaScript(WebPageScripts.textSampleScript)
        } catch {
            return
        }
        guard let json = raw as? String,
              let data = json.data(using: .utf8),
              let sample = try? JSONDecoder().decode(Sample.self, from: data) else { return }

        if detectedUrl == sample.url { return }
        let previousTab = syncedTabId
        let previousUrl = syncedUrl

        let language = Self.recognize(sample.sample)
        guard syncedTabId == previousTab, syncedUrl == previousUrl else { return }

        detectedUrl = sample.url
        guard let language, language.confidence >= 0.3 else {
            detected = nil
            return
        }
        if TranslationTargetLanguage.baseCode(of: language.code)
            == TranslationTargetLanguage.baseCode(of: target.googleCode) {
            detected = nil
            return
        }
        detected = language
        if let record = records[syncedTabId] {
            record.detected = language
        }
    }

    // MARK: - Translating

    /// Translates the document in `webView` in place.
    public func translate(
        webView: WKWebView,
        settings: TranslationSettings,
        target: TranslationTargetLanguage
    ) async {
        guard settings.isUsable else {
            let message = TranslationError.notConfigured.localizedDescription
            lastErrorMessage = message
            phase = .failed(message)
            return
        }
        guard !isBusy else { return }

        let tabId = syncedTabId
        generation += 1
        let run = generation
        dynamicWork.removeAll()
        lastErrorMessage = nil
        phase = .extracting

        // Install the document-side helpers, then undo any translation that is
        // already applied. Re-translating must start from the page's own text,
        // not from the previous translation.
        _ = try? await webView.evaluateJavaScript(WebPageScripts.translationSupportScript)
        _ = try? await webView.evaluateJavaScript(WebPageScripts.textRestoreScript)
        guard run == generation else { return }

        let raw: Any?
        do {
            raw = try await webView.evaluateJavaScript(WebPageScripts.textExtractionScript)
        } catch {
            fail(run, error.localizedDescription)
            return
        }
        guard run == generation else { return }

        guard let json = raw as? String,
              let data = json.data(using: .utf8),
              let extraction = try? JSONDecoder().decode(Extraction.self, from: data) else {
            fail(run, TranslationError.scriptUnavailable.localizedDescription)
            return
        }

        let units = extraction.units.filter { !$0.html.isEmpty }
        guard !units.isEmpty else {
            fail(run, TranslationError.noSegments.localizedDescription)
            return
        }

        // The first extraction's sample is the best language evidence we have;
        // keep it even when the page was translated from the menu rather than
        // from an offer.
        if detected == nil, let language = Self.recognize(extraction.sample) {
            detected = language
            detectedUrl = extraction.url
        }

        let total = units.count
        var applied = 0
        phase = .translating(done: 0, total: total)

        do {
            for batch in makeBatches(units, settings: settings) {
                try Task.checkCancellation()
                guard run == generation else { return }

                let outcome = try await applyBatch(
                    batch,
                    settings: settings,
                    target: target,
                    to: webView
                )
                guard run == generation else { return }

                if let code = outcome.detectedLanguage {
                    updateDetected(code: code, target: target)
                }

                applied += outcome.applied
                if run == generation {
                    phase = .translating(done: applied, total: total)
                }
            }
        } catch is CancellationError {
            fail(run, "翻译已取消。")
            return
        } catch {
            let message = error.localizedDescription
            if applied > 0 {
                // Partial results are kept: a page that translated its first
                // half is more useful than one that reverted because a later
                // request failed.
                records[tabId] = AppliedRecord(
                    webView: webView,
                    target: target,
                    url: extraction.url,
                    segments: applied,
                    detected: detected
                )
                _ = try? await webView.evaluateJavaScript(
                    "window.__velaStartTranslationObserver && window.__velaStartTranslationObserver();"
                )
                appliedTarget = target
                appliedUrl = extraction.url
                fail(run, "已翻译 \(applied)/\(total) 段：\(message)")
            } else {
                fail(run, message)
            }
            return
        }

        _ = try? await webView.evaluateJavaScript(
            "window.__velaStartTranslationObserver && window.__velaStartTranslationObserver();"
        )

        if !tabId.isEmpty {
            records[tabId] = AppliedRecord(
                webView: webView,
                target: target,
                url: extraction.url,
                segments: applied,
                detected: detected
            )
        }

        guard run == generation else { return }
        appliedTarget = target
        appliedUrl = extraction.url
        phase = .finished(segments: applied)
    }

    /// Puts the document's own text back.
    public func restoreOriginal(webView: WKWebView) async {
        generation += 1
        dynamicWork.removeAll()
        _ = try? await webView.evaluateJavaScript(WebPageScripts.translationSupportScript)
        _ = try? await webView.evaluateJavaScript(WebPageScripts.textRestoreScript)
        if !syncedTabId.isEmpty {
            records.removeValue(forKey: syncedTabId)
        }
        appliedTarget = nil
        appliedUrl = nil
        lastErrorMessage = nil
        phase = .idle
    }

    // MARK: - Content added after the first pass

    /// Receives new blocks from the document's mutation observer.
    public func handleDynamicUnits(
        _ payload: String,
        tabId: String,
        webView: WKWebView,
        settings: TranslationSettings
    ) {
        guard let record = records[tabId], record.webView === webView else { return }
        dynamicWork.append(
            DynamicWork(
                payload: payload,
                webView: webView,
                target: record.target,
                generation: generation
            )
        )
        guard !dynamicWorkerActive else { return }
        dynamicWorkerActive = true

        Task { @MainActor [weak self] in
            guard let self else { return }
            while !self.dynamicWork.isEmpty {
                let item = self.dynamicWork.removeFirst()
                guard item.generation == self.generation else { continue }
                await self.translateDynamic(item, settings: settings)
            }
            self.dynamicWorkerActive = false
        }
    }

    private func translateDynamic(_ item: DynamicWork, settings: TranslationSettings) async {
        guard let data = item.payload.data(using: .utf8),
              let payload = try? JSONDecoder().decode(DynamicPayload.self, from: data),
              !payload.units.isEmpty else { return }

        do {
            for batch in makeBatches(payload.units, settings: settings) {
                guard item.generation == generation else { return }
                _ = try await applyBatch(
                    batch,
                    settings: settings,
                    target: item.target,
                    to: item.webView
                )
                guard item.generation == generation else { return }
            }
        } catch {
            // A feed that adds content while the network is flaky must not
            // replace the translated page with an error surface; the initial
            // translation is still on screen and still usable.
        }
    }

    // MARK: - Document bridge

    private struct Extraction: Decodable {
        struct Unit: Decodable {
            let id: Int
            let html: String
        }

        let units: [Unit]
        let sample: String
        let url: String
        let title: String
    }

    private struct DynamicPayload: Decodable {
        let units: [Extraction.Unit]
    }

    private struct Sample: Decodable {
        let sample: String
        let url: String
    }

    private func fail(_ run: Int, _ message: String) {
        guard run == generation else { return }
        lastErrorMessage = message
        phase = .failed(message)
    }

    private func makeBatches(
        _ units: [Extraction.Unit],
        settings: TranslationSettings
    ) -> [[Extraction.Unit]] {
        var batches: [[Extraction.Unit]] = []
        var current: [Extraction.Unit] = []
        var characters = 0

        for unit in units {
            let cost = unit.html.count + 40
            if !current.isEmpty,
               characters + cost > settings.provider.batchCharacterLimit
                   || current.count >= settings.provider.batchItemLimit {
                batches.append(current)
                current = []
                characters = 0
            }
            current.append(unit)
            characters += cost
        }
        if !current.isEmpty { batches.append(current) }
        return batches
    }

    /// Applies one batch and repairs any block the provider left out.
    ///
    /// Google normally returns every wrapper it was given, but a long page can
    /// lose one to a sentence split. A one-block request has nothing to lose,
    /// so the missing ids are retried that way rather than left untranslated.
    private func applyBatch(
        _ batch: [Extraction.Unit],
        settings: TranslationSettings,
        target: TranslationTargetLanguage,
        to webView: WKWebView
    ) async throws -> (applied: Int, detectedLanguage: String?) {
        let result = try await requestBatch(batch, settings: settings, target: target)
        var ids = try await apply(result.payload, to: webView)

        if Set(ids).count < batch.count {
            for unit in batch where !ids.contains(unit.id) {
                let single = try await requestBatch([unit], settings: settings, target: target)
                let singleIds = try await apply(single.payload, to: webView)
                ids.append(contentsOf: singleIds)
            }
        }

        let unique = Set(ids)
        guard !unique.isEmpty else {
            throw TranslationError.scriptUnavailable
        }
        return (unique.count, result.detectedLanguage)
    }

    private func apply(_ payload: BatchPayload, to webView: WKWebView) async throws -> [Int] {
        let script: String
        switch payload {
        case let .wrappedHTML(html):
            script = "window.__velaApplyTranslatedHTML(\(jsStringLiteral(html)));"
        case let .units(values):
            let items = values.map { ["id": $0.key, "html": $0.value] as [String: Any] }
            let data = try JSONSerialization.data(withJSONObject: ["units": items])
            let literal = String(data: data, encoding: .utf8) ?? "{\"units\":[]}"
            script = "window.__velaApplyTranslations(\(literal));"
        }

        let raw = try await webView.evaluateJavaScript(script)
        if let numbers = raw as? [NSNumber] {
            return numbers.map(\.intValue)
        }
        if let values = raw as? [Int] {
            return values
        }
        // WebKit normally bridges a JavaScript number array to NSNumber, but
        // the generic array path costs nothing and keeps a successful page
        // from being reported as a failed one if it does not.
        if let values = raw as? [Any] {
            return values.compactMap { value in
                (value as? NSNumber)?.intValue ?? (value as? Int)
            }
        }
        return []
    }

    private func jsStringLiteral(_ value: String) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: [value]),
              let array = String(data: data, encoding: .utf8), array.count >= 2 else {
            return "\"\""
        }
        return String(array.dropFirst().dropLast())
    }

    // MARK: - Providers

    private enum BatchPayload {
        case wrappedHTML(String)
        case units([Int: String])
    }

    private struct BatchResult {
        let payload: BatchPayload
        let detectedLanguage: String?
    }

    private func requestBatch(
        _ units: [Extraction.Unit],
        settings: TranslationSettings,
        target: TranslationTargetLanguage
    ) async throws -> BatchResult {
        switch settings.provider {
        case .google:
            // Google is given every block in the batch wrapped in its own
            // element. It preserves the tags and their data attributes, so the
            // response can be split back into the same block ids without the
            // host parsing HTML.
            let wrapped = units.map {
                "<div data-vela-unit=\"\($0.id)\">\($0.html)</div>"
            }.joined()
            let result = try await google(wrapped, settings: settings, target: target)
            return BatchResult(
                payload: .wrappedHTML(result.html),
                detectedLanguage: result.detectedLanguage
            )

        case .deepL:
            let values = try await deepL(units.map(\.html), settings: settings, target: target)
            guard values.count == units.count else { throw TranslationError.alignment }
            var map: [Int: String] = [:]
            for (unit, value) in zip(units, values) {
                map[unit.id] = value
            }
            return BatchResult(payload: .units(map), detectedLanguage: nil)

        case .openAICompatible:
            let values = try await openAI(units.map(\.html), settings: settings, target: target)
            guard values.count == units.count else { throw TranslationError.alignment }
            var map: [Int: String] = [:]
            for (unit, value) in zip(units, values) {
                map[unit.id] = value
            }
            return BatchResult(payload: .units(map), detectedLanguage: nil)
        }
    }

    private func google(
        _ wrappedHTML: String,
        settings: TranslationSettings,
        target: TranslationTargetLanguage
    ) async throws -> (html: String, detectedLanguage: String?) {
        guard var components = URLComponents(string: settings.resolvedEndpoint) else {
            throw TranslationError.failed("翻译接口地址无效。")
        }
        var items = components.queryItems ?? []
        items.append(URLQueryItem(name: "client", value: "gtx"))
        items.append(URLQueryItem(name: "sl", value: "auto"))
        items.append(URLQueryItem(name: "tl", value: target.googleCode))
        items.append(URLQueryItem(name: "dt", value: "t"))
        components.queryItems = items
        guard let url = components.url else {
            throw TranslationError.failed("翻译接口地址无效。")
        }

        // POST rather than GET: a page's blocks are far more text than a query
        // string can carry, and the public endpoint accepts the same form body.
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue(
            "application/x-www-form-urlencoded; charset=utf-8",
            forHTTPHeaderField: "Content-Type"
        )
        request.httpBody = "q=\(formEncode(wrappedHTML))".data(using: .utf8)

        let data = try await send(request)
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [Any],
              let sentences = root.first as? [Any] else {
            throw TranslationError.badResponse(String(data: data.prefix(240), encoding: .utf8) ?? "")
        }

        let html = sentences.compactMap { entry -> String? in
            guard let sentence = entry as? [Any], let text = sentence.first as? String else {
                return nil
            }
            return text
        }.joined()
        guard !html.isEmpty else {
            throw TranslationError.badResponse(String(data: data.prefix(240), encoding: .utf8) ?? "")
        }

        // The third element is the language the service decided the text was
        // written in. It is more reliable than a local sample for short or
        // mixed pages.
        let detected = root.count > 2 ? root[2] as? String : nil
        return (html, detected)
    }

    private func deepL(
        _ htmlUnits: [String],
        settings: TranslationSettings,
        target: TranslationTargetLanguage
    ) async throws -> [String] {
        guard let url = URL(string: settings.resolvedEndpoint) else {
            throw TranslationError.failed("翻译接口地址无效。")
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue(
            "DeepL-Auth-Key \(settings.apiKey.trimmingCharacters(in: .whitespacesAndNewlines))",
            forHTTPHeaderField: "Authorization"
        )
        request.setValue(
            "application/x-www-form-urlencoded; charset=utf-8",
            forHTTPHeaderField: "Content-Type"
        )

        var fields = htmlUnits.map { "text=\(formEncode($0))" }
        fields.append("target_lang=\(target.deepLCode)")
        // The units are HTML; without this DeepL treats tags as words.
        fields.append("tag_handling=html")
        request.httpBody = fields.joined(separator: "&").data(using: .utf8)

        let data = try await send(request)
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let translations = root["translations"] as? [[String: Any]] else {
            throw TranslationError.badResponse(String(data: data.prefix(240), encoding: .utf8) ?? "")
        }
        let values = translations.compactMap { $0["text"] as? String }
        guard values.count == htmlUnits.count else { throw TranslationError.alignment }
        return values
    }

    private func openAI(
        _ htmlUnits: [String],
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
        You are the translation engine inside a web browser. Translate every \
        HTML fragment in the JSON array the user sends into \(target.naturalName). \
        The fragments are paragraphs of one web page in reading order. Translate \
        each fragment on its own, keep its tone, and preserve every HTML tag, \
        attribute, link and inline element exactly as written. Do not add, \
        remove, merge or reorder fragments or tags, do not summarise, and do \
        not add commentary. Return only a JSON array of strings with exactly the \
        same number of elements, in the same order.
        """
        let input = try JSONSerialization.data(withJSONObject: htmlUnits)
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
        request.setValue(
            "Bearer \(settings.apiKey.trimmingCharacters(in: .whitespacesAndNewlines))",
            forHTTPHeaderField: "Authorization"
        )
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
        guard values.count == htmlUnits.count else { throw TranslationError.alignment }
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

    // MARK: - Recognition

    private static func recognize(_ text: String) -> DetectedPageLanguage? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 24 else { return nil }

        let recognizer = NLLanguageRecognizer()
        recognizer.processString(String(trimmed.prefix(1_200)))
        guard let language = recognizer.dominantLanguage else { return nil }
        let confidence = recognizer.languageHypotheses(withMaximum: 1)[language] ?? 0
        return DetectedPageLanguage(
            code: language.rawValue,
            displayName: displayName(forCode: language.rawValue),
            confidence: confidence
        )
    }

    private func updateDetected(code: String, target: TranslationTargetLanguage) {
        if TranslationTargetLanguage.baseCode(of: code)
            == TranslationTargetLanguage.baseCode(of: target.googleCode) {
            detected = nil
            return
        }
        detected = DetectedPageLanguage(
            code: code,
            displayName: Self.displayName(forCode: code),
            confidence: 1
        )
        if let record = records[syncedTabId] {
            record.detected = detected
        }
    }

    private static func displayName(forCode code: String) -> String {
        switch TranslationTargetLanguage.baseCode(of: code) {
        case "en": return "英语"
        case "ja": return "日语"
        case "ko": return "韩语"
        case "fr": return "法语"
        case "de": return "德语"
        case "es": return "西班牙语"
        case "ru": return "俄语"
        case "zh": return "中文"
        default:
            return Locale.current.localizedString(forLanguageCode: code) ?? code
        }
    }
}
