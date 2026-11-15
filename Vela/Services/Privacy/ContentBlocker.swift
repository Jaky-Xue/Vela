import Foundation
import WebKit
import Observation
import CryptoKit

@MainActor @Observable
public final class ContentBlocker {
    public static let identifier = "org.vela.browser.content-blocker.builtin"
    public private(set) var isReady = false
    public private(set) var isCompiling = false
    public private(set) var ruleCount = 0
    public private(set) var hiddenRuleCount = 0
    public private(set) var skippedRuleCount = 0
    public private(set) var lastError: String?
    public private(set) var loadedAt: Date?
    public var onChange: (() -> Void)?
    private let settings: SettingsService
    private let store: WKContentRuleListStore
    private let cacheDirectory: URL
    private let session: URLSession
    private var compiledList: WKContentRuleList?
    private var hasRestoredCache = false

    public init(settings: SettingsService, store: WKContentRuleListStore? = nil,
                cacheDirectory: URL? = nil, session: URLSession? = nil) {
        self.settings = settings
        self.store = store ?? WKContentRuleListStore.default()
        self.cacheDirectory = cacheDirectory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Vela/Filters", isDirectory: true)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        self.session = session ?? URLSession(configuration: configuration)
    }

    public func ruleList(forHost host: String?) -> WKContentRuleList? {
        guard settings.contentBlocker.enabled, let compiledList else { return nil }
        if let host, settings.contentBlocker.isExcepted(host: host) { return nil }
        return compiledList
    }

    public func prepare() {
        guard !isCompiling else { return }
        isCompiling = true
        Task { [weak self] in
            guard let self else { return }
            _ = await self.publish(self.settings.contentBlocker)
            self.isCompiling = false
            let stale = (self.settings.contentBlocker.subscriptions ?? []).contains {
                $0.enabled && ($0.lastSuccess.map { Date().timeIntervalSince($0) > 86_400 } ?? true)
            }
            if stale { await self.refreshSubscriptions() }
        }
    }

    /// Navigation can await this before its first request, including cold start.
    public func waitUntilPrepared() async {
        if !isReady && !isCompiling { prepare() }
        while isCompiling && !isReady {
            if Task.isCancelled { return }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
    }

    public func setBuiltIn(_ id: String, enabled: Bool) async {
        guard !isCompiling else { return }
        var candidate = settings.contentBlocker
        var disabled = Set(candidate.disabledBuiltIns ?? [])
        if enabled { disabled.remove(id) } else { disabled.insert(id) }
        candidate.disabledBuiltIns = Array(disabled).sorted()
        await change(candidate)
    }

    @discardableResult public func saveCustomRules(_ text: String) async -> Bool {
        guard !isCompiling else { return false }
        do {
            if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                try FilterValidation.validate(text, limit: 256_000)
            }
            var candidate = settings.contentBlocker
            candidate.customRules = text
            return await change(candidate)
        } catch { lastError = error.localizedDescription; return false }
    }

    public func addSubscription(name: String, url raw: String) async -> Bool {
        guard !isCompiling else { return false }
        guard let url = URL(string: raw.trimmingCharacters(in: .whitespacesAndNewlines)),
              url.scheme == "https", url.host != nil, url.user == nil, url.password == nil else {
            lastError = "订阅需要有效的 HTTPS 地址"; return false
        }
        guard (settings.contentBlocker.subscriptions ?? []).count < 12,
              !(settings.contentBlocker.subscriptions ?? []).contains(where: { $0.url == url.absoluteString }) else {
            lastError = "来源已存在或已达到 12 个来源上限"; return false
        }
        isCompiling = true
        defer { isCompiling = false }
        do {
            let source = FilterSubscription(name: name.isEmpty ? (url.host ?? "订阅") : name, url: url.absoluteString)
            let downloaded = try await download(source)
            var candidate = settings.contentBlocker
            candidate.subscriptions = (candidate.subscriptions ?? []) + [downloaded]
            return await publish(candidate)
        } catch { lastError = error.localizedDescription; return false }
    }

    public func setSubscription(_ id: String, enabled: Bool) async {
        guard !isCompiling else { return }
        var candidate = settings.contentBlocker
        guard let index = candidate.subscriptions?.firstIndex(where: { $0.id == id }) else { return }
        candidate.subscriptions?[index].enabled = enabled
        await change(candidate)
    }

