//
//  TranslationModels.swift
//  Vela
//
//  The values page translation is configured with: which service does the
//  translating, where it lives, what credential it wants, and which language
//  the user is reading in.
//
//  The settings live in their own document (`TranslationSettings`) rather than
//  inside `BrowserPreferences`, for the same reason the download and
//  navigation-diagnostics documents do: `BrowserPreferences` decodes as a
//  whole, so a new key in it would make every existing install's document fail
//  to decode and silently reset every setting.
//

import Foundation

// MARK: - Providers

/// One translation backend.
///
/// Three shapes cover what a browser actually needs. `google` is the key-less
/// public endpoint, which is what makes translation work the moment the feature
/// is opened. `deepL` is the documented DeepL API. The `openAICompatible` case
/// is generic on purpose: any service exposing `/chat/completions` with a
/// bearer token — a hosted model or a local server — can be pointed at it by
/// changing the endpoint and model.
public enum TranslationProviderKind: String, Codable, CaseIterable, Identifiable, Sendable {
    case google
    case appleSystem
    case deepL
    case openAICompatible

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .google: return "Google 翻译"
        case .appleSystem: return "系统翻译（离线）"
        case .deepL: return "DeepL"
        case .openAICompatible: return "OpenAI 兼容接口"
        }
    }

    public var summary: String {
        switch self {
        case .google: return "免密钥的公共接口；网络受限时自动尝试系统离线翻译。"
        case .appleSystem: return "使用 iOS 内置离线翻译，不经过 VPN 或第三方接口；首次使用需下载语言包。"
        case .deepL: return "需要 DeepL API 密钥，免费版与 Pro 版都支持。"
        case .openAICompatible: return "任何兼容 /chat/completions 的服务，可填自建地址。"
        }
    }

    public var requiresAPIKey: Bool {
        switch self {
        case .google, .appleSystem: return false
        case .deepL, .openAICompatible: return true
        }
    }

    /// The endpoint used when the settings document leaves it blank.
    public var defaultEndpoint: String {
        switch self {
        case .google: return "https://translate.googleapis.com/translate_a/single"
        case .appleSystem: return ""
        case .deepL: return "https://api-free.deepl.com/v2/translate"
        case .openAICompatible: return "https://api.openai.com/v1"
        }
    }

    public var defaultModel: String {
        switch self {
        case .google, .appleSystem, .deepL: return ""
        case .openAICompatible: return "gpt-4o-mini"
        }
    }

    /// The most text one request is given, and the most segments.
    ///
    /// The Google endpoint carries the text in a GET query string, so its
    /// budget is a URL-length budget; the two POST providers have room for
    /// more. Splitting the work is also what produces the progress the sheet
    /// shows.
    var batchCharacterLimit: Int {
        switch self {
        // Google is sent a POST body, not a query string, so a batch can hold
        // several paragraphs. Apple's on-device session has its own sensible
        // per-request size; the others have their own caps.
        case .google: return 12_000
        case .appleSystem: return 8_000
        case .deepL: return 24_000
        case .openAICompatible: return 8_000
        }
    }

    var batchItemLimit: Int {
        switch self {
        case .google: return 50
        case .appleSystem: return 40
        case .deepL: return 40
        case .openAICompatible: return 30
        }
    }
}

// MARK: - Target languages

