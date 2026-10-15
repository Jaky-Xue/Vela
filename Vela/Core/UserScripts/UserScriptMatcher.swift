//
//  UserScriptMatcher.swift
//  Vela
//
//  Decides whether a user script should run on a URL.
//
//  `@match` and `@include` are different grammars and both have to be honoured:
//  `@match` uses the strict Chrome extension pattern syntax, while `@include`
//  allows a loose glob people rely on, including a bare `*`. Treating the two as
//  one thing is the classic way a userscript manager silently stops matching the
//  scripts its users actually install.
//

import Foundation

public enum UserScriptMatcher {
    /// Decides whether `script` runs on `url`.
    public static func matches(_ script: InstalledUserScriptState, url: URL) -> Bool {
        guard script.enabled else { return false }
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else {
            return false
        }

        // Exclusions win over inclusions, in both grammars.
        if script.excludeMatches.contains(where: { matchPattern($0, matches: url) }) {
            return false
        }
        if script.excludes.contains(where: { includePattern($0, matches: url) }) {
            return false
        }

        let included = script.matches.contains { matchPattern($0, matches: url) }
            || script.includes.contains { includePattern($0, matches: url) }
        return included
    }

    /// Every enabled script that applies to `url`, in install order.
    public static func matchingScripts(
        in scripts: [InstalledUserScriptState],
        url: URL
    ) -> [InstalledUserScriptState] {
        scripts.filter { matches($0, url: url) }
            .sorted { lhs, rhs in
                if lhs.createdAt == rhs.createdAt { return lhs.id < rhs.id }
                return lhs.createdAt < rhs.createdAt
            }
    }

    /// Which scripts may run on a URL.
    ///
    /// Private browsing blocks user scripts outright: a script runs with page
    /// privileges and can read and modify everything on the page, which would
    /// defeat the session.
    public static func eligibility(
        scripts: [InstalledUserScriptState],
        url: URL,
        privacyMode: BrowserSessionPrivacyMode,
        userScriptsEnabled: Bool
    ) -> UserScriptRuntimeEligibility {
        guard userScriptsEnabled else {
            return UserScriptRuntimeEligibility(
                executionAllowed: false,
                blockReason: .disabled,
                matchingScripts: []
            )
        }
        guard privacyMode != .private else {
            return UserScriptRuntimeEligibility(
                executionAllowed: false,
                blockReason: .privateMode,
                matchingScripts: []
            )
        }
        let matching = matchingScripts(in: scripts, url: url)
        guard !matching.isEmpty else {
            return UserScriptRuntimeEligibility(
                executionAllowed: false,
                blockReason: .noMatch,
                matchingScripts: []
            )
        }
        return UserScriptRuntimeEligibility(
            executionAllowed: true,
            blockReason: .none,
            matchingScripts: matching
        )
    }

    // MARK: - Chrome match patterns

    /// `<scheme>://<host><path>`, where scheme may be `*`, host may be `*` or
    /// `*.example.com`, and path is a glob.
    static func matchPattern(_ pattern: String, matches url: URL) -> Bool {
        let trimmed = pattern.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return false }
        // `<all_urls>` is shorthand for every http/https URL.
        if trimmed == "<all_urls>" {
            return url.scheme == "http" || url.scheme == "https"
        }
        // A regex pattern is not part of the @match grammar; treat it as an
        // include so a script that writes one there still works.
        if trimmed.hasPrefix("/") && trimmed.hasSuffix("/") && trimmed.count > 2 {
            return includePattern(trimmed, matches: url)
        }

        guard let schemeRange = trimmed.range(of: "://") else { return false }
        let scheme = String(trimmed[trimmed.startIndex..<schemeRange.lowerBound]).lowercased()
        let remainder = String(trimmed[schemeRange.upperBound...])

        guard let urlScheme = url.scheme?.lowercased() else { return false }
        if scheme != "*" && scheme != urlScheme { return false }

        // Split host from path at the first slash after the host.
        let hostPart: String
        let pathPart: String
        if let slashIndex = remainder.firstIndex(of: "/") {
            hostPart = String(remainder[remainder.startIndex..<slashIndex])
            pathPart = String(remainder[slashIndex...])
        } else {
            hostPart = remainder
            pathPart = "/*"
        }

        guard let urlHost = url.host?.lowercased() else { return false }
        let patternHost = hostPart.lowercased()

        if patternHost == "*" {
            // Wildcard host still requires a host to exist.
            if urlHost.isEmpty { return false }
        } else if patternHost.hasPrefix("*.") {
            let suffix = String(patternHost.dropFirst(2))
            // `*.example.com` matches subdomains but not the bare domain —
            // that is the Chrome rule and scripts depend on it.
            guard urlHost.hasSuffix("." + suffix) else { return false }
        } else if urlHost != patternHost {
            return false
        }

        // The path is matched against path + query, because a script that asks
        // for `/*?foo*` means the query too.
        var pathAndQuery = url.path
        if let query = url.query, !query.isEmpty {
            pathAndQuery += "?" + query
        }
        if url.path.isEmpty { pathAndQuery = "/" + pathAndQuery }
        return globMatch(pattern: pathPart, value: pathAndQuery.hasPrefix("/") ? pathAndQuery : "/" + pathAndQuery)
    }

    // MARK: - Include patterns

    /// `@include` accepts a glob over the whole URL, plus `/regex/` form.
    static func includePattern(_ pattern: String, matches url: URL) -> Bool {
        let trimmed = pattern.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return false }

        if trimmed.hasPrefix("/") && trimmed.hasSuffix("/") && trimmed.count > 2 {
            let body = String(trimmed.dropFirst().dropLast())
            guard let regex = try? NSRegularExpression(pattern: body, options: [.caseInsensitive]) else {
                return false
            }
            let target = url.absoluteString
            let range = NSRange(target.startIndex..<target.endIndex, in: target)
            return regex.firstMatch(in: target, options: [], range: range) != nil
        }

        // A bare `*` means every page.
        if trimmed == "*" { return true }

        return globMatch(pattern: trimmed, value: url.absoluteString, caseSensitiveHost: true)
    }

    // MARK: - Glob

    /// Glob matching with `*` as the only wildcard.
    ///
    /// Implemented directly rather than through `NSPredicate` or by building a
    /// regex, because a user-supplied pattern must not be able to become a
    /// catastrophic-backtracking regular expression on every navigation.
    static func globMatch(pattern: String, value: String, caseSensitiveHost: Bool = false) -> Bool {
        let patternChars = Array(pattern.lowercased())
        let valueChars = Array(value.lowercased())

        var patternIndex = 0
        var valueIndex = 0
        var starIndex = -1
        var matchIndex = 0

        while valueIndex < valueChars.count {
            if patternIndex < patternChars.count,
               patternChars[patternIndex] == "*" {
                starIndex = patternIndex
                matchIndex = valueIndex
                patternIndex += 1
            } else if patternIndex < patternChars.count,
                      patternChars[patternIndex] == valueChars[valueIndex] {
                patternIndex += 1
                valueIndex += 1
            } else if starIndex != -1 {
                // Backtrack: let the star consume one more character.
                patternIndex = starIndex + 1
                matchIndex += 1
                valueIndex = matchIndex
            } else {
                return false
            }
        }

        while patternIndex < patternChars.count, patternChars[patternIndex] == "*" {
            patternIndex += 1
        }
        return patternIndex == patternChars.count
    }
}
