//
//  TranslationSheet.swift
//  Vela
//
//  The page-translation panel.
//
//  It is a sheet rather than a toolbar mode because translation has a
//  beginning, a progress and an undo: the panel can say how many segments are
//  written so far, and its 显示原文 button is the way back. Dismissing it does
//  not undo the translation, which is what lets the user read the translated
//  page with the panel out of the way.
//

import SwiftUI
import WebKit

struct TranslationSheet: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.dismiss) private var dismiss
    @Environment(\.browserPalette) private var palette

    let webView: WKWebView

    @State private var target: TranslationTargetLanguage

    init(webView: WKWebView, target: TranslationTargetLanguage) {
        self.webView = webView
        _target = State(initialValue: target)
    }

    private var translation: TranslationService { env.translation }
    private var settings: TranslationSettings { env.settings.translationSettings }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    LabeledContent("服务商", value: settings.provider.displayName)
                    if case let .failed(message) = translation.phase {
                        Text(message)
                            .font(.footnote)
                            .foregroundStyle(.red)
                    } else {
                        Text(translation.statusText)
                            .font(.footnote)
                            .foregroundStyle(palette.secondaryText)
                    }
                } header: {
                    Text("状态")
                }

                if translation.isBusy {
                    Section {
                        ProgressView(value: translation.progress)
                        if case let .translating(done, total) = translation.phase {
                            Text("已写入 \(done) / \(total) 段")
                                .font(.caption)
                                .foregroundStyle(palette.secondaryText)
                        }
                    }
                }

                Section {
                    Picker("翻译为", selection: $target) {
                        ForEach(TranslationTargetLanguage.allCases) { language in
                            Text(language.displayName).tag(language)
                        }
                    }
                    .disabled(translation.isBusy)

                    if translation.isTranslated {
                        Button {
                            Task { await translation.restoreOriginal(webView: webView) }
                        } label: {
                            Label("显示原文", systemImage: "character.book.closed")
                        }

                        Button {
                            start()
                        } label: {
                            Label("重新翻译", systemImage: "arrow.clockwise")
                        }
                        .disabled(translation.isBusy || !settings.isUsable)
                    } else {
                        Button {
                            start()
                        } label: {
                            Label(translation.isBusy ? "正在翻译…" : "开始翻译", systemImage: "character.bubble")
                        }
                        .disabled(translation.isBusy || !settings.isUsable)
                    }

                    if !settings.isUsable {
                        Text("请先在 设置 ▸ 网页翻译 中填写服务商凭据。")
                            .font(.caption)
                            .foregroundStyle(palette.secondaryText)
                    }
                } header: {
                    Text("翻译")
                } footer: {
                    Text("页面文本会发送到 \(settings.provider.displayName) 完成翻译。译文直接写回页面，不重新载入文档。")
                }

                Section("说明") {
                    Text("只翻译当前可见文档中的正文文本，脚本、样式、代码块和单字符节点会被跳过。一次最多处理 800 段。")
                        .font(.footnote)
                        .foregroundStyle(palette.secondaryText)
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("网页翻译")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private func start() {
        env.settings.updateTranslationSettings { $0.target = target }
        Task {
            await translation.translate(
                webView: webView,
                settings: env.settings.translationSettings,
                target: target
            )
        }
    }
}
