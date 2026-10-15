//
//  AdBlockRuleCompiler.swift
//  Vela
//
//  Translates Adblock Plus filter syntax into WebKit content-blocker JSON.
//
//  Aira evaluates filters in its own Rust core
//  (`entry/src/main/cpp/rust/aira_adblock_core`, wrapping Brave's adblock
//  engine) because it owns the network stack. Inside a `WKWebView` there is no
//  way to intercept a subresource request, so iOS browsers must express
//  blocking as a `WKContentRuleList`: a JSON array of trigger/action pairs that
//  WebKit compiles and applies in its own process. This file is the bridge
//  between the filter lists users actually subscribe to and that format.
//
//  What is supported (the overwhelming majority of real-world rules):
//    ||example.com^          domain anchor
//    |https://example.com/   left anchor
//    example.com/ads$script  suffix anchor / plain substring
//    @@||example.com^        exception (ignore-previous-rules)
//    ##.ad-banner            cosmetic hide (css-display-none)
//    #@#.ad-banner           cosmetic exception
//    $script,image,third-party,domain=a.com|~b.com   options
//
//  What is not: regex rules (`/pattern/`), `$csp`, `$rewrite`, `$removeparam`,
//  scriptlet injection (`##+js(...)`), and extended CSS selectors
//  (`:has-text`, `:xpath`). Each of those has no representation in WebKit's
//  rule format; `unsupportedRuleCount` reports how many were skipped so the
//  settings screen can be honest about it rather than silently under-blocking.
//

import Foundation

/// One compiled content-blocker rule, in the shape `WKContentRuleList` expects.
///
/// Encoded with `JSONEncoder` rather than string-built, so a rule containing a
/// quote or a backslash cannot produce invalid JSON that fails the whole list.
public struct ContentBlockerRule: Codable, Equatable, Sendable {
    public struct Trigger: Codable, Equatable, Sendable {
        public var urlFilter: String
        public var ifDomain: [String]?
        public var unlessDomain: [String]?
        public var resourceType: [String]?
        public var loadType: [String]?

        enum CodingKeys: String, CodingKey {
            case urlFilter = "url-filter"
            case ifDomain = "if-domain"
            case unlessDomain = "unless-domain"
            case resourceType = "resource-type"
            case loadType = "load-type"
        }

        public init(
            urlFilter: String,
            ifDomain: [String]? = nil,
            unlessDomain: [String]? = nil,
            resourceType: [String]? = nil,
            loadType: [String]? = nil
        ) {
            self.urlFilter = urlFilter
            self.ifDomain = ifDomain
            self.unlessDomain = unlessDomain
            self.resourceType = resourceType
            self.loadType = loadType
        }
    }

    public struct Action: Codable, Equatable, Sendable {
        public var type: String
        public var selector: String?

        public init(type: String, selector: String? = nil) {
            self.type = type
            self.selector = selector
        }

        public static let block = Action(type: "block")
        public static let blockCookies = Action(type: "block-cookies")
        public static let ignorePreviousRules = Action(type: "ignore-previous-rules")

        public static func hide(selector: String) -> Action {
            Action(type: "css-display-none", selector: selector)
        }
    }

    public var trigger: Trigger
    public var action: Action

    public init(trigger: Trigger, action: Action) {
        self.trigger = trigger
        self.action = action
    }
}

/// The outcome of compiling one filter list.
public struct AdBlockCompileResult: Sendable {
    public var rules: [ContentBlockerRule]
    public var cosmeticSelectors: [String]
    /// Filters that parsed but have no WebKit representation.
    public var unsupportedRuleCount: Int
    /// Lines that did not parse at all.
    public var invalidRuleCount: Int
    public var sourceLineCount: Int

    public init(
        rules: [ContentBlockerRule] = [],
        cosmeticSelectors: [String] = [],
        unsupportedRuleCount: Int = 0,
        invalidRuleCount: Int = 0,
        sourceLineCount: Int = 0
    ) {
        self.rules = rules
        self.cosmeticSelectors = cosmeticSelectors
        self.unsupportedRuleCount = unsupportedRuleCount
        self.invalidRuleCount = invalidRuleCount
        self.sourceLineCount = sourceLineCount
    }

    /// WebKit refuses a rule list beyond roughly 150k rules or 50 MB. Callers
    /// check this before handing the list to the compiler.
    public static let webKitRuleLimit = 150_000
}

