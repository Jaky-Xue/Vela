//
//  UserScriptInstallPromptView.swift
//  Vela
//
//  The sheet a `*.user.js` link opens.
//
//  It confirms the link and installs from that link directly. The earlier
//  version downloaded the file first to draw a metadata preview, which meant a
//  large script — or a link that redirected to something bigger than the
//  preview's own ceiling — could not be installed at all. The link is the
//  source of truth here: the service downloads it, follows a metadata-only
//  `@updateURL`/`@downloadURL` file to the script it names, and installs that.
//  The preview was never the point; installing the script was.
//

import Foundation
import SwiftUI

@MainActor
struct UserScriptInstallPromptView: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.browserPalette) private var palette
    @Environment(\.dismiss) private var dismiss

    var request: UserScriptInstallRequest
    /// Called when the sheet closes for any reason, so the shell can clear the
    /// overlay value that presented it.
    var onFinish: () -> Void

    private enum Phase {
        case ready
        case installing
        case installed(String)
        case failed(String)

        var isInstalling: Bool {
            if case .installing = self { return true }
            return false
        }
    }

    @State private var phase: Phase = .ready

    var body: some View {
        NavigationStack {
            content
                .navigationTitle("安装用户脚本")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button(phase.isInstalling ? "关闭" : "取消") { finish() }
                    }
                }
        }
    }

    @ViewBuilder
    private var content: some View {
        switch phase {
        case .ready:
            readyState
        case .installing:
            installingState
        case let .installed(name):
            installedState(name)
        case let .failed(message):
            failureState(message)
        }
    }

    // MARK: - States

    private var readyState: some View {
        VStack(spacing: BrowserSpacing.regular) {
            Spacer()

            Image(systemName: "curlybraces")
                .font(.system(size: 34, weight: .light))
                .foregroundStyle(palette.accent)
                .frame(width: 70, height: 70)
                .background(palette.accent.opacity(0.12), in: Circle())

            VStack(spacing: 6) {
                Text("从链接安装用户脚本")
                    .font(.headline)
                    .foregroundStyle(palette.primaryText)
                Text("Vela 会下载这个链接并安装其中的脚本，安装后可随时在 设置 ▸ 用户脚本 中查看、编辑或停用。")
                    .font(.footnote)
                    .foregroundStyle(palette.secondaryText)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 28)
            }

            VStack(spacing: 4) {
                Text(request.url.absoluteString)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(palette.primaryText)
                    .lineLimit(3)
                    .multilineTextAlignment(.center)
                if !request.sourceHost.isEmpty {
                    Text("来自 \(request.sourceHost)")
                        .font(.caption2)
                        .foregroundStyle(palette.secondaryText)
                }
            }
            .padding(.horizontal, 20)

            Button {
                Task { await install() }
            } label: {
                Label("安装", systemImage: "arrow.down.circle.fill")
                    .font(.system(size: 15, weight: .semibold))
                    .frame(maxWidth: 260, minHeight: 46)
            }
            .buttonStyle(.borderedProminent)

            Spacer()
        }
    }

    private var installingState: some View {
        VStack(spacing: BrowserSpacing.regular) {
            Spacer()
            ProgressView()
                .controlSize(.large)
            Text("正在从链接下载并解析脚本…")
                .font(.subheadline)
                .foregroundStyle(palette.secondaryText)
            Spacer()
        }
    }

    private func installedState(_ name: String) -> some View {
        VStack(spacing: BrowserSpacing.regular) {
            Spacer()
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 38))
                .foregroundStyle(.green)
            Text("已安装「\(name)」")
                .font(.headline)
                .foregroundStyle(palette.primaryText)
            Text("重新载入当前页面后，脚本会在匹配的网页上运行。")
                .font(.footnote)
                .foregroundStyle(palette.secondaryText)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 28)
            Button("好") { finish() }
                .buttonStyle(.borderedProminent)
            Spacer()
        }
    }

    private func failureState(_ message: String) -> some View {
        VStack(spacing: BrowserSpacing.regular) {
            Spacer()
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 32, weight: .light))
                .foregroundStyle(.orange)
            Text("无法安装这个脚本")
                .font(.headline)
                .foregroundStyle(palette.primaryText)
            Text(message)
                .font(.footnote)
                .foregroundStyle(palette.secondaryText)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 28)
            HStack(spacing: BrowserSpacing.regular) {
                Button("重试") {
                    Task { await install() }
                }
                .buttonStyle(.bordered)
                Button("关闭") { finish() }
                    .buttonStyle(.borderedProminent)
            }
            Spacer()
        }
    }

    // MARK: - Install

    private func install() async {
        guard !phase.isInstalling else { return }
        phase = .installing
        let result = await env.userScripts.installFromURL(request.url)
        switch result {
        case let .success(outcome):
            phase = .installed(outcome.script.displayName)
        case let .failure(error):
            phase = .failed(error.localizedDescription)
        }
    }

    private func finish() {
        onFinish()
        dismiss()
    }
}
