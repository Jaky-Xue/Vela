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
    case deepL
    case openAICompatible

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .google: return "Google 翻译"
        case .deepL: return "DeepL"
        case .openAICompatible: return "OpenAI 兼容接口"
        }
    }

    public var summary: String {
        switch self {
        case .google: return "免密钥的公共接口，直接可用。"
        case .deepL: return "需要 DeepL API 密钥，免费版与 Pro 版都支持。"
        case .openAICompatible: return "任何兼容 /chat/completions 的服务，可填自建地址。"
        }
    }

    public var requiresAPIKey: Bool {
        self != .google
    }

    /// The endpoint used when the settings document leaves it blank.
    public var defaultEndpoint: String {
        switch self {
        case .google: return "https://translate.googleapis.com/translate_a/single"
        case .deepL: return "https://api-free.deepl.com/v2/translate"
        case .openAICompatible: return "https://api.openai.com/v1"
        }
    }

    public var defaultModel: String {
        switch self {
        case .google, .deepL: return ""
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
        case .google: return 1_600
        case .deepL: return 9_000
        case .openAICompatible: return 6_000
        }
    }

    var batchItemLimit: Int {
        switch self {
        case .google: return 20
        case .deepL: return 40
        case .openAICompatible: return 40
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

    public init(
        provider: TranslationProviderKind = .google,
        targetLanguage: String = TranslationTargetLanguage.simplifiedChinese.rawValue,
        apiKey: String = "",
        endpoint: String = "",
        model: String = ""
    ) {
        self.provider = provider
        self.targetLanguage = targetLanguage
        self.apiKey = apiKey
        self.endpoint = endpoint
        self.model = model
    }

    public static let `default` = TranslationSettings()

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
        case .google:
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
            return "翻译服务返回了 \(status)。请检查密钥、接口地址或稍后重试。"
        case let .badResponse(message):
            return "翻译服务返回了无法解析的内容。\n\(message)"
        case .alignment:
            return "译文段落数与原文不一致，已停止写入。请重试或更换服务商。"
        case let .failed(message):
            return message
        }
    }
}
