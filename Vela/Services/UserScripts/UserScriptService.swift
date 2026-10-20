//
//  UserScriptService.swift
//  Vela
//
//  Installing, editing and updating user scripts, including the dependencies
//  a Tampermonkey-compatible script declares.
//
//  `@require` and `@resource` are resolved here rather than at injection time:
//  a script's dependencies are part of the script as installed, so the page
//  injection stays synchronous at document start. An update re-downloads them
//  only when the declarations changed, unless the user asks for a refresh.
//

import Foundation
import Observation

public enum UserScriptServiceError: LocalizedError {
    case parseFailed(String)
    case writeFailed(String)

    public var errorDescription: String? {
        switch self {
        case let .parseFailed(message): return message
        case let .writeFailed(message): return "保存失败：\(message)"
        }
    }
}

public enum UserScriptEditResult: Sendable {
    case saved(warnings: [String])
    case invalid(message: String, warnings: [String])
}

@MainActor
@Observable
public final class UserScriptService {
    public private(set) var scripts: [InstalledUserScriptState] = []
    public private(set) var isInstalling = false
    public private(set) var isCheckingUpdates = false
    /// Per-script last result, shown in the list and the detail screen.
    public private(set) var updateStatus: [String: String] = [:]
    public private(set) var lastError: String?

    public let repository: UserScriptRepository
    private let settings: SettingsService

    public init(repository: UserScriptRepository, settings: SettingsService) {
        self.repository = repository
        self.settings = settings
        reload()
    }

    // MARK: - Reading

    public func reload() {
        scripts = (try? repository.allScripts()) ?? []
    }

    public func script(id: String) -> InstalledUserScriptState? {
        scripts.first { $0.id == id } ?? (try? repository.script(id: id))
    }

    public func setEnabled(_ enabled: Bool, id: String) {
        try? repository.setEnabled(enabled, id: id)
        reload()
    }

    public func delete(id: String) {
        try? repository.remove(id: id)
        updateStatus.removeValue(forKey: id)
        reload()
    }

    // MARK: - Install and edit

    public func install(
        text: String,
        source: UserScriptPackageSource,
        sourceUrl: String,
        replacingId: String? = nil
    ) async -> Result<UserScriptInstallOutcome, Error> {
        isInstalling = true
        defer { isInstalling = false }
        lastError = nil

        // A URL install may point at a metadata-only update file; follow its
        // @downloadURL/@updateURL when the body is absent.
        let installText = source == .url && !sourceUrl.isEmpty
            ? await fullScriptText(text, baseURL: sourceUrl)
            : text
        let parse = UserScriptParser.parse(installText, installSource: source, sourceUrl: sourceUrl)
        guard parse.valid, let candidate = parse.candidate else {
            let failure = UserScriptServiceError.parseFailed(parse.errorMessage)
            lastError = failure.localizedDescription
            return .failure(failure)
        }

        // Identity is name plus namespace, the userscript metadata convention.
        // A reinstall of the same script updates it rather than stacking a
        // second copy.
        let existing: InstalledUserScriptState?
        if let replacingId {
            existing = self.script(id: replacingId)
        } else {
            existing = scripts.first {
                $0.name == candidate.name && $0.namespace == candidate.namespace
            }
        }

        var resolved = candidate
        let fallbackUrl = source == .url ? sourceUrl : ""
        if resolved.updateUrl.isEmpty {
            resolved.updateUrl = existing?.updateUrl.isEmpty == false
                ? existing!.updateUrl
                : fallbackUrl
        }
        if resolved.downloadUrl.isEmpty {
            resolved.downloadUrl = existing?.downloadUrl.isEmpty == false
                ? existing!.downloadUrl
                : fallbackUrl
        }

        var warnings = parse.warnings
        let dependencies = await resolveDependencies(for: resolved, reusing: existing)
        warnings.append(contentsOf: dependencies.warnings)

        var script = InstalledUserScriptState(candidate: resolved)
        script.resourceDeclarations = resolved.resourceDeclarations
        script.requireSources = dependencies.requireSources
        script.resources = dependencies.resources
        if let existing {
            script.id = existing.id
            script.createdAt = existing.createdAt
            script.enabled = existing.enabled
            script.lastCheckedAt = existing.lastCheckedAt
            if script.updateUrl.isEmpty { script.updateUrl = existing.updateUrl }
            if script.downloadUrl.isEmpty { script.downloadUrl = existing.downloadUrl }
        }
        script.updatedAt = Date()

        do {
            try repository.upsert(script)
        } catch {
            let failure = UserScriptServiceError.writeFailed(error.localizedDescription)
            lastError = failure.localizedDescription
            return .failure(failure)
        }
        reload()
        return .success(UserScriptInstallOutcome(script: script, warnings: warnings))
    }