    public func removeSubscription(_ id: String) async {
        guard !isCompiling else { return }
        var candidate = settings.contentBlocker
        candidate.subscriptions?.removeAll { $0.id == id }
        await change(candidate)
    }

    public func refreshSubscriptions() async {
        guard !isCompiling else { return }
        isCompiling = true
        defer { isCompiling = false }
        var candidate = settings.contentBlocker
        var sources = candidate.subscriptions ?? []
        var failure: String?
        for index in sources.indices where sources[index].enabled {
            do { sources[index] = try await download(sources[index]) }
            catch { sources[index].error = error.localizedDescription; failure = error.localizedDescription }
        }
        // A failed source keeps its own cached version; good candidates can still publish.
        candidate.subscriptions = sources
        if await publish(candidate), let failure { lastError = "部分订阅更新失败，仍使用缓存：" + failure }
    }

    @discardableResult private func change(_ candidate: ContentBlockerSettings) async -> Bool {
        guard !isCompiling else { return false }
        isCompiling = true
        defer { isCompiling = false }
        return await publish(candidate)
    }

    private func download(_ original: FilterSubscription) async throws -> FilterSubscription {
        guard let url = URL(string: original.url), url.scheme == "https" else { throw FilterError.invalid("订阅地址无效") }
        var request = URLRequest(url: url)
        request.timeoutInterval = 30
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("text/plain", forHTTPHeaderField: "Accept")
        if let etag = original.etag { request.setValue(etag, forHTTPHeaderField: "If-None-Match") }
        if let modified = original.lastModified { request.setValue(modified, forHTTPHeaderField: "If-Modified-Since") }
        let (data, response) = try await BoundedHTTPData.load(request, limit: FilterValidation.sourceByteLimit, session: session)
        guard let http = response as? HTTPURLResponse, response.url?.scheme == "https" else { throw FilterError.invalid("订阅响应无效") }
        var source = original
        if http.statusCode == 304, let hash = source.cacheHash,
           FileManager.default.fileExists(atPath: cacheURL(hash).path) {
            source.lastSuccess = Date(); source.error = nil; return source
        }
        guard http.statusCode == 200, response.mimeType?.lowercased() != "text/html",
              response.expectedContentLength <= FilterValidation.sourceByteLimit else { throw FilterError.invalid("订阅状态、类型或大小不符合要求") }
        guard let text = String(data: data, encoding: .utf8) else { throw FilterError.invalid("订阅须为 UTF-8 文本") }
        try FilterValidation.validate(text)
        let hash = Self.hash(data)
        try FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
        try data.write(to: cacheURL(hash), options: .atomic)
        if source.cacheHash != hash { source.previousCacheHash = source.cacheHash }
        source.cacheHash = hash
        source.etag = http.value(forHTTPHeaderField: "ETag")
        source.lastModified = http.value(forHTTPHeaderField: "Last-Modified")
        source.lastSuccess = Date(); source.error = nil
        return source
    }

    private func cacheURL(_ hash: String) -> URL { cacheDirectory.appendingPathComponent(hash + ".txt") }
    private static func hash(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }

    private func restoreCache() async {
        guard !hasRestoredCache else { return }
        hasRestoredCache = true
        let snapshot = settings.contentBlocker.activeSnapshot
        let id = snapshot?.identifier ?? Self.identifier
        let list: WKContentRuleList? = await withCheckedContinuation { continuation in
            store.lookUpContentRuleList(forIdentifier: id) { list, _ in continuation.resume(returning: list) }
        }
        guard let list else { return }
        compiledList = list; isReady = true
        if let snapshot {
            ruleCount = snapshot.networkCount + snapshot.hiddenCount
            hiddenRuleCount = snapshot.hiddenCount; skippedRuleCount = snapshot.skippedCount
            loadedAt = snapshot.createdAt
        }
        onChange?()
    }