public enum AdBlockRuleCompiler {
    /// Compiles a whole filter list.
    ///
    /// - Parameter exceptions: hosts from the user's per-site exception list.
    ///   They become `ignore-previous-rules` triggers placed *after* the blocking
    ///   rules, because WebKit applies rules in order and a later ignore wins.
    public static func compile(
        filterList: String,
        exceptedHosts: [String] = [],
        includeCosmetic: Bool = true
    ) -> AdBlockCompileResult {
        var result = AdBlockCompileResult()
        var lines: [Substring] = filterList.split(whereSeparator: \.isNewline)
        result.sourceLineCount = lines.count

        // A list can declare `!#include`; Vela does not follow those, and a
        // silently missing include would look like under-blocking, so it counts
        // as unsupported rather than being dropped without a trace.
        for rawLine in lines {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { continue }
            guard !line.hasPrefix("!") else {
                if line.hasPrefix("!#include") { result.unsupportedRuleCount += 1 }
                continue
            }
            if line.hasPrefix("[") && line.hasSuffix("]") {
                // A metadata header such as [Adblock Plus 2.0].
                continue
            }

            if includeCosmetic, let cosmetic = compileCosmetic(line) {
                switch cosmetic {
                case let .hide(selector):
                    result.cosmeticSelectors.append(selector)
                case .unsupported:
                    result.unsupportedRuleCount += 1
                case .invalid:
                    result.invalidRuleCount += 1
                }
                continue
            }
            if line.contains("##") || line.contains("#@#") || line.contains("#?#") {
                result.unsupportedRuleCount += 1
                continue
            }

            switch compileNetworkRule(line) {
            case let .success(rule):
                result.rules.append(rule)
            case .unsupported:
                result.unsupportedRuleCount += 1
            case .invalid:
                result.invalidRuleCount += 1
            }
        }

        // The user's per-site exceptions go last so they override the list.
        result.rules.append(contentsOf: exceptionRules(for: exceptedHosts))
        return result
    }

    private enum CosmeticOutcome {
        case hide(String)
        case unsupported
        case invalid
    }

    private enum NetworkOutcome {
        case success(ContentBlockerRule)
        case unsupported
        case invalid
    }

    /// Compiles a `##` / `#@#` / `#?#` line.
    private static func compileCosmetic(_ line: String) -> CosmeticOutcome? {
        // `#?#` marks an extended selector, which WebKit cannot evaluate.
        if line.contains("#?#") { return .unsupported }

        let isException = line.contains("#@#")
        let separator = isException ? "#@#" : "##"
        guard let range = line.range(of: separator) else { return nil }

        let selector = String(line[range.upperBound...]).trimmingCharacters(in: .whitespaces)
        guard !selector.isEmpty else { return .invalid }
        // A plain CSS selector is required; anything with EasyList's extended
        // syntax is not expressible.
        if selector.contains(":has-text(") || selector.contains(":xpath(") ||
            selector.contains(":matches-") || selector.contains(":style(") ||
            selector.contains(":remove(") || selector.contains(":-abp-") {
            return .unsupported
        }
        // A scriptlet injection is not a selector at all.
        if selector.hasPrefix("+js(") { return .unsupported }

        // A cosmetic exception cannot be expressed: WebKit has no
        // "unhide this selector" action, so an exception on a host means the
        // caller has to leave the selector out of the list entirely.
        return isException ? .unsupported : .hide(selector)
    }

    /// Compiles one network rule.
    private static func compileNetworkRule(_ line: String) -> NetworkOutcome {
        var pattern = line
        var isException = false

        if pattern.hasPrefix("@@") {
            isException = true
            pattern = String(pattern.dropFirst(2))
        }

        // Options follow a `$`, but a `$` can also appear inside a URL. ABP
        // resolves this by taking the last `$` that is followed by a known
        // option token.
        var options = ""
        if let optionsRange = splitOptions(pattern) {
            options = optionsRange.options
            pattern = optionsRange.pattern
        }

        // A regex rule is not representable.
        if pattern.hasPrefix("/") && pattern.hasSuffix("/") && pattern.count > 2 {
            return .unsupported
        }
        if pattern.isEmpty {
            return .invalid
        }

        let parsedOptions = parseOptions(options)
        if parsedOptions.hasUnsupportedOption {
            return .unsupported
        }

        guard let urlFilter = regexFilter(for: pattern) else {
            return .invalid
        }

        let action: ContentBlockerRule.Action = isException
            ? .ignorePreviousRules
            : .block

        let trigger = ContentBlockerRule.Trigger(
            urlFilter: urlFilter,
            ifDomain: parsedOptions.includeDomains.isEmpty ? nil : parsedOptions.includeDomains,
            unlessDomain: parsedOptions.excludeDomains.isEmpty ? nil : parsedOptions.excludeDomains,
            resourceType: parsedOptions.resourceTypes.isEmpty ? nil : parsedOptions.resourceTypes,
            loadType: parsedOptions.loadType
        )
        return .success(ContentBlockerRule(trigger: trigger, action: action))
    }