    /// Saves an edited script, re-parsing its metadata block.
    ///
    /// A body-only edit keeps working; a changed metadata block updates the
    /// matches and grants too, which is what a user who pasted a modified script
    /// expects. Dependencies are re-downloaded only when their declarations
    /// changed.
    public func saveEditedSource(
        _ text: String,
        for script: InstalledUserScriptState
    ) async -> UserScriptEditResult {
        let parse = UserScriptParser.parse(
            text,
            installSource: script.installSource.packageSource,
            sourceUrl: script.sourceUrl
        )
        guard parse.valid else {
            return .invalid(message: parse.errorMessage, warnings: parse.warnings)
        }
        let result = await install(
            text: text,
            source: script.installSource.packageSource,
            sourceUrl: script.sourceUrl,
            replacingId: script.id
        )
        switch result {
        case let .success(outcome):
            return .saved(warnings: outcome.warnings)
        case let .failure(error):
            return .invalid(message: error.localizedDescription, warnings: parse.warnings)
        }
    }

    /// The script text the editor shows.
    ///
    /// The stored `source` is only the executable body — everything after the
    /// `==/UserScript==` marker — because that is what the injector runs. An
    /// editor that started from it could never save: the metadata block is
    /// missing, so the re-parse rejected every edit as "not a user script".
    ///
    /// The block shown is the verbatim one the script was installed with
    /// (`metadataBlock`), so an unknown `@key` the parser does not capture is
    /// still on screen — a rebuilt block dropped those, which read as the
    /// source being cut off. Scripts installed before the field existed fall
    /// back to a reconstruction, and a raw save (where `source` already holds
    /// the whole text) is shown as-is.
    public func editableSource(for script: InstalledUserScriptState) -> String {
        let trimmed = script.source.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("// ==UserScript==") || trimmed.hasPrefix("==UserScript==") {
            return script.source
        }
        if !script.metadataBlock.isEmpty {
            return script.metadataBlock + "\n\n" + script.source
        }
        return Self.reconstructedSource(for: script)
    }

    /// Rebuilds a metadata block around a body that was stored without one.
    static func reconstructedSource(for script: InstalledUserScriptState) -> String {
        func line(_ key: String, _ value: String) -> String? {
            let single = value
                .replacingOccurrences(of: "\r", with: " ")
                .replacingOccurrences(of: "\n", with: " ")
                .trimmingCharacters(in: .whitespaces)
            return single.isEmpty ? nil : "// @\(key) \(single)"
        }

        var lines: [String] = ["// ==UserScript=="]
        lines.append(contentsOf: [
            line("name", script.name),
            line("namespace", script.namespace),
            line("version", script.version),
            line("description", script.description),
            line("icon", script.iconUrl)
        ].compactMap { $0 })
        for pattern in script.matches { lines.append(contentsOf: line("match", pattern).map { [$0] } ?? []) }
        for pattern in script.includes { lines.append(contentsOf: line("include", pattern).map { [$0] } ?? []) }
        for pattern in script.excludes { lines.append(contentsOf: line("exclude", pattern).map { [$0] } ?? []) }
        for pattern in script.excludeMatches { lines.append(contentsOf: line("exclude-match", pattern).map { [$0] } ?? []) }
        if !(script.grants.count == 1 && script.grants.first == UserScriptGrant.none) {
            for grant in script.grants { lines.append(contentsOf: line("grant", grant.rawValue).map { [$0] } ?? []) }
        }
        for url in script.requireUrls { lines.append(contentsOf: line("require", url).map { [$0] } ?? []) }
        for declaration in script.resourceDeclarations {
            lines.append(contentsOf: line("resource", "\(declaration.name) \(declaration.url)").map { [$0] } ?? [])
        }
        for rule in script.connectRules { lines.append(contentsOf: line("connect", rule).map { [$0] } ?? []) }
        lines.append("// @run-at \(script.runAt.rawValue)")
        if script.noframes { lines.append("// @noframes") }
        lines.append(contentsOf: [
            line("downloadURL", script.downloadUrl),
            line("updateURL", script.updateUrl)
        ].compactMap { $0 })
        lines.append("// ==/UserScript==")
        lines.append("")
        lines.append(script.source)
        return lines.joined(separator: "\n")
    }

