//
//  UserScriptParser.swift
//  Vela
//
//  Parses a user-script metadata block into a `UserScriptPackageCandidate`.
//
//  A script is metadata-block driven: everything before the closing marker is
//  `// @key value`, everything after is the body that runs on the page. The
//  parser is deliberately permissive about unknown `@keys` — a script written
//  for a manager with extensions should still install — and strict about the two
//  things that make a script unrunnable: a missing `@name`, and a metadata block
//  with neither `@match` nor `@include`.
//

import Foundation

public enum UserScriptParser {
    private static let blockStart = "==UserScript=="
    private static let blockEnd = "==/UserScript=="

    /// Parses a whole script document.
    ///
    /// - Parameter installSource: recorded on the candidate so the installer
    ///   knows whether the source came from the clipboard, a URL or a file.
    /// - Parameter sourceUrl: the URL the script was fetched from, when there
    ///   was one. Recorded so `@updateURL` can be inferred later.
    public static func parse(
        _ text: String,
        installSource: UserScriptPackageSource = .paste,
        sourceUrl: String = ""
    ) -> UserScriptMetadataParseResult {
        var warnings: [String] = []

        guard let startRange = text.range(of: blockStart) else {
            return .failure("找不到用户脚本元数据块（需要 // ==UserScript== … // ==/UserScript== ）。")
        }
        guard let endRange = text.range(of: blockEnd, range: startRange.upperBound..<text.endIndex) else {
            return .failure("用户脚本元数据块没有闭合，缺少 // ==/UserScript== 。")
        }

        let metadataText = String(text[startRange.upperBound..<endRange.lowerBound])

        var candidate = UserScriptPackageCandidate()
        candidate.installSource = installSource
        candidate.sourceUrl = sourceUrl

        var sawName = false
        var sawPattern = false

        for rawLine in metadataText.split(whereSeparator: \.isNewline) {
            // Strip the comment leader and the trailing whitespace.
            var line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("//") {
                line = String(line.dropFirst(2)).trimmingCharacters(in: .whitespaces)
            } else if line.hasPrefix("#") {
                line = String(line.dropFirst(1)).trimmingCharacters(in: .whitespaces)
            } else if line.isEmpty || line.hasPrefix("/*") || line.hasPrefix("*") || line.hasPrefix("*/") {
                // Tolerate a block-comment style metadata header. Some scripts
                // wrap the block in /* */ for no reason other than habit.
                line = line.replacingOccurrences(of: "/*", with: "")
                    .replacingOccurrences(of: "*/", with: "")
                    .trimmingCharacters(in: .whitespaces)
            }
            guard line.hasPrefix("@") else { continue }

            let body = String(line.dropFirst())
            let (key, value) = splitKeyValue(body)
            guard !key.isEmpty else { continue }

            switch key.lowercased() {
            case "name":
                candidate.name = value
                sawName = !value.isEmpty
            case "namespace":
                candidate.namespace = value
            case "version":
                candidate.version = value
            case "description":
                candidate.description = value
            case "icon", "iconurl", "icon-url":
                candidate.iconUrl = value
            case "match":
                if !value.isEmpty { candidate.matches.append(value); sawPattern = true }
            case "include":
                if !value.isEmpty { candidate.includes.append(value); sawPattern = true }
            case "exclude":
                if !value.isEmpty { candidate.excludes.append(value) }
            case "excludematch", "exclude_match", "exclude-match":
                if !value.isEmpty { candidate.excludeMatches.append(value) }
            case "grant":
                if !value.isEmpty { candidate.grants.append(UserScriptGrant(token: value)) }
            case "require":
                if !value.isEmpty { candidate.requireUrls.append(value) }
            case "resource":
                if let declaration = parseResource(value) {
                    candidate.resourceDeclarations.append(declaration)
                } else {
                    warnings.append("@resource 声明无法解析，已跳过：\(value)")
                }
            case "connect":
                if !value.isEmpty { candidate.connectRules.append(value) }
            case "run-at":
                if let runAt = UserScriptRunAt(rawValue: value.lowercased()) {
                    candidate.runAt = runAt
                } else {
                    warnings.append("未知的 @run-at 取值「\(value)」，将使用 document-idle。")
                }
            case "noframes":
                // A bare `@noframes` has no value; a value of "false" means off.
                candidate.noframes = value.lowercased() != "false"
            case "updateurl":
                candidate.updateUrl = value
            case "downloadurl":
                candidate.downloadUrl = value
            case "homepage", "homepageurl", "website", "source":
                warnings.append("@\(key) 已忽略：该字段在 iOS 上没有对应能力。")
            default:
                // Unknown keys are tolerated silently; a warning per unknown key
                // would bury the real problems in a long block.
                break
            }
        }

        // The body is everything after the closing marker.
        candidate.source = String(text[endRange.upperBound...])
            .trimmingCharacters(in: .whitespacesAndNewlines)

        if !sawName {
            return .failure("用户脚本缺少 @name，无法安装。", warnings: warnings)
        }
        if !sawPattern {
            return .failure("用户脚本没有 @match 或 @include，无法确定在哪些网站运行。", warnings: warnings)
        }
        if candidate.source.isEmpty {
            return .failure("用户脚本没有可执行的代码。", warnings: warnings)
        }
        if candidate.grants.isEmpty {
            warnings.append("脚本没有声明 @grant，将按无特权脚本执行。")
            candidate.grants = [.none]
        }

        return UserScriptMetadataParseResult(
            valid: true,
            candidate: candidate,
            warnings: warnings,
            errorMessage: ""
        )
    }

    /// Splits `key value` on the first run of whitespace.
    private static func splitKeyValue(_ body: String) -> (key: String, value: String) {
        guard let separatorIndex = body.firstIndex(where: { $0.isWhitespace }) else {
            return (body, "")
        }
        let key = String(body[body.startIndex..<separatorIndex])
        let value = String(body[separatorIndex...]).trimmingCharacters(in: .whitespaces)
        return (key, value)
    }

    /// Parses `@resource name url`.
    private static func parseResource(_ value: String) -> UserScriptResourceDeclaration? {
        let parts = value.split(separator: " ", maxSplits: 1).map(String.init)
        guard parts.count == 2 else { return nil }
        let name = parts[0].trimmingCharacters(in: .whitespaces)
        let url = parts[1].trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty, !url.isEmpty else { return nil }
        return UserScriptResourceDeclaration(name: name, url: url)
    }
}
