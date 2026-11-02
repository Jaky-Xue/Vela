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

    @State private var packStatus: TranslationLanguagePackStatus?
    @State private var isPreparingPack = false
    @State private var packMessage: String?

    private var settings: TranslationSettings {
        env.settings.translationSettings
    }

    /// Re-checks the pack when the target or the page's language changes.
    private var packRefreshKey: String {
        "\(settings.target.rawValue)|\(env.translation.detected?.code ?? "")"
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

            if env.appleTranslationBridge != nil {
                Section {
                    if let source = env.translation.detected {
                        LabeledContent(
                            "语言对",
                            value: "\(source.displayName) → \(settings.target.displayName)"
                        )
                    } else {
                        Text("打开一个网页后，这里会显示当前网页语言 → 目标语言的语言包状态。")
                            .font(.footnote)
                            .foregroundStyle(palette.secondaryText)
                    }

                    HStack {
                        Text("语言包")
                        Spacer()
                        Text(packStatusText)
                            .foregroundStyle(packStatusColor)
                    }

                    Button {
                        Task { await preparePack() }
                    } label: {
                        HStack {
                            if isPreparingPack {
                                ProgressView().controlSize(.small)
                            }
                            Label(
                                packStatus == .needsDownload ? "下载语言包" : "检查并下载语言包",
                                systemImage: "arrow.down.circle"
                            )
                        }
                    }
                    .disabled(isPreparingPack)

                    if let packMessage {
                        Text(packMessage)
                            .font(.caption)
                            .foregroundStyle(palette.secondaryText)
                    }
                } header: {
                    Text("系统翻译语言包")
                } footer: {
                    Text("系统翻译在设备上运行。第一次使用某个语言对时需要下载系统语言包，下载由系统弹窗完成；这里可以提前检查并开始下载。")
                }
                .task(id: packRefreshKey) {
                    await refreshPackStatus()
                }
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

            if settings.provider != .appleSystem {
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
        .browserListSurface()
    }

    private var packStatusText: String {
        switch packStatus {
        case .installed: return "已安装"
        case .needsDownload: return "未安装，需要下载"
        case .unsupported: return "系统不支持此语言对"
        case .unknown, nil: return "打开网页后可检查"
        }
    }

    private var packStatusColor: Color {
        switch packStatus {
        case .installed: return .green
        case .needsDownload: return .orange
        case .unsupported: return .red
        default: return palette.secondaryText
        }
    }

    private func refreshPackStatus() async {
        guard let bridge = env.appleTranslationBridge else { return }
        packStatus = await bridge.languagePackStatus(
            source: env.translation.detected?.code,
            target: settings.target
        )
    }

    private func preparePack() async {
        guard let bridge = env.appleTranslationBridge else { return }
        isPreparingPack = true
        packMessage = nil
        defer { isPreparingPack = false }

        do {
            try await bridge.prepareLanguagePack(
                source: env.translation.detected?.code,
                target: settings.target
            )
            await refreshPackStatus()
            packMessage = packStatus == .installed
                ? "语言包已安装。"
                : "系统没有报告安装完成；如果下载弹窗被取消，可以再试一次。"
        } catch {
            packMessage = "无法开始下载：\(error.localizedDescription)"
        }
    }

    private func symbol(for provider: TranslationProviderKind) -> String {
        switch provider {
        case .google: return "globe"
        case .appleSystem: return "translate"
        case .deepL: return "character.book.closed"
        case .openAICompatible: return "cpu"
        }
    }

    private var providerPlaceholder: String {
        switch settings.provider {
        case .google: return TranslationProviderKind.google.defaultEndpoint
        case .appleSystem: return ""
        case .deepL: return TranslationProviderKind.deepL.defaultEndpoint
        case .openAICompatible: return TranslationProviderKind.openAICompatible.defaultEndpoint
        }
    }

    private var endpointFooter: String {
        switch settings.provider {
        case .google:
            return "留空使用 Google 的公共接口。该接口无需密钥；网络受限时会自动尝试系统离线翻译。"
        case .appleSystem:
            return "系统翻译不经过网络接口；首次使用会自动下载语言包。"
        case .deepL:
            return "留空使用免费版地址。Pro 账户请改为 https://api.deepl.com/v2/translate。"
        case .openAICompatible:
            return "填服务根地址（例如 https://api.deepseek.com/v1）或完整的 /chat/completions 地址；留空使用 OpenAI 默认地址。模型留空时使用 gpt-4o-mini。"
        }
    }
}