    /// Saves the text without parsing it.
    ///
    /// Offered when an edit is mid-flight and the metadata block is temporarily
    /// broken: losing the body would be worse than keeping the old metadata.
    public func saveRawSource(_ text: String, for script: InstalledUserScriptState) throws {
        var updated = script
        updated.source = text
        updated.updatedAt = Date()
        try repository.upsert(updated)
        reload()
    }

    // MARK: - Dependencies

    /// Downloads `@require` and `@resource` again, keeping the old copy when a
    /// download fails. Returns the non-fatal problems for the detail screen.
    @discardableResult
    public func refreshDependencies(for script: InstalledUserScriptState) async -> [String] {
        let previousSources = dictionary(
            keys: script.requireUrls,
            values: script.requireSources
        )
        let previousResources = dictionary(
            keys: script.resources.map { Self.resourceKey($0) },
            values: script.resources
        )
        let dependencies = await downloadDependencies(
            requireUrls: script.requireUrls,
            resourceDeclarations: script.resourceDeclarations,
            base: URL(string: script.sourceUrl),
            previousSources: previousSources,
            previousResources: previousResources
        )

        var updated = script
        updated.requireSources = dependencies.requireSources
        updated.resources = dependencies.resources
        updated.updatedAt = Date()
        try? repository.upsert(updated)
        reload()
        return dependencies.warnings
    }

    private func resolveDependencies(
        for candidate: UserScriptPackageCandidate,
        reusing existing: InstalledUserScriptState?
    ) async -> (requireSources: [String], resources: [UserScriptResourceRecord], warnings: [String]) {
        let base = URL(string: candidate.sourceUrl)

        let declarationsChanged = (existing?.requireUrls ?? []) != candidate.requireUrls
            || (existing?.resourceDeclarations ?? []) != candidate.resourceDeclarations
        if let existing, !declarationsChanged,
           existing.requireSources.count == existing.requireUrls.count,
           existing.resources.count == existing.resourceDeclarations.count {
            return (existing.requireSources, existing.resources, [])
        }

        let previousSources = dictionary(
            keys: existing?.requireUrls ?? [],
            values: existing?.requireSources ?? []
        )
        let previousResources = dictionary(
            keys: (existing?.resources ?? []).map { Self.resourceKey($0) },
            values: existing?.resources ?? []
        )
        return await downloadDependencies(
            requireUrls: candidate.requireUrls,
            resourceDeclarations: candidate.resourceDeclarations,
            base: base,
            previousSources: previousSources,
            previousResources: previousResources
        )
    }