    /// Splits the filter pattern from its `$`-options.
    ///
    /// Only splits when everything after the last `$` looks like an option
    /// list, so a URL containing `$` survives intact.
    private static func splitOptions(_ value: String) -> (pattern: String, options: String)? {
        let known = [
            "script", "image", "stylesheet", "object", "xmlhttprequest", "subdocument",
            "document", "font", "media", "ping", "websocket", "other", "popup",
            "third-party", "~third-party", "first-party", "domain=", "~domain=",
            "csp=", "rewrite=", "removeparam", "redirect=", "genericblock",
            "generichide", "elemhide", "important", "match-case", "collapse",
            "document", "all", "inline-script", "inline-font"
        ]

        guard let range = value.range(of: "$", options: .backwards) else { return nil }
        let candidate = String(value[range.upperBound...])
        guard !candidate.isEmpty else { return nil }

        let tokens = candidate.split(separator: ",").map {
            $0.trimmingCharacters(in: .whitespaces).lowercased()
        }
        guard !tokens.isEmpty else { return nil }

        let looksLikeOptions = tokens.allSatisfy { token in
            let bare = token.hasPrefix("~") ? String(token.dropFirst()) : token
            return known.contains { bare == $0 || bare.hasPrefix($0) }
        }
        guard looksLikeOptions else { return nil }

        return (String(value[value.startIndex..<range.lowerBound]), candidate)
    }

    private struct ParsedOptions {
        var resourceTypes: [String] = []
        var includeDomains: [String] = []
        var excludeDomains: [String] = []
        var loadType: [String]?
        var hasUnsupportedOption = false
    }

    private static func parseOptions(_ raw: String) -> ParsedOptions {
        var parsed = ParsedOptions()
        guard !raw.isEmpty else { return parsed }

        var types: [String] = []
        var include: [String] = []
        var exclude: [String] = []

        for token in raw.split(separator: ",") {
            let option = token.trimmingCharacters(in: .whitespaces).lowercased()
            guard !option.isEmpty else { continue }

            if option.hasPrefix("domain=") || option.hasPrefix("~domain=") {
                let body = option.replacingOccurrences(of: "~domain=", with: "")
                    .replacingOccurrences(of: "domain=", with: "")
                for entry in body.split(separator: "|") {
                    let host = entry.trimmingCharacters(in: .whitespaces)
                    guard !host.isEmpty else { continue }
                    if host.hasPrefix("~") {
                        exclude.append(String(host.dropFirst()))
                    } else {
                        include.append(host)
                    }
                }
                continue
            }

            switch option {
            case "third-party":
                parsed.loadType = ["third-party"]
            case "~third-party", "first-party":
                parsed.loadType = ["first-party"]
            case "important", "match-case", "collapse", "popup", "all", "elemhide",
                 "generichide", "genericblock", "document":
                // WebKit has no equivalent control for these. Treating them as
                // unsupported rather than ignoring them keeps the reported
                // coverage honest.
                if option == "popup" {
                    types.append("popup")
                } else if option == "document" {
                    types.append("document")
                } else {
                    parsed.hasUnsupportedOption = true
                }
            case "inline-script", "inline-font":
                parsed.hasUnsupportedOption = true
            default:
                if option.hasPrefix("csp=") || option.hasPrefix("rewrite=") ||
                    option.hasPrefix("redirect=") || option.hasPrefix("removeparam") {
                    parsed.hasUnsupportedOption = true
                } else if let mapped = webKitResourceType(for: option) {
                    types.append(mapped)
                } else {
                    parsed.hasUnsupportedOption = true
                }
            }
        }

        parsed.resourceTypes = Array(Set(types)).sorted()
        parsed.includeDomains = Array(Set(include)).sorted()
        parsed.excludeDomains = Array(Set(exclude)).sorted()
        return parsed
    }

