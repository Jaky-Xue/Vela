import SwiftUI

struct PendingScriptUpdateView: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.dismiss) private var dismiss
    var scriptID: String
    @State private var candidate: UserScriptPackageCandidate?
    @State private var error: String?
    @State private var applying = false
    @State private var pending: PendingScriptUpdate?

    var body: some View {
        NavigationStack {
            List {
                if let pending {
                    Section("版本") {
                        LabeledContent("当前版本", value: pending.fromVersion.isEmpty ? "未标注" : pending.fromVersion)
                        LabeledContent("新版本", value: pending.toVersion.isEmpty ? "未标注" : pending.toVersion)
                        ForEach(pending.changes, id: \.self) { change in Label(change, systemImage: "arrow.triangle.2.circlepath") }
                    }
                }
                if let candidate {
                    Section("授权能力") {
                        ForEach(Array(Set(candidate.grants.map(\.rawValue))).sorted(), id: \.self) { Text($0).font(.footnote.monospaced()) }
                        if candidate.grants.contains(where: { !$0.isSupportedByVela }) { Label("含未支持能力", systemImage: "exclamationmark.circle").foregroundStyle(.orange) }
                    }
                    Section("运行网站") {
                        ForEach(Array(Set(candidate.matches + candidate.includes)).sorted(), id: \.self) { Text($0).font(.footnote) }
                        if !candidate.excludes.isEmpty || !candidate.excludeMatches.isEmpty {
                            DisclosureGroup("排除网站") {
                                ForEach(Array(Set(candidate.excludes + candidate.excludeMatches)).sorted(), id: \.self) { Text($0).font(.footnote) }
                            }
                        }
                        if env.settings.userScriptSettings.localRules?[scriptID] != nil { Text("保留本地运行规则").font(.caption) }
                    }
                    Section("联网范围") {
                        if candidate.connectRules.isEmpty { Text("未声明") }
                        ForEach(Array(Set(candidate.connectRules)).sorted(), id: \.self) { Text($0).font(.footnote) }
                    }
                    Section("依赖来源") {
                        LabeledContent("脚本依赖", value: String(candidate.requireUrls.count))
                        LabeledContent("资源数量", value: String(candidate.resourceDeclarations.count))
                        DisclosureGroup("地址详情") {
                            ForEach(Array(Set(candidate.requireUrls + candidate.resourceDeclarations.map(\.url))).sorted(), id: \.self) { Text($0).font(.footnote) }
                            if !candidate.updateUrl.isEmpty { LabeledContent("更新地址", value: candidate.updateUrl).font(.footnote) }
                            if !candidate.downloadUrl.isEmpty { LabeledContent("下载地址", value: candidate.downloadUrl).font(.footnote) }
                        }
                    }
                    Section {
                        Button("确认更新") { Task {
                            applying = true
                            if let hash = pending?.candidateHash, await env.userScripts.applyPendingUpdate(for: scriptID, expectedHash: hash) { dismiss() }
                            else { error = env.userScripts.lastError ?? "更新失败" }
                            applying = false
                        }}.disabled(applying)
                        Button("忽略更新", role: .destructive) { Task { await env.userScripts.dismissPendingUpdate(for: scriptID); dismiss() } }.disabled(applying)
                    }
                } else if error == nil { ProgressView("读取更新…") }
                if applying { ProgressView("正在更新…") }
                if let error { Section { Text(error).font(.footnote).foregroundStyle(.orange) } }
            }
            .settingsList().navigationTitle("审阅更新").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("稍后") { dismiss() } } }
            .task {
                do {
                    pending = env.userScripts.pendingUpdate(for: scriptID)
                    candidate = try await env.userScripts.pendingCandidate(for: scriptID, expectedHash: pending?.candidateHash)
                }
                catch { self.error = error.localizedDescription }
            }
        }
    }
}
