import SwiftUI

struct FilterSourcesSettingsView: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.browserPalette) private var palette
    @State private var sourceName = ""
    @State private var sourceURL = ""
    @State private var customText = ""
    @State private var saved = false
    @State private var loaded = false
    private var blocker: ContentBlocker { env.services.contentBlocker }

    var body: some View {
        List {
            Section {
                ForEach(AdBlockBuiltInRules.filterLists.keys.sorted(), id: \.self) { id in
                    Toggle(builtInName(id), isOn: Binding(
                        get: { !(env.settings.contentBlocker.disabledBuiltIns ?? []).contains(id) },
                        set: { value in Task { await blocker.setBuiltIn(id, enabled: value) } }
                    )).tint(palette.accent).disabled(blocker.isCompiling)
                }
            } header: { Text("内置来源") }
            Section {
                ForEach(env.settings.contentBlocker.subscriptions ?? []) { source in
                    VStack(alignment: .leading, spacing: 6) {
                        Toggle(source.name, isOn: Binding(
                            get: { source.enabled },
                            set: { value in Task { await blocker.setSubscription(source.id, enabled: value) } }
                        )).tint(palette.accent).disabled(blocker.isCompiling)
                        Text(source.url).font(.caption).foregroundStyle(palette.secondaryText).lineLimit(2)
                        if let date = source.lastSuccess {
                            Text("缓存更新：" + date.formatted(date: .abbreviated, time: .shortened)).font(.caption)
                        }
                        if let error = source.error { Text(error).font(.caption).foregroundStyle(.orange) }
                        Button("移除此来源", role: .destructive) {
                            Task { await blocker.removeSubscription(source.id) }
                        }.font(.caption).disabled(blocker.isCompiling)
                    }.padding(.vertical, 4)
                }
                Button {
                    Task { await blocker.refreshSubscriptions() }
                } label: { Label("更新所有已启用的订阅", systemImage: "arrow.clockwise") }
                .disabled(blocker.isCompiling || (env.settings.contentBlocker.subscriptions ?? []).isEmpty)
                TextField("来源名称（可选）", text: $sourceName)
                TextField("https://… 订阅地址", text: $sourceURL)
                    .textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL)
                Button("下载、验证并添加") {
                    Task {
                        if await blocker.addSubscription(name: sourceName, url: sourceURL) { sourceName = ""; sourceURL = "" }
                    }
                }.disabled(blocker.isCompiling || sourceURL.trimmingCharacters(in: .whitespaces).isEmpty)
            } header: { Text("远程订阅") } footer: {
                Text("支持 HTTPS、UTF-8 纯文本来源，每份最多 2 MB，合并最多 8 MB。不展开 include 指令。离线使用缓存；下载或编译失败保留有效版本。")
            }
            Section {
                TextEditor(text: $customText)
                    .font(.system(.footnote, design: .monospaced))
                    .frame(minHeight: 190)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                    .onChange(of: customText) { _, _ in saved = false }
                Button(saved ? "已保存并生效" : "验证并应用自定义规则") {
                    Task { saved = await blocker.saveCustomRules(customText) }
                }.disabled(blocker.isCompiling)
            } header: { Text("自定义 ABP 规则") } footer: {
                Text("例如 ||tracker.example^ 或 ##.ad-banner。支持的子集会编译到 WebKit；未知选项会跳过并计数。无效规则不覆盖当前配置。")
            }
            Section {
                if blocker.isCompiling { ProgressView("正在验证并编译候选规则…") }
                if let error = blocker.lastError { Text(error).font(.footnote).foregroundStyle(.orange) }
                if let snapshot = env.settings.contentBlocker.activeSnapshot {
                    LabeledContent("网络与放行规则", value: String(snapshot.networkCount))
                    LabeledContent("隐藏规则", value: String(snapshot.hiddenCount))
                    LabeledContent("跳过规则", value: String(snapshot.skippedCount))
                    Text("活动版本：" + String(snapshot.identifier.suffix(12))).font(.caption.monospaced())
                }
            } header: { Text("活动规则与诊断") }
        }
        .navigationTitle("过滤来源与规则")
        .navigationBarTitleDisplayMode(.inline)
        .settingsList()
        .onAppear {
            if !loaded { customText = env.settings.contentBlocker.customRules ?? ""; loaded = true }
        }
    }

    private func builtInName(_ id: String) -> String {
        if id == AdBlockBuiltInRules.builtInSourceId { return "基础广告与跟踪过滤" }
        if id == AdBlockBuiltInRules.smoothModeSourceId { return "流畅模式元素隐藏" }
        return "应用推广横幅隐藏"
    }
}
