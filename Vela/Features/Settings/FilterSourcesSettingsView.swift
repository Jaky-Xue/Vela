import SwiftUI

struct FilterSourcesSettingsView: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.browserPalette) private var palette
    @State private var showAddSource = false
    @State private var showRules = false
    @State private var sourceName = ""
    @State private var sourceURL = ""
    @State private var customText = ""
    @State private var message: String?
    private var blocker: ContentBlocker { env.services.contentBlocker }
    private var sources: [FilterSubscription] { env.settings.contentBlocker.subscriptions ?? [] }

    var body: some View {
        List {
            Section("内置规则") {
                ForEach(AdBlockBuiltInRules.filterLists.keys.sorted(), id: \.self) { id in
                    Toggle(builtInName(id), isOn: Binding(
                        get: { !(env.settings.contentBlocker.disabledBuiltIns ?? []).contains(id) },
                        set: { value in Task { await blocker.setBuiltIn(id, enabled: value) } }
                    )).disabled(blocker.isCompiling)
                }
            }
            Section("订阅来源") {
                if sources.isEmpty { Text("暂无订阅").foregroundStyle(palette.secondaryText) }
                ForEach(sources) { source in
                    VStack(alignment: .leading, spacing: 4) {
                        Toggle(source.name, isOn: Binding(get: { source.enabled }, set: { value in
                            Task { await blocker.setSubscription(source.id, enabled: value) }
                        })).disabled(blocker.isCompiling)
                        HStack {
                            Text(source.lastSuccess?.formatted(date: .abbreviated, time: .shortened) ?? "未更新")
                            Spacer()
                            if source.error != nil { Label("使用缓存", systemImage: "exclamationmark.circle") }
                        }.font(.caption).foregroundStyle(palette.secondaryText)
                    }
                    .contextMenu {
                        Text(source.url)
                        Button("移除订阅", role: .destructive) { Task { await blocker.removeSubscription(source.id) } }
                    }
                }
                Button("添加订阅", systemImage: "plus") { sourceName = ""; sourceURL = ""; message = nil; showAddSource = true }
                Button("更新订阅", systemImage: "arrow.clockwise") { Task { await blocker.refreshSubscriptions() } }
                    .disabled(blocker.isCompiling || sources.isEmpty)
            }
            Section("自定义") {
                Button("编辑规则", systemImage: "square.and.pencil") {
                    customText = env.settings.contentBlocker.customRules ?? ""; message = nil; showRules = true
                }
            }
            Section("规则状态") {
                if blocker.isCompiling { ProgressView("处理中…") }
                LabeledContent("网络规则", value: String(blocker.ruleCount - blocker.hiddenRuleCount))
                LabeledContent("隐藏规则", value: String(blocker.hiddenRuleCount))
                if blocker.skippedRuleCount > 0 { LabeledContent("跳过规则", value: String(blocker.skippedRuleCount)) }
                if let error = blocker.lastError {
                    DisclosureGroup("错误详情") { Text(error).font(.footnote) }
                }
            }
            DisclosureGroup("使用说明") {
                Text("订阅使用 HTTPS 纯文本。单份 2 MB，合计 8 MB；失败时保留旧规则。自定义支持 ABP 子集。")
                    .font(.footnote).foregroundStyle(palette.secondaryText)
            }
        }
        .navigationTitle("过滤规则")
        .navigationBarTitleDisplayMode(.inline)
        .settingsList()
        .sheet(isPresented: $showAddSource) { addSourceSheet }
        .sheet(isPresented: $showRules) { ruleSheet }
    }

    private var addSourceSheet: some View {
        NavigationStack {
            List {
                Section {
                    SettingsInputRow(title: "订阅名称", prompt: "例如：常用过滤", text: $sourceName)
                    SettingsInputRow(title: "订阅地址", prompt: "https://example.com/filter.txt", text: $sourceURL, keyboard: .URL)
                }
                if let message { Section { Text(message).font(.footnote).foregroundStyle(.orange) } }
            }
            .settingsList().navigationTitle("添加订阅").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { showAddSource = false } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("添加") { Task {
                        if await blocker.addSubscription(name: sourceName, url: sourceURL) { showAddSource = false }
                        else { message = blocker.lastError }
                    }}.disabled(blocker.isCompiling || sourceURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
    }
    private var ruleSheet: some View {
        NavigationStack {
            List {
                Section("规则内容") {
                    ZStack(alignment: .topLeading) {
                        if customText.isEmpty { Text("例如：||tracker.example^\n##.ad-banner").foregroundStyle(palette.secondaryText).padding(8) }
                        TextEditor(text: $customText).scrollContentBackground(.hidden)
                            .font(.system(.body, design: .monospaced)).frame(minHeight: 260)
                            .textInputAutocapitalization(.never).autocorrectionDisabled()
                            .accessibilityLabel("自定义过滤规则")
                    }
                }
                if let message { Section { Text(message).font(.footnote).foregroundStyle(.orange) } }
            }
            .settingsList().navigationTitle("自定义规则").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { showRules = false } }
                ToolbarItem(placement: .confirmationAction) { Button("保存") { Task {
                    if await blocker.saveCustomRules(customText) { showRules = false } else { message = blocker.lastError }
                }}.disabled(blocker.isCompiling) }
            }
        }
    }
    private func builtInName(_ id: String) -> String {
        if id == AdBlockBuiltInRules.builtInSourceId { return "广告跟踪" }
        if id == AdBlockBuiltInRules.smoothModeSourceId { return "流畅模式" }
        return "推广横幅"
    }
}