    private func downloadDependencies(
        requireUrls: [String],
        resourceDeclarations: [UserScriptResourceDeclaration],
        base: URL?,
        previousSources: [String: String],
        previousResources: [String: UserScriptResourceRecord]
    ) async -> (requireSources: [String], resources: [UserScriptResourceRecord], warnings: [String]) {
        var sources: [String] = []
        var resources: [UserScriptResourceRecord] = []
        var warnings: [String] = []
        var totalBytes = 0
        let perItemLimit = 4_000_000
        let totalLimit = 16_000_000

        for rawURL in requireUrls {
            guard totalBytes < totalLimit else {
                warnings.append("@require 总量超过上限，其余依赖未下载。")
                break
            }
            if let fetched = await fetch(rawURL, base: base, limit: perItemLimit),
               let text = Self.decodeText(fetched.data) {
                sources.append(text)
                totalBytes += fetched.data.count
            } else if let previous = previousSources[rawURL] {
                sources.append(previous)
                warnings.append("无法重新下载 @require，沿用上次保存的副本：\(rawURL)")
            } else {
                warnings.append("无法下载 @require：\(rawURL)")
            }
        }

        for declaration in resourceDeclarations {
            guard totalBytes < totalLimit else {
                warnings.append("@resource 总量超过上限，其余资源未下载。")
                break
            }
            let key = Self.resourceKey(declaration)
            if let fetched = await fetch(declaration.url, base: base, limit: perItemLimit) {
                totalBytes += fetched.data.count
                let mime = fetched.mimeType
                if Self.isTextMime(mime) || Self.hasTextExtension(declaration.url),
                   let text = Self.decodeText(fetched.data) {
                    resources.append(
                        UserScriptResourceRecord(
                            name: declaration.name,
                            url: declaration.url,
                            text: text,
                            mimeType: mime
                        )
                    )
                } else {
                    resources.append(
                        UserScriptResourceRecord(
                            name: declaration.name,
                            url: declaration.url,
                            mimeType: mime.isEmpty ? "application/octet-stream" : mime,
                            contentBase64: fetched.data.base64EncodedString()
                        )
                    )
                }
            } else if let previous = previousResources[key] {
                resources.append(previous)
                warnings.append("无法重新下载 @resource，沿用上次保存的副本：\(declaration.name)")
            } else {
                warnings.append("无法下载 @resource：\(declaration.name)")
            }
        }

        return (sources, resources, warnings)
    }

    private struct Fetched {
        var data: Data
        var mimeType: String
    }

    /// Follows a metadata-only update file to the script it points at.
    private func fullScriptText(_ text: String, baseURL: String) async -> String {
        let parse = UserScriptParser.parse(
            text,
            installSource: .url,
            sourceUrl: baseURL
        )
        guard !parse.valid, parse.errorMessage.contains("没有可执行") else { return text }
        guard let relative = Self.metadataValue(in: text, key: "downloadurl")
                ?? Self.metadataValue(in: text, key: "updateurl"),
              let resolved = URL(string: relative, relativeTo: URL(string: baseURL))?.absoluteString,
              let fetched = await fetch(resolved, base: nil, limit: 8_000_000),
              let script = Self.decodeText(fetched.data) else {
            return text
        }
        return script
    }

    /// Reads one `@key value` from a metadata block without requiring the
    /// whole document to parse.
    private static func metadataValue(in text: String, key: String) -> String? {
        let wanted = "@" + key.lowercased()
        for rawLine in text.split(whereSeparator: \.isNewline) {
            var line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("//") {
                line = String(line.dropFirst(2)).trimmingCharacters(in: .whitespaces)
            } else if line.hasPrefix("#") {
                line = String(line.dropFirst(1)).trimmingCharacters(in: .whitespaces)
            }
            let lower = line.lowercased()
            guard lower.hasPrefix(wanted) else { continue }
            let remainder = line.dropFirst(wanted.count)
            let value = remainder.trimmingCharacters(in: .whitespaces)
            if !value.isEmpty { return value }
        }
        return nil
    }

    private func fetch(_ raw: String, base: URL?, limit: Int) async -> Fetched? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        if trimmed.lowercased().hasPrefix("data:") {
            guard let decoded = Self.decodeDataURI(trimmed), decoded.data.count <= limit else {
                return nil
            }
            return Fetched(data: decoded.data, mimeType: decoded.mimeType)
        }