    private func publish(_ proposed: ContentBlockerSettings) async -> Bool {
        await restoreCache()
        do {
            let disabled = Set(proposed.disabledBuiltIns ?? [])
            var parts = AdBlockBuiltInRules.filterLists.sorted { $0.key < $1.key }
                .filter { !disabled.contains($0.key) }.map(\.value)
            for source in proposed.subscriptions ?? [] where source.enabled {
                guard let hash = source.cacheHash else { throw FilterError.invalid("订阅缺少缓存，请先更新") }
                parts.append(try String(contentsOf: cacheURL(hash), encoding: .utf8))
            }
            parts.append(proposed.customRules ?? "")
            let text = parts.joined(separator: "\n")
            guard text.utf8.count <= FilterValidation.combinedByteLimit else { throw FilterError.invalid("合并规则超过 8 MB 上限") }
            let compiled = await Task.detached(priority: .utility) {
                let result = AdBlockRuleCompiler.compile(filterList: text)
                return result
            }.value
            guard compiled.invalidRuleCount == 0, compiled.rules.count <= AdBlockCompileResult.webKitRuleLimit else {
                throw FilterError.invalid("规则无效或超过 WebKit 条数上限；上一版本已保留")
            }
            // WebKit requires a nonempty list even when the user disabled every source.
            let rules = compiled.rules.isEmpty ? [ContentBlockerRule(trigger: .init(urlFilter: ".*"), action: .ignorePreviousRules)] : compiled.rules
            try await CSSSelectorValidation.validate(rules.compactMap { $0.action.selector })
            let encoded = try AdBlockRuleCompiler.encode(rules)
            guard encoded.utf8.count < 45_000_000 else { throw FilterError.invalid("编译输出过大") }
            let id = Self.identifier + ".v2." + Self.hash(Data(encoded.utf8))
            let list: WKContentRuleList?
            if compiledList?.identifier == id { list = compiledList }
            else { list = try await store.compileContentRuleList(forIdentifier: id, encodedContentRuleList: encoded) }
            guard let list else { throw FilterError.invalid("WebKit 未返回有效规则") }
            let hidden = compiled.rules.filter { $0.action.type == "css-display-none" }.count
            let snapshot = FilterSnapshotInfo(identifier: id, networkCount: compiled.rules.count - hidden,
                hiddenCount: hidden, skippedCount: compiled.unsupportedRuleCount, createdAt: Date())
            // Only commit source configuration and metadata once WebKit accepted the candidate.
            var committed = proposed
            // Preserve independent switches edited while compilation was in flight.
            committed.enabled = settings.contentBlocker.enabled
            committed.whitelistedHosts = settings.contentBlocker.whitelistedHosts
            let old = settings.contentBlocker.activeSnapshot
            committed.previousSnapshot = old?.identifier == id ? settings.contentBlocker.previousSnapshot : old
            committed.activeSnapshot = snapshot
            settings.updateContentBlocker { $0 = committed }
            compiledList = list; isReady = true
            ruleCount = compiled.rules.count; hiddenRuleCount = hidden
            skippedRuleCount = snapshot.skippedCount; loadedAt = snapshot.createdAt
            lastError = nil; onChange?()
            pruneCaches()
            return true
        } catch {
            lastError = error.localizedDescription
            isReady = compiledList != nil
            return false
        }
    }

    private func pruneCaches() {
        let config = settings.contentBlocker
        let hashes = Set((config.subscriptions ?? []).flatMap { [$0.cacheHash, $0.previousCacheHash].compactMap { $0 } })
        for file in (try? FileManager.default.contentsOfDirectory(at: cacheDirectory, includingPropertiesForKeys: nil)) ?? [] {
            let hash = file.deletingPathExtension().lastPathComponent
            if file.pathExtension == "txt", hash.count == 64,
               hash.allSatisfy({ $0.isHexDigit }), !hashes.contains(hash) { try? FileManager.default.removeItem(at: file) }
        }
        let keep = Set([config.activeSnapshot?.identifier, config.previousSnapshot?.identifier].compactMap { $0 })
        store.getAvailableContentRuleListIdentifiers { [weak self] identifiers in
            Task { @MainActor [weak self] in
                guard let self else { return }
                let current = self.settings.contentBlocker
                let live = keep.union([current.activeSnapshot?.identifier, current.previousSnapshot?.identifier].compactMap { $0 })
                for id in identifiers ?? [] where id.hasPrefix(Self.identifier) && !live.contains(id) {
                    self.store.removeContentRuleList(forIdentifier: id) { _ in }
                }
            }
        }
    }

    public func noteSettingsChanged() { onChange?() }
}