    /// Maps an ABP resource token onto WebKit's resource-type vocabulary.
    private static func webKitResourceType(for option: String) -> String? {
        switch option {
        case "script": return "script"
        case "image": return "image"
        case "stylesheet": return "style-sheet"
        case "font": return "font"
        case "media": return "media"
        case "object", "object-subrequest", "xmlhttprequest", "other", "websocket", "ping":
            return "raw"
        case "subdocument": return "document"
        case "document": return "document"
        case "popup": return "popup"
        case "svg": return "svg-document"
        default: return nil
        }
    }

    /// Turns an ABP pattern into a WebKit `url-filter` regular expression.
    ///
    /// The anchor handling is the whole job here. `||` means "domain anchor"
    /// (this host or a subdomain), a leading `|` means "start of URL", a
    /// trailing `|` means "end of URL", and `^` means "separator". Everything
    /// else is a literal that must be escaped, because a `.` in a filter is a
    /// literal dot, not a regex wildcard.
    static func regexFilter(for pattern: String) -> String? {
        var body = pattern
        var prefix = ""
        var suffix = ""

        if body.hasPrefix("||") {
            body = String(body.dropFirst(2))
            // Scheme, then an optional subdomain chain. WebKit's url-filter
            // matches the whole URL, so the anchor has to be spelled out.
            prefix = "^[a-z][a-z0-9+.-]*://([^/]+\\.)?"
            // A trailing `^` on a domain anchor already covers the path
            // separator, so the generic separator suffix below would double it.
        } else if body.hasPrefix("|") {
            body = String(body.dropFirst())
            prefix = "^"
        }

        if body.hasSuffix("|") {
            body = String(body.dropLast())
            suffix = "$"
        }

        var regex = ""
        for character in body {
            switch character {
            case "*":
                regex += ".*"
            case "^":
                // ABP separator: anything that is not a letter, digit, or one
                // of `_ - . %`.
                regex += "[^a-zA-Z0-9_.%-]"
            case ".":
                regex += "\\."
            case "?", "+", "(", ")", "[", "]", "{", "}", "\\", "/", "$", "^", "|":
                regex += "\\" + String(character)
            default:
                if character.isLetter || character.isNumber || "-".contains(character) || "_".contains(character) {
                    regex += String(character)
                } else {
                    regex += NSRegularExpression.escapedPattern(for: String(character))
                }
            }
        }

        // A rule ending in a separator should still match a URL that ends right
        // there, so the trailing separator becomes optional.
        if body.hasSuffix("^") {
            regex = String(regex.dropLast("[^a-zA-Z0-9_.%-]".count))
            regex += "([^a-zA-Z0-9_.%-]|$)"
        }

        let combined = prefix + regex + suffix
        guard !combined.isEmpty, combined != "^" else { return nil }

        // WebKit rejects a filter that does not compile, and one bad rule fails
        // the entire list, so validate before returning.
        guard (try? NSRegularExpression(pattern: combined)) != nil else { return nil }
        return combined
    }

    /// Builds the exception rules for the user's per-site whitelist.
    private static func exceptionRules(for hosts: [String]) -> [ContentBlockerRule] {
        hosts.compactMap { host in
            let normalized = host.lowercased().trimmingCharacters(in: .whitespaces)
            guard !normalized.isEmpty else { return nil }
            return ContentBlockerRule(
                trigger: ContentBlockerRule.Trigger(
                    urlFilter: ".*",
                    ifDomain: ["*" + normalized]
                ),
                action: .ignorePreviousRules
            )
        }
    }

    /// Encodes rules into the JSON `WKContentRuleListStore` accepts.
    public static func encode(_ rules: [ContentBlockerRule]) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        let data = try encoder.encode(rules)
        guard let json = String(data: data, encoding: .utf8) else {
            throw AdBlockError.encodingFailed
        }
        return json
    }
}

public enum AdBlockError: Error, LocalizedError {
    case encodingFailed
    case compilationFailed(String)
    case ruleListTooLarge(count: Int)

    public var errorDescription: String? {
        switch self {
        case .encodingFailed:
            return "无法生成过滤规则。"
        case let .compilationFailed(message):
            return "过滤规则编译失败：\(message)"
        case let .ruleListTooLarge(count):
            return "过滤规则过多（\(count) 条），超出系统上限。请减少订阅列表。"
        }
    }
}
