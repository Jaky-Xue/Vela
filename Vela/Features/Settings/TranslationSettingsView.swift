//
//  TranslationSettingsView.swift
//  Vela
//
//  Where 网页翻译 is pointed at a service.
//
//  Google's public endpoint is the default because it needs no account and
//  makes the feature work on first use. The other two providers are opt-in
//  credentials, and the screen explains that the page text goes to whichever
//  service is chosen — the browser performs the request, but it does not
//  translate anything itself.
//

import SwiftUI

struct TranslationSettingsView: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.browserPalette) private var palette

    private var settings: TranslationSettings {
        env.settings.translationSettings
    }

    var body: some View {
        List {
            Section {
                ForEach(TranslationProviderKind.allCases) { provider in
                    Button {
                        env.settings.updateTranslationSettings { $0.provider = provider }
                    } label: {
                        HStack(alignment: .top, spacing: 12) {
                            Image(systemName: symbol(for: provider))
                                .font(.system(size: 15, weight: .semibold))
                                .foregroundStyle(provider == settings.provider ? palette.onAccent : palette.accent)
                                .frame(width: 34, height: 34)
                                .background(
                                    provider == settings.provider
                                        ? palette.accent
                                        : palette.accent.opacity(0.13),
                                    in: RoundedRectangle(cornerRadius: 9, style: .continuous)
                                )

                            VStack(alignment: .leading, spacing: 3) {
                                Text(provider.displayName)
                                    .foregroundStyle(palette.primaryText)
                                Text(provider.summary)
                                    .font(.caption2)
                                    .foregroundStyle(palette.secondaryText)
                                    .fixedSize(horizontal: false, vertical: true)
                            }

                            Spacer(minLength: 6)

                            if provider == settings.provider {
                                Image(systemName: "checkmark")
                                    .foregroundStyle(palette.accent)
                            }
                        }
                        .padding(.vertical, 2)
                    }
                    .buttonStyle(.plain)
                }
            } header: {
                Text("服务商")
            }

            Section {
                Toggle(isOn: Binding(
                    get: { settings.offersAutomatically },
                    set: { value in
                        env.settings.updateTranslationSettings { $0.autoOffer = value }
                    }
                )) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("自动提示翻译外语页面")
                        Text("识别到页面语言与目标语言不同时，在页面顶部显示翻译栏。")
                            .font(.caption2)
                            .foregroundStyle(palette.secondaryText)
                    }
                }
                .tint(palette.accent)
            } header: {
                Text("自动提示")
            }

            Section {
                Picker("目标语言", selection: Binding(
                    get: { settings.target },
                    set: { language in
                        env.settings.updateTranslationSettings { $0.target = language }
                    }
                )) {
                    ForEach(TranslationTargetLanguage.allCases) { language in
                        Text(language.displayName).tag(language)
                    }
                }
            } header: {
                Text("翻译为")
            } footer: {
                Text("每次翻译都可以在翻译栏的选项菜单里临时改目标语言，这里选择的是默认值。")
            }

            if settings.provider.requiresAPIKey {
                Section {
                    SecureField(
                        settings.provider == .deepL ? "DeepL API 密钥" : "API 密钥",
                        text: Binding(
                            get: { settings.apiKey },
                            set: { value in
                                env.settings.updateTranslationSettings { $0.apiKey = value }
                            }
                        )
                    )
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                } header: {
                    Text("凭据")
                } footer: {
                    Text("密钥只保存在这台设备的设置里，不会上传到 Vela 之外的任何地方——它只随翻译请求发给所选服务商。")
                }
            }

            if let rules = settings.siteRules, !rules.isEmpty {
                Section {
                    ForEach(rules.keys.sorted(), id: \.self) { host in
                        HStack {
                            Text(host)
                            Spacer()
                            Text(
                                SiteTranslationRule(rawValue: rules[host] ?? "")?.displayName
                                    ?? "已忽略"
                            )
                            .font(.caption)
                            .foregroundStyle(palette.secondaryText)

                            Button {
                                env.settings.updateTranslationSettings { $0.setRule(nil, for: host) }
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .foregroundStyle(palette.secondaryText)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                } header: {
                    Text("网站规则")
                } footer: {
                    Text("在翻译栏的选项菜单里选择「总是翻译此网站」或「不再翻译此网站」会写到这里。")
                }
            }

            Section {
                TextField(
                    providerPlaceholder,
                    text: Binding(
                        get: { settings.endpoint },
                        set: { value in
                            env.settings.updateTranslationSettings { $0.endpoint = value }
                        }
                    )
                )
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .keyboardType(.URL)

                if settings.provider == .openAICompatible {
                    TextField(
                        "模型，例如 gpt-4o-mini",
                        text: Binding(
                            get: { settings.model },
                            set: { value in
                                env.settings.updateTranslationSettings { $0.model = value }
                            }
                        )
                    )
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                }
            } header: {
                Text("接口")
            } footer: {
                Text(endpointFooter)
            }

            Section("说明") {
                LabeledContent("当前状态", value: settings.isUsable ? "可以使用" : "缺少凭据")
                Text("翻译按段落进行，段落里的链接、加粗等行内标记会原样保留；译文写回页面而不重新载入文档，选择「显示原文」即可恢复，滚动位置不会丢失。")
                    .font(.footnote)
                    .foregroundStyle(palette.secondaryText)
            }
        }
        .navigationTitle("网页翻译")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func symbol(for provider: TranslationProviderKind) -> String {
        switch provider {
        case .google: return "globe"
        case .deepL: return "character.book.closed"
        case .openAICompatible: return "cpu"
        }
    }

    private var providerPlaceholder: String {
        switch settings.provider {
        case .google: return TranslationProviderKind.google.defaultEndpoint
        case .deepL: return TranslationProviderKind.deepL.defaultEndpoint
        case .openAICompatible: return TranslationProviderKind.openAICompatible.defaultEndpoint
        }
    }

    private var endpointFooter: String {
        switch settings.provider {
        case .google:
            return "留空使用 Google 的公共接口。该接口无需密钥，但在某些网络下可能无法访问。"
        case .deepL:
            return "留空使用免费版地址。Pro 账户请改为 https://api.deepl.com/v2/translate。"
        case .openAICompatible:
            return "填服务根地址（例如 https://api.deepseek.com/v1）或完整的 /chat/completions 地址；留空使用 OpenAI 默认地址。模型留空时使用 gpt-4o-mini。"
        }
    }
}