/// The languages the picker offers.
///
/// A closed set rather than a text field: every provider spells the language
/// code differently, and an unknown code would turn into a request the service
/// rejects. The three spellings each provider needs live on the case.
public enum TranslationTargetLanguage: String, Codable, CaseIterable, Identifiable, Sendable {
    case simplifiedChinese = "zh-CN"
    case traditionalChinese = "zh-TW"
    case english = "en"
    case japanese = "ja"
    case korean = "ko"
    case french = "fr"
    case german = "de"
    case spanish = "es"
    case russian = "ru"

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .simplifiedChinese: return "简体中文"
        case .traditionalChinese: return "繁體中文"
        case .english: return "English"
        case .japanese: return "日本語"
        case .korean: return "한국어"
        case .french: return "Français"
        case .german: return "Deutsch"
        case .spanish: return "Español"
        case .russian: return "Русский"
        }
    }

    /// The Google code, which is also the value stored in settings.
    public var googleCode: String { rawValue }

    /// BCP-47 spelling for Apple's Translation framework.
    public var appleTranslationCode: String {
        switch self {
        case .simplifiedChinese: return "zh-Hans"
        case .traditionalChinese: return "zh-Hant"
        case .english: return "en"
        case .japanese: return "ja"
        case .korean: return "ko"
        case .french: return "fr"
        case .german: return "de"
        case .spanish: return "es"
        case .russian: return "ru"
        }
    }

    /// DeepL's spelling. DeepL grew `ZH-HANS`/`ZH-HANT`; the older `ZH` still
    /// means Simplified, which is the safer choice for a traditional-Chinese
    /// target because unsupported target languages are rejected outright.
    public var deepLCode: String {
        switch self {
        case .simplifiedChinese: return "ZH"
        case .traditionalChinese: return "ZH-HANT"
        case .english: return "EN-US"
        case .japanese: return "JA"
        case .korean: return "KO"
        case .french: return "FR"
        case .german: return "DE"
        case .spanish: return "ES"
        case .russian: return "RU"
        }
    }

    /// The target a fresh install starts with: the user's preferred language
    /// when it is one the picker offers, otherwise Simplified Chinese.
    public static var defaultTarget: TranslationTargetLanguage {
        for identifier in Locale.preferredLanguages {
            let lower = identifier.lowercased()
            if lower.hasPrefix("zh-hant") || lower.hasPrefix("zh-tw") || lower.hasPrefix("zh-hk") {
                return .traditionalChinese
            }
            if lower.hasPrefix("zh") { return .simplifiedChinese }
            if lower.hasPrefix("en") { return .english }
            if lower.hasPrefix("ja") { return .japanese }
            if lower.hasPrefix("ko") { return .korean }
            if lower.hasPrefix("fr") { return .french }
            if lower.hasPrefix("de") { return .german }
            if lower.hasPrefix("es") { return .spanish }
            if lower.hasPrefix("ru") { return .russian }
        }
        return .simplifiedChinese
    }

    /// The part of a language tag that identifies the language rather than the
    /// region or script. NaturalLanguage returns tags such as `zh-Hans`, while
    /// the settings store `zh-CN`; both are Chinese for this comparison.
    public static func baseCode(of code: String) -> String {
        let lower = code.lowercased()
        if lower.hasPrefix("zh") { return "zh" }
        return lower.split(separator: "-").first.map(String.init) ?? lower
    }

    /// How a chat-completions prompt names the language.
    public var naturalName: String {
        switch self {
        case .simplifiedChinese: return "Simplified Chinese"
        case .traditionalChinese: return "Traditional Chinese"
        case .english: return "English"
        case .japanese: return "Japanese"
        case .korean: return "Korean"
        case .french: return "French"
        case .german: return "German"
        case .spanish: return "Spanish"
        case .russian: return "Russian"
        }
    }
}

// MARK: - Site rules

/// What to do the next time a page on this host is recognised as foreign.
///
/// Chrome's "always translate" / "never translate" choice, scoped to a host.
/// Stored as raw strings because the settings document is decoded as a whole
/// and an unknown value must not fail the decode.
public enum SiteTranslationRule: String, Codable, Equatable, CaseIterable, Sendable {
    case always
    case never

    public var displayName: String {
        switch self {
        case .always: return "总是翻译"
        case .never: return "不再翻译"
        }
    }
}

/// A language the page is written in, as far as detection can tell.
public struct DetectedPageLanguage: Equatable, Sendable {
    public var code: String
    public var displayName: String
    public var confidence: Double

    public init(code: String, displayName: String, confidence: Double) {
        self.code = code
        self.displayName = displayName
        self.confidence = confidence
    }
}

// MARK: - Settings document

public struct TranslationSettings: Codable, Equatable, Sendable {
    public var provider: TranslationProviderKind
    /// A `TranslationTargetLanguage` raw value. Stored as a string so an
    /// unknown value written by a newer build decodes rather than resets.
    public var targetLanguage: String
    public var apiKey: String
    /// Blank means the provider's default endpoint.
    public var endpoint: String
    /// Blank means the provider's default model.
    public var model: String
    /// Host -> `SiteTranslationRule` raw value.
    ///
    /// Optional so an existing settings document still decodes; absent means
    /// no host has a rule yet.
    public var siteRules: [String: String]?
    /// Whether a foreign-language page offers translation automatically.
    /// Optional for the same decode-compatibility reason; absent means yes.
    public var autoOffer: Bool?

