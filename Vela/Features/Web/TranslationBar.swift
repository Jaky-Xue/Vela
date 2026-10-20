//
//  TranslationBar.swift
//  Vela
//
//  The strip Chrome puts above a translated page.
//
//  It is a bar rather than a sheet because translation has three states the
//  user needs to see without asking for them: a page in another language that
//  can be translated, a translation in progress, and a translated page with a
//  way back to the original. The bar floats over the page’s top edge and stays
//  out of the content’s way; the page keeps its scroll position throughout.
//

import SwiftUI
import WebKit

struct TranslationBar: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.browserPalette) private var palette
    @Environment(\.colorScheme) private var colorScheme

    let webView: WKWebView
    let onClose: () -> Void
    let onOpenSettings: () -> Void

    private var translation: TranslationService { env.translation }
    private var settings: TranslationSettings { env.settings.translationSettings }

    private var host: String {
        URL(string: webView.url?.absoluteString ?? "")?.host ?? ""
    }

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "character.bubble")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(palette.accent)

            status
                .font(.footnote)
                .lineLimit(2)
                .foregroundStyle(palette.primaryText)
                .frame(maxWidth: .infinity, alignment: .leading)

            if translation.isBusy {
                ProgressView(value: translation.progress)
                    .progressViewStyle(.linear)
                    .frame(width: 52)
                    .tint(palette.accent)
            }

            action

            optionsMenu

            Button {
                onClose()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(palette.secondaryText)
                    .frame(width: 24, height: 24)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("关闭翻译栏")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background {
            RoundedRectangle(cornerRadius: 15, style: .continuous)
                .fill(.ultraThinMaterial)
                .overlay {
                    RoundedRectangle(cornerRadius: 15, style: .continuous)
                        .fill(palette.card.opacity(colorScheme == .dark ? 0.55 : 0.62))
                }
        }
        .overlay {
            RoundedRectangle(cornerRadius: 15, style: .continuous)
                .strokeBorder(palette.cardStroke, lineWidth: 0.6)
        }
        .shadow(color: .black.opacity(0.16), radius: 14, y: 5)
        .tint(palette.accent)
    }

    // MARK: - Status

    @ViewBuilder
    private var status: some View {
        switch translation.phase {
        case .idle:
            if let detected = translation.detected {
                Text("此页面是\(detected.displayName)，翻译成\(settings.target.displayName)？")
            } else {
                Text("翻译成\(settings.target.displayName)？")
            }
        case .extracting:
            Text("正在读取正文…")
        case let .translating(done, total):
            Text("正在翻译 \(done)/\(total)…")
        case .finished:
            Text("已翻译成\(translation.appliedTarget?.displayName ?? settings.target.displayName)")
        case let .failed(message):
            Text(message)
                .foregroundStyle(.red)
        }
    }

    // MARK: - Action

    @ViewBuilder
    private var action: some View {
        switch translation.phase {
        case .idle:
            Button("翻译") {
                start(into: settings.target)
            }
            .font(.footnote.weight(.semibold))
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
        case .extracting, .translating:
            EmptyView()
        case .finished:
            Button("显示原文") {
                Task { await translation.restoreOriginal(webView: webView) }
            }
            .font(.footnote.weight(.semibold))
            .buttonStyle(.borderless)
        case .failed:
            Button("重试") {
                start(into: settings.target)
            }
            .font(.footnote.weight(.semibold))
            .buttonStyle(.borderless)
        }
    }

    // MARK: - Options

    private var optionsMenu: some View {
        Menu {
            Section("翻译为") {
                ForEach(TranslationTargetLanguage.allCases) { language in
                    Button {
                        start(into: language)
                    } label: {
                        if language == settings.target {
                            Label(language.displayName, systemImage: "checkmark")
                        } else {
                            Text(language.displayName)
                        }
                    }
                }
            }

            Section {
                if settings.rule(for: host) == .always {
                    Button("取消总是翻译此网站") { setRule(nil) }
                } else {
                    Button("总是翻译此网站") { setRule(.always) }
                }
                if settings.rule(for: host) == .never {
                    Button("取消不翻译此网站") { setRule(nil) }
                } else {
                    Button("不再翻译此网站") { setRule(.never) }
                }
            }

            Button("翻译设置…") { onOpenSettings() }
        } label: {
            Image(systemName: "ellipsis.circle")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(palette.secondaryText)
                .frame(width: 26, height: 24)
        }
    }

    // MARK: - Actions

    private func start(into target: TranslationTargetLanguage) {
        env.settings.updateTranslationSettings { $0.target = target }
        let latest = env.settings.translationSettings
        Task {
            await translation.translate(
                webView: webView,
                settings: latest,
                target: target
            )
        }
    }

    private func setRule(_ rule: SiteTranslationRule?) {
        env.settings.updateTranslationSettings { $0.setRule(rule, for: host) }
        // 不再翻译 applies to the offer on screen too, not only to the next
        // visit; a translated page keeps its bar and its 显示原文 action.
        if rule == .never, !translation.isTranslated {
            onClose()
        }
    }
}
