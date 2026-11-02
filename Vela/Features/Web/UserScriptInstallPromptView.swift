//
//  UserScriptInstallPromptView.swift
//  Vela
//
//  The review sheet a `*.user.js` link opens.
//
//  A userscript manager owns the install link: tapping one on a gallery page
//  should offer to install the script, not print its source in the tab. The
//  navigation is stopped before it starts, the URL arrives here, and this sheet
//  fetches and parses it so the user sees the name, the rules it will run on and
//  the grants it asks for before anything reaches the database.
//
//  The sheet intentionally does not trust the link: the script is fetched once
//  here, capped in size, and the bytes are what the installer parses. A gallery
//  that serves a redirect or an error page lands on the failure path with the
//  server's message rather than as an empty "success".
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
        case loading
        case failed(String)
        case review(UserScriptPackageCandidate, warnings: [String])
        case installing
        case installed(String)
    }

    @State private var phase: Phase = .loading
    @State private var attempt = 0
    /// The exact bytes that passed review. Installing reuses them instead of
    /// downloading the gallery page a second time.
    @State private var reviewedSource: String?

    /// A script is text; a link that serves more than this is not one.
    private static let maximumBytes = 5 * 1024 * 1024

    var body: some View {
        NavigationStack {
            content
                .navigationTitle("安装用户脚本")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("取消") { finish() }
                    }
                }
        }
        .task(id: attempt) {
            await load()
        }
    }

    @ViewBuilder
    private var content: some View {
        switch phase {
        case .loading:
            loadingState
        case let .failed(message):
            failureState(message)
        case let .review(candidate, warnings):
            reviewState(candidate, warnings: warnings)
        case .installing:
            installingState
        case let .installed(name):
            installedState(name)
        }
    }

    // MARK: - States

    private var loadingState: some View {
        VStack(spacing: BrowserSpacing.regular) {
            Spacer()
            ProgressView()
                .controlSize(.large)
            Text("正在下载脚本…")
                .font(.subheadline)
                .foregroundStyle(palette.secondaryText)
            Text(request.url.absoluteString)
                .font(.caption2)
                .foregroundStyle(palette.secondaryText)
                .lineLimit(2)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
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
                    phase = .loading
                    attempt += 1
                }
                .buttonStyle(.bordered)
                Button("关闭") { finish() }
                    .buttonStyle(.borderedProminent)
            }
            Spacer()
        }
    }

    private func reviewState(
        _ candidate: UserScriptPackageCandidate,
        warnings: [String]
    ) -> some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: 6) {
                    Text(candidate.name.isEmpty ? "未命名脚本" : candidate.name)
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(palette.primaryText)
                    if !candidate.description.isEmpty {
                        Text(candidate.description)
                            .font(.footnote)
                            .foregroundStyle(palette.secondaryText)
                    }
                    HStack(spacing: 8) {
                        if !candidate.version.isEmpty {
                            Label("v\(candidate.version)", systemImage: "number")
                        }
                        if !request.sourceHost.isEmpty {
                            Label(request.sourceHost, systemImage: "globe")
                        }
                    }
                    .font(.caption)
                    .foregroundStyle(palette.secondaryText)
                }
                .padding(.vertical, 4)
            }

            Section {
                if candidate.matches.isEmpty && candidate.includes.isEmpty {
                    Text("没有匹配规则")
                        .foregroundStyle(palette.secondaryText)
                } else {
                    ForEach(Array(rules(of: candidate).prefix(12)), id: \.self) { pattern in
                        Text(pattern)
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundStyle(palette.primaryText)
                    }
                    let total = rules(of: candidate).count
                    if total > 12 {
                        Text("还有 \(total - 12) 条规则，安装后可在详情中查看。")
                            .font(.caption)
                            .foregroundStyle(palette.secondaryText)
                    }
                }
            } header: {
                Text("运行于")
            } footer: {
                Text("脚本只会在匹配这些地址的网页上运行。")
            }

            if !candidate.grants.isEmpty {
                Section {
                    ForEach(Array(candidate.grants.prefix(10)), id: \.self) { grant in
                        HStack {
                            Text(grant.rawValue)
                                .font(.system(size: 12, design: .monospaced))
                            Spacer()
                            Image(systemName: grant.isSupportedByVela
                                ? "checkmark.circle.fill"
                                : "xmark.circle.fill")
                                .foregroundStyle(grant.isSupportedByVela ? .green : .orange)
                        }
                    }
                } header: {
                    Text("申请的权限")
                } footer: {
                    if candidate.grants.contains(where: { !$0.isSupportedByVela }) {
                        Text("带橙色标记的权限在 iOS 上不可用；脚本仍可安装，调用时返回空值。")
                    }
                }
            }

            if !candidate.requireUrls.isEmpty || !candidate.resourceDeclarations.isEmpty {
                Section {
                    LabeledContent("@require 依赖", value: "\(candidate.requireUrls.count) 个")
                    LabeledContent("@resource 资源", value: "\(candidate.resourceDeclarations.count) 个")
                } footer: {
                    Text("安装时会一并下载这些依赖；失败时脚本仍会保存，可在详情中重试。")
                }
            }

            if !warnings.isEmpty {
                Section("提示") {
                    ForEach(warnings, id: \.self) { warning in
                        Text(warning)
                            .font(.caption)
                            .foregroundStyle(palette.secondaryText)
                    }
                }
            }

            Section {
                Button {
                    Task { await install() }
                } label: {
                    Label("安装", systemImage: "arrow.down.circle.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .listRowInsets(EdgeInsets(top: 6, leading: 16, bottom: 6, trailing: 16))
            }
        }
        .listStyle(.insetGrouped)
        .browserListSurface()
    }

    private var installingState: some View {
        VStack(spacing: BrowserSpacing.regular) {
            Spacer()
            ProgressView()
                .controlSize(.large)
            Text("正在保存脚本与依赖…")
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

    // MARK: - Loading and installing

    private func load() async {
        var urlRequest = URLRequest(url: request.url)
        urlRequest.timeoutInterval = 25
        urlRequest.cachePolicy = .reloadIgnoringLocalCacheData

        do {
            let (data, response) = try await URLSession.shared.data(for: urlRequest)
            if let http = response as? HTTPURLResponse,
               !(200..<300).contains(http.statusCode) {
                phase = .failed("服务器返回 HTTP \(http.statusCode)。")
                return
            }
            guard data.count <= Self.maximumBytes else {
                phase = .failed("文件超过 5 MB，可能是网页而不是用户脚本。")
                return
            }
            guard let text = Self.decode(data) else {
                phase = .failed("无法读取文件内容，编码不受支持。")
                return
            }
            let parse = UserScriptParser.parse(
                text,
                installSource: .url,
                sourceUrl: request.url.absoluteString
            )
            guard parse.valid, let candidate = parse.candidate else {
                phase = .failed(parse.errorMessage)
                return
            }
            reviewedSource = text
            phase = .review(candidate, warnings: parse.warnings)
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }

    private func install() async {
        guard let text = reviewedSource else {
            phase = .failed("脚本内容已失效，请重试。")
            return
        }
        phase = .installing
        let result = await env.userScripts.install(
            text: text,
            source: .url,
            sourceUrl: request.url.absoluteString
        )
        switch result {
        case let .success(outcome):
            phase = .installed(outcome.script.displayName)
        case let .failure(error):
            phase = .failed(error.localizedDescription)
        }
    }

    /// The match and include rules, de-duplicated and in declaration order.
    private func rules(of candidate: UserScriptPackageCandidate) -> [String] {
        var seen = Set<String>()
        return (candidate.matches + candidate.includes).filter { seen.insert($0).inserted }
    }

    private static func decode(_ data: Data) -> String? {
        String(data: data, encoding: .utf8)
            ?? String(data: data, encoding: .utf16)
            ?? String(data: data, encoding: .isoLatin1)
    }

    private func finish() {
        onFinish()
        dismiss()
    }
}