        guard let url = URL(string: trimmed, relativeTo: base)?.absoluteURL,
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https" else {
            return nil
        }

        var request = URLRequest(url: url)
        request.timeoutInterval = 20
        request.setValue("*/*", forHTTPHeaderField: "Accept")
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            if let http = response as? HTTPURLResponse,
               !(200...299).contains(http.statusCode) {
                return nil
            }
            guard data.count <= limit else { return nil }
            let mime = (response.mimeType ?? httpContentType(response) ?? "text/plain").lowercased()
            return Fetched(data: data, mimeType: mime)
        } catch {
            return nil
        }
    }

    private func httpContentType(_ response: URLResponse) -> String? {
        (response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Content-Type")
    }

    // MARK: - Updates

    /// Checks one script's update URL and applies a newer version.
    public func checkForUpdate(_ script: InstalledUserScriptState) async -> UserScriptUpdateResult {
        let candidates = [script.updateUrl, script.downloadUrl, script.sourceUrl]
        guard let rawURL = candidates.first(where: { value in
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, let url = URL(string: trimmed) else { return false }
            return url.scheme == "http" || url.scheme == "https"
        }) else {
            let result = UserScriptUpdateResult.noUpdateUrl
            updateStatus[script.id] = result.displayName
            return result
        }

        guard let fetched = await fetch(rawURL, base: URL(string: script.sourceUrl), limit: 8_000_000),
              let downloaded = Self.decodeText(fetched.data) else {
            let result = UserScriptUpdateResult.failed("无法下载脚本")
            updateStatus[script.id] = result.displayName
            return result
        }

        let text = await fullScriptText(downloaded, baseURL: rawURL)
        let parse = UserScriptParser.parse(text, installSource: .url, sourceUrl: rawURL)
        guard parse.valid, let candidate = parse.candidate else {
            let result = UserScriptUpdateResult.failed(parse.errorMessage)
            updateStatus[script.id] = result.displayName
            return result
        }

        let newer = Self.isNewer(candidate.version, than: script.version)
            || (candidate.version.isEmpty && script.version.isEmpty && candidate.source != script.source)

        try? repository.setLastChecked(id: script.id)

        if newer {
            var resolved = candidate
            if resolved.updateUrl.isEmpty { resolved.updateUrl = script.updateUrl }
            if resolved.downloadUrl.isEmpty { resolved.downloadUrl = script.downloadUrl }
            if resolved.sourceUrl.isEmpty { resolved.sourceUrl = rawURL }

            let dependencies = await resolveDependencies(for: resolved, reusing: script)
            var updated = InstalledUserScriptState(candidate: resolved)
            updated.id = script.id
            updated.createdAt = script.createdAt
            updated.enabled = script.enabled
            updated.lastCheckedAt = Date()
            updated.resourceDeclarations = resolved.resourceDeclarations
            updated.requireSources = dependencies.requireSources
            updated.resources = dependencies.resources
            updated.updatedAt = Date()
            try? repository.upsert(updated)
            reload()
            let result = UserScriptUpdateResult.updated(from: script.version, to: candidate.version)
            updateStatus[script.id] = result.displayName
            return result
        }

        // Even when the script itself is current, a missing dependency can be
        // repaired here — that is what makes an older install work with the
        // @require support added later.
        if script.requireSources.count != script.requireUrls.count
            || script.resources.count != script.resourceDeclarations.count {
            _ = await refreshDependencies(for: script)
        }
        reload()

        let result = UserScriptUpdateResult.upToDate
        updateStatus[script.id] = result.displayName
        return result
    }

    /// Checks every installed script, one at a time, and returns the results.
    @discardableResult
    public func checkAllUpdates() async -> [String: UserScriptUpdateResult] {
        guard !isCheckingUpdates else { return [:] }
        isCheckingUpdates = true
        defer { isCheckingUpdates = false }

        var results: [String: UserScriptUpdateResult] = [:]
        for script in scripts {
            results[script.id] = await checkForUpdate(script)
        }
        return results
    }

    /// Runs a check at launch when the user opted in, skipping scripts checked
    /// in the last day so a busy collection does not hit the network every time
    /// the app opens.
    public func autoUpdateIfNeeded() async {
        guard settings.userScriptSettings.autoUpdateEnabled else { return }
        let cutoff = Date().addingTimeInterval(-24 * 60 * 60)
        let stale = scripts.filter { script in
            guard let checked = script.lastCheckedAt else { return true }
            return checked < cutoff
        }
        guard !stale.isEmpty else { return }
        for script in stale {
            _ = await checkForUpdate(script)
        }
    }

    // MARK: - Version comparison

    /// Whether `remote` is a later version than `local`.
    ///
    /// Versions are compared token by token, so `1.10` is newer than `1.9`
    /// (which a string comparison gets wrong) and `2.0.1` is newer than `2.0`.
    /// Non-numeric tokens compare lexically; a missing token counts as zero.
    public static func isNewer(_ remote: String, than local: String) -> Bool {
        let remoteTokens = versionTokens(remote)
        let localTokens = versionTokens(local)
        guard !remoteTokens.isEmpty || !localTokens.isEmpty else { return false }
        guard !remoteTokens.isEmpty else { return false }
        guard !localTokens.isEmpty else { return true }

        let count = max(remoteTokens.count, localTokens.count)
        for index in 0..<count {
            let lhs = index < remoteTokens.count ? remoteTokens[index] : "0"
            let rhs = index < localTokens.count ? localTokens[index] : "0"
            if lhs == rhs { continue }
            if let left = Int(lhs), let right = Int(rhs) {
                return left > right
            }
            if Int(lhs) != nil { return true }
            if Int(rhs) != nil { return false }
            return lhs > rhs
        }
        return false
    }

    private static func versionTokens(_ value: String) -> [String] {
        value.lowercased()
            .split { !$0.isLetter && !$0.isNumber }
            .map(String.init)
            .filter { !$0.isEmpty }
    }

    // MARK: - Decoding helpers

    private func dictionary<Key: Hashable, Value>(keys: [Key], values: [Value]) -> [Key: Value] {
        var result: [Key: Value] = [:]
        for (key, value) in zip(keys, values) {
            result[key] = value
        }
        return result
    }

    private static func resourceKey(_ resource: UserScriptResourceRecord) -> String {
        "\(resource.name)|\(resource.url)"
    }

    private static func resourceKey(_ declaration: UserScriptResourceDeclaration) -> String {
        "\(declaration.name)|\(declaration.url)"
    }

    private static func hasTextExtension(_ raw: String) -> Bool {
        let path = URL(string: raw)?.path.lowercased() ?? raw.lowercased()
        let extensions = [".js", ".mjs", ".css", ".json", ".txt", ".html", ".htm", ".xml", ".svg", ".md", ".csv"]
        return extensions.contains { path.hasSuffix($0) }
    }

    private static func isTextMime(_ mime: String) -> Bool {
        let value = mime.lowercased()
        return value.hasPrefix("text/")
            || value.contains("javascript")
            || value.contains("ecmascript")
            || value.contains("json")
            || value.contains("xml")
            || value.contains("css")
            || value.contains("x-www-form-urlencoded")
    }

    private static func decodeText(_ data: Data) -> String? {
        String(data: data, encoding: .utf8)
            ?? String(data: data, encoding: .utf16)
            ?? String(data: data, encoding: .isoLatin1)
    }

    private static func decodeDataURI(_ raw: String) -> (mimeType: String, data: Data)? {
        guard let comma = raw.firstIndex(of: ",") else { return nil }
        let metadata = String(raw[raw.index(raw.startIndex, offsetBy: 5)..<comma])
        let payload = String(raw[raw.index(after: comma)...])
        let parts = metadata.split(separator: ";", omittingEmptySubsequences: false)
        let mime = parts.first.map(String.init) ?? "text/plain"
        let isBase64 = parts.dropFirst().contains { $0.lowercased() == "base64" }
        if isBase64 {
            guard let data = Data(base64Encoded: payload) else { return nil }
            return (mime.isEmpty ? "text/plain" : mime, data)
        }
        guard let decoded = payload.removingPercentEncoding,
              let data = decoded.data(using: .utf8) else { return nil }
        return (mime.isEmpty ? "text/plain" : mime, data)
    }
}
