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

    /// Enables or disables every installed script in one pass.
    ///
    /// A manager with a dozen scripts should not ask the user to tap a dozen
    /// switches to silence them for an afternoon. Scripts already in the
    /// requested state are skipped, so the write touches only what changed.
    public func setAllEnabled(_ enabled: Bool) {
        for script in scripts where script.enabled != enabled {
            try? repository.setEnabled(enabled, id: script.id)
        }
        reload()
    }

    /// Replaces a script's matching rules.
    ///
    /// The detail screen edits these directly instead of requiring a reinstall:
    /// a script that is right about everything except its `@match` line should
    /// not have to be re-fetched to be pointed at the site the user is on.
    /// Empty lines are dropped, and each list keeps declaration order.
    public func updateRules(
        matches: [String],
        includes: [String],
        excludes: [String] = [],
        excludeMatches: [String] = [],
        for script: InstalledUserScriptState
    ) throws {
        func cleaned(_ values: [String]) -> [String] {
            var seen = Set<String>()
            return values
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty && seen.insert($0).inserted }
        }

        var updated = script
        updated.matches = cleaned(matches)
        updated.includes = cleaned(includes)
        updated.excludes = cleaned(excludes)
        updated.excludeMatches = cleaned(excludeMatches)
        updated.updatedAt = Date()
        try repository.upsert(updated)
        reload()
    }

    public func delete(id: String) {
        try? repository.remove(id: id)
        updateStatus.removeValue(forKey: id)
        reload()
    }

    /// Points a script's update checks at a URL, or clears the override.
    ///
    /// A script installed from pasted code or a file can have `@updateURL`
    /// missing, or a declaration that has gone stale. Without a way to name the
    /// address, "检查更新" can only answer "没有更新地址" forever — which is not
    /// a check, it is a dead end.
    public func setUpdateURL(_ raw: String, for script: InstalledUserScriptState) throws {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            guard let url = URL(string: trimmed),
                  let scheme = url.scheme?.lowercased(),
                  scheme == "http" || scheme == "https" else {
                throw UserScriptServiceError.parseFailed("更新地址必须是 http 或 https 链接。")
            }
        }
        var updated = script
        updated.updateUrl = trimmed
        updated.updatedAt = Date()
        try repository.upsert(updated)
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

    /// Downloads and installs a script straight from a link.
    ///
    /// The `.user.js` install prompt uses this instead of fetching the file
    /// itself. The link is the source of truth: the service follows a
    /// metadata-only `.meta.js` to its `@downloadURL`, and the size ceiling
    /// here only guards against a link that serves a video or an archive
    /// rather than a script. A userscript with a large bundled payload is
    /// still a script and is not rejected for its size.
    public func installFromURL(_ url: URL) async -> Result<UserScriptInstallOutcome, Error> {
        guard let fetched = await fetch(url.absoluteString, base: nil, limit: 64_000_000),
              let text = Self.decodeText(fetched.data) else {
            let failure = UserScriptServiceError.parseFailed("无法从该链接下载脚本。")
            lastError = failure.localizedDescription
            return .failure(failure)
        }
        return await install(text: text, source: .url, sourceUrl: url.absoluteString)
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
              let fetched = await fetch(resolved, base: nil, limit: 64_000_000),
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
        // An update check that reads the URL cache is not a check: script
        // hosts cache their metadata and install endpoints aggressively, so a
        // stale entry makes every "check for updates" answer with the version
        // already installed.
        request.cachePolicy = .reloadIgnoringLocalCacheData
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

    /// Checks one script's update URLs and applies a newer version.
    ///
    /// The three URLs are tried in order rather than only the first one that
    /// exists. A script's `@updateURL` may serve a metadata-only file (the
    /// `.meta.js` convention), its `@downloadURL` may be the only live copy
    /// after a rename, and the install address may be a gallery page rather
    /// than the script itself. Stopping at the first URL turned any of those
    /// into "check failed" while another address could still have answered.
    public func checkForUpdate(_ script: InstalledUserScriptState) async -> UserScriptUpdateResult {
        let candidates = Self.updateCandidateURLs(for: script)
        guard !candidates.isEmpty else {
            markChecked(script)
            let result = UserScriptUpdateResult.noUpdateUrl
            updateStatus[script.id] = result.displayName
            return result
        }

        var failures: [String] = []
        var resolved: (candidate: UserScriptPackageCandidate, sourceURL: String)?

        for rawURL in candidates {
            guard let fetched = await fetch(rawURL, base: URL(string: script.sourceUrl), limit: 64_000_000),
                  let downloaded = Self.decodeText(fetched.data) else {
                failures.append("无法下载 \(rawURL)")
                continue
            }
            let text = await fullScriptText(downloaded, baseURL: rawURL)
            let parse = UserScriptParser.parse(text, installSource: .url, sourceUrl: rawURL)
            guard parse.valid, let candidate = parse.candidate else {
                failures.append("\(rawURL)：\(parse.errorMessage)")
                continue
            }
            resolved = (candidate, rawURL)
            break
        }

        guard let resolved else {
            markChecked(script)
            let result = UserScriptUpdateResult.failed(
                failures.first ?? "无法下载脚本"
            )
            updateStatus[script.id] = result.displayName
            return result
        }

        let candidate = resolved.candidate
        let newer = Self.isNewer(candidate.version, than: script.version)
            || (candidate.version.isEmpty && script.version.isEmpty && candidate.source != script.source)

        if newer {
            var updatedCandidate = candidate
            if updatedCandidate.updateUrl.isEmpty { updatedCandidate.updateUrl = script.updateUrl }
            if updatedCandidate.downloadUrl.isEmpty { updatedCandidate.downloadUrl = script.downloadUrl }
            if updatedCandidate.sourceUrl.isEmpty { updatedCandidate.sourceUrl = resolved.sourceURL }

            let dependencies = await resolveDependencies(for: updatedCandidate, reusing: script)
            var updated = InstalledUserScriptState(candidate: updatedCandidate)
            updated.id = script.id
            updated.createdAt = script.createdAt
            updated.enabled = script.enabled
            updated.installSource = script.installSource
            // An inferred update address should not replace the install
            // address the script was recorded with; only fill it when the
            // remote file does not name one.
            if updated.sourceUrl.isEmpty { updated.sourceUrl = script.sourceUrl }
            updated.lastCheckedAt = Date()
            updated.resourceDeclarations = updatedCandidate.resourceDeclarations
            updated.requireSources = dependencies.requireSources
            updated.resources = dependencies.resources
            updated.updatedAt = Date()

            do {
                try repository.upsert(updated)
            } catch {
                markChecked(script)
                let result = UserScriptUpdateResult.failed("保存更新失败：\(error.localizedDescription)")
                updateStatus[script.id] = result.displayName
                return result
            }
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
        markChecked(script)
        reload()

        let result = UserScriptUpdateResult.upToDate
        updateStatus[script.id] = result.displayName
        return result
    }

    /// The update addresses, in the order worth trying.
    ///
    /// A declared `@updateURL` is authoritative; a declared `@downloadURL` is
    /// the script itself; the install address is last because it is the one
    /// most likely to be a page. Duplicates are dropped so a script that
    /// declares its install URL as both endpoints is fetched once.
    static func updateCandidateURLs(for script: InstalledUserScriptState) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for raw in [script.updateUrl, script.downloadUrl, script.sourceUrl] {
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let url = URL(string: trimmed),
                  let scheme = url.scheme?.lowercased(),
                  scheme == "http" || scheme == "https",
                  seen.insert(trimmed).inserted else { continue }
            result.append(trimmed)
        }
        return result
    }

    /// Writes the check time through both the repository and the in-memory
    /// list. The detail screen reads the service's copy, so updating only the
    /// database left "最近检查" showing the previous attempt after a failure.
    private func markChecked(_ script: InstalledUserScriptState, at date: Date = Date()) {
        try? repository.setLastChecked(id: script.id, at: date)
        if let index = scripts.firstIndex(where: { $0.id == script.id }) {
            scripts[index].lastCheckedAt = date
        }
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
        var normalized = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        // `@version v1.2` and `@version 1.2` are the same version written two
        // ways; without dropping the prefix the first token is "v1" on one
        // side and "1" on the other, and the comparison reads the v-prefixed
        // side as older forever.
        if normalized.hasPrefix("v"), normalized.dropFirst().first?.isNumber == true {
            normalized = String(normalized.dropFirst())
        }
        return normalized
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