    public init(
        provider: TranslationProviderKind = .google,
        targetLanguage: String = TranslationTargetLanguage.defaultTarget.rawValue,
        apiKey: String = "",
        endpoint: String = "",
        model: String = "",
        siteRules: [String: String]? = nil,
        autoOffer: Bool? = nil
    ) {
        self.provider = provider
        self.targetLanguage = targetLanguage
        self.apiKey = apiKey
        self.endpoint = endpoint
        self.model = model
        self.siteRules = siteRules
        self.autoOffer = autoOffer
    }

    public static let `default` = TranslationSettings()

    /// Whether to offer translation for a foreign-language page without the
    /// user opening a menu.
    public var offersAutomatically: Bool { autoOffer ?? true }

    public func rule(for host: String) -> SiteTranslationRule? {
        guard let host = Self.normalizedHost(host),
              let raw = siteRules?[host] else { return nil }
        return SiteTranslationRule(rawValue: raw)
    }

    public mutating func setRule(_ rule: SiteTranslationRule?, for host: String) {
        guard let host = Self.normalizedHost(host) else { return }
        var rules = siteRules ?? [:]
        if let rule {
            rules[host] = rule.rawValue
        } else {
            rules.removeValue(forKey: host)
        }
        siteRules = rules.isEmpty ? nil : rules
    }

    /// A host without the `www.` prefix, so the same site does not need two
    /// rules depending on how its links were written.
    public static func normalizedHost(_ raw: String) -> String? {
        var host = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !host.isEmpty else { return nil }
        if host.hasPrefix("www.") { host = String(host.dropFirst(4)) }
        return host
    }

    public var target: TranslationTargetLanguage {
        get { TranslationTargetLanguage(rawValue: targetLanguage) ?? .simplifiedChinese }
        set { targetLanguage = newValue.rawValue }
    }

    public var resolvedEndpoint: String {
        let trimmed = endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? provider.defaultEndpoint : trimmed
    }

    public var resolvedModel: String {
        let trimmed = model.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? provider.defaultModel : trimmed
    }

    /// Whether enough is present to make a request. Google needs nothing; the
    /// other two need a credential, and a chat-completions provider also needs
    /// a model name.
    public var isUsable: Bool {
        switch provider {
        case .google, .appleSystem:
            return true
        case .deepL:
            return !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case .openAICompatible:
            return !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                && !resolvedModel.isEmpty
        }
    }
}

// MARK: - Errors

public enum TranslationError: LocalizedError {
    case notConfigured
    case noSegments
    case scriptUnavailable
    case http(Int)
    /// The provider asked the caller to slow down. The associated value is the
    /// provider's `Retry-After` hint, when it sent one.
    case rateLimited(TimeInterval?)
    case badResponse(String)
    case alignment
    case failed(String)

    public var errorDescription: String? {
        switch self {
        case .notConfigured:
            return "翻译服务尚未配置。请在 设置 ▸ 网页翻译 中填写服务商信息。"
        case .noSegments:
            return "没有找到可翻译的正文。页面可能还没有加载完成。"
        case .scriptUnavailable:
            return "无法在页面中执行脚本。页面可能已经离开。"
        case let .http(status):
            if status == 405 {
                return "翻译接口返回 405（不接受当前请求方法）。已自动尝试兼容请求；若仍失败，可能是当前网络/VPN 拦截了该接口，请更换网络或服务商。"
            }
            return "翻译服务返回了 \(status)。请检查密钥、接口地址或稍后重试。"
        case let .rateLimited(retryAfter):
            if let retryAfter, retryAfter > 0 {
                return "翻译服务限流（429）。请约 \(Int(retryAfter.rounded(.up))) 秒后重试，或在设置中更换翻译服务商。已翻译的段落会保留。"
            }
            return "翻译服务限流（429）。请稍后重试，或在设置中更换翻译服务商。已翻译的段落会保留。"
        case let .badResponse(message):
            return "翻译服务返回了无法解析的内容。\n\(message)"
        case .alignment:
            return "译文段落数与原文不一致，已停止写入。请重试或更换服务商。"
        case let .failed(message):
            return message
        }
    }
}
