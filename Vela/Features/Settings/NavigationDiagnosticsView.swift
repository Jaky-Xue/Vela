//
//  NavigationDiagnosticsView.swift
//  Vela
//
//  The screen over `NavigationLog`.
//
//  It exists because a page that will not load raises the same question every
//  time — which page, at which phase, because of what — and none of that is
//  answerable from outside the app. The log is where the answer already is, so
//  this is a view onto it rather than a second source of truth.
//
//  The privacy position is stated on the screen itself rather than only in the
//  code, because a user has to be able to decide whether to copy the report: it
//  holds addresses with their query values removed, nothing is written to disk,
//  and the log records nothing at all while it is switched off.
//

import SwiftUI
import UIKit

struct NavigationDiagnosticsView: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.browserPalette) private var palette

    @State private var didCopy = false

    private var settings: NavigationDiagnosticsSettings {
        env.settings.navigationDiagnostics
    }

    /// Newest first: the navigation that just failed is the one being asked
    /// about.
    private var entries: [NavigationLogEntry] {
        env.navigationLog.entries.reversed()
    }

    var body: some View {
        List {
            Section {
                Toggle("记录加载诊断", isOn: Binding(
                    get: { settings.enabled },
                    set: { value in
                        env.settings.updateNavigationDiagnostics { $0.enabled = value }
                        env.applyNavigationDiagnosticsSettings()
                    }
                ))
                .tint(palette.accent)
            } header: {
                Text("诊断")
            } footer: {
                Text("记录只保存在本次运行的记忆中，退出应用即清空，也不会写入浏览历史。地址中的查询参数只记录数量，不记录内容；Cookie、请求头和表单内容从不记录。")
            }

            Section {
                Button {
                    UIPasteboard.general.string = env.navigationLog.report()
                    didCopy = true
                    Task {
                        try? await Task.sleep(for: .seconds(2))
                        didCopy = false
                    }
                } label: {
                    Label(didCopy ? "已复制" : "复制诊断信息", systemImage: didCopy ? "checkmark" : "doc.on.doc")
                }
                .disabled(entries.isEmpty)

                Button(role: .destructive) {
                    env.navigationLog.clear()
                } label: {
                    Label("清空记录", systemImage: "trash")
                }
                .disabled(entries.isEmpty)
            }

            if entries.isEmpty {
                Section {
                    Text(settings.enabled ? "还没有导航记录。" : "加载诊断已关闭。")
                        .font(.footnote)
                        .foregroundStyle(palette.secondaryText)
                }
            } else {
                Section("最近的导航") {
                    ForEach(entries) { entry in
                        NavigationLogRow(entry: entry)
                    }
                }
            }
        }
        .navigationTitle("加载诊断")
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// One entry, laid out so the phase and the failure are what the eye lands on.
private struct NavigationLogRow: View {
    var entry: NavigationLogEntry

    @Environment(\.browserPalette) private var palette

    var body: some View {
        VStack(alignment: .leading, spacing: BrowserSpacing.hairline) {
            HStack(spacing: BrowserSpacing.tight) {
                Text(entry.event.rawValue)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(tint)
                Text(entry.phase.rawValue)
                    .font(.caption2)
                    .foregroundStyle(palette.secondaryText)
                Spacer(minLength: 0)
                if let duration = entry.durationMs {
                    Text("\(duration) ms")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(palette.secondaryText)
                }
            }

            Text(entry.url.isEmpty ? "（无地址）" : entry.url)
                .font(.caption.monospaced())
                .foregroundStyle(palette.primaryText)
                .lineLimit(2)
                .truncationMode(.middle)

            if let finalUrl = entry.finalUrl, finalUrl != entry.url {
                Text("→ \(finalUrl)")
                    .font(.caption2.monospaced())
                    .foregroundStyle(palette.secondaryText)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            if !entry.errorDomain.isEmpty {
                Text("\(entry.errorDomain) \(entry.errorCode) · \(entry.errorMessage)")
                    .font(.caption2)
                    .foregroundStyle(palette.secondaryText)
                    .lineLimit(2)
            }

            HStack(spacing: BrowserSpacing.compact) {
                Text("#\(entry.navigationSerial)")
                if entry.adBlockActive { Text("拦截开") }
                if entry.userScriptsActive { Text("脚本开") }
                if !entry.navigationType.isEmpty { Text(entry.navigationType) }
            }
            .font(.caption2)
            .foregroundStyle(palette.secondaryText.opacity(0.8))
        }
        .padding(.vertical, BrowserSpacing.hairline)
    }

    private var tint: Color {
        switch entry.outcome {
        case .ok: return .green
        case .failure: return .red
        case .cancelled: return palette.secondaryText
        case .info: return palette.accent
        }
    }
}
