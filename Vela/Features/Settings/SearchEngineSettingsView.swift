//
//  SearchEngineSettingsView.swift
//  Vela
//
//  Choosing the default engine, the omnibox alternatives, and custom engines.
//

import SwiftUI
import UIKit

// MARK: - Search engines

struct SearchEngineSettingsView: View {
    @Environment(AppEnvironment.self) private var env

    @State private var showingCustomEngineForm = false
    @State private var editingEngine: SearchEngineRecord?

    var body: some View {
        List {
            Section("默认搜索引擎") {
                ForEach(env.settings.preferences.searchEngine.selectableEngines) { engine in
                    Button {
                        env.settings.setDefaultSearchEngine(id: engine.id)
                    } label: {
                        HStack {
                            Text(engine.name)
                                .foregroundStyle(.primary)
                            Spacer()
                            if env.settings.preferences.searchEngine.defaultSearchEngineId == engine.id {
                                Image(systemName: "checkmark")
                                    .foregroundStyle(.tint)
                            }
                        }
                    }
                }
            }

            Section {
                ForEach(BuiltInSearchEngineId.allCases) { engine in
                    let option = searchEngineOptions.first { $0.id == engine.rawValue }
                    Toggle(isOn: Binding(
                        get: {
                            env.settings.preferences.searchEngine.enabledBuiltInEngineIds.contains(engine.rawValue)
                        },
                        set: { enabled in
                            env.settings.setSearchEngineEnabled(enabled, id: engine)
                        }
                    )) {
                        Text(option?.name ?? engine.rawValue)
                    }
                }
            } header: {
                Text("在地址栏中可切换的引擎")
            } footer: {
                Text("关闭的引擎不出现在地址栏的切换列表里。")
            }

            Section {
                ForEach(env.settings.preferences.searchEngine.customEngines) { engine in
                    Button {
                        editingEngine = engine
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(engine.name)
                                .foregroundStyle(.primary)
                            Text(engine.searchUrlTemplate)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                }
                .onDelete { offsets in
                    for index in offsets {
                        env.settings.removeCustomSearchEngine(
                            id: env.settings.preferences.searchEngine.customEngines[index].id
                        )
                    }
                }

                Button("添加自定义引擎", systemImage: "plus") {
                    showingCustomEngineForm = true
                }
            } header: {
                Text("自定义引擎")
            } footer: {
                Text("网址模板中用 {searchTerms} 表示搜索词。")
            }

            Section {
                Toggle("显示搜索建议", isOn: Binding(
                    get: { env.settings.preferences.searchEngine.searchSuggestions.regularEnabled },
                    set: { value in
                        env.settings.update { $0.searchEngine.searchSuggestions.regularEnabled = value }
                    }
                ))
                Toggle("历史与书签建议", isOn: Binding(
                    get: { env.settings.preferences.searchEngine.searchSuggestions.browsingHistoryEnabled },
                    set: { value in
                        env.settings.update { $0.searchEngine.searchSuggestions.browsingHistoryEnabled = value }
                    }
                ))
                Toggle("已打开标签页建议", isOn: Binding(
                    get: { env.settings.preferences.searchEngine.searchSuggestions.openTabsEnabled },
                    set: { value in
                        env.settings.update { $0.searchEngine.searchSuggestions.openTabsEnabled = value }
                    }
                ))
                Toggle("联网搜索推荐", isOn: Binding(
                    get: { env.settings.preferences.searchEngine.searchSuggestions.remoteEnabled },
                    set: { value in
                        env.settings.update { $0.searchEngine.searchSuggestions.remoteEnabled = value }
                    }
                ))
            } header: {
                Text("搜索建议")
            } footer: {
                Text("关闭后地址栏不再显示任何建议。联网搜索推荐会在输入时向当前搜索引擎请求建议；无痕标签页始终只用本地记录，不会发出请求。")
            }
        }
        .navigationTitle("搜索引擎")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showingCustomEngineForm) {
            CustomSearchEngineForm(engine: nil) { engine in
                env.settings.addCustomSearchEngine(engine)
            }
        }
        .sheet(item: $editingEngine) { engine in
            CustomSearchEngineForm(engine: engine) { updated in
                env.settings.removeCustomSearchEngine(id: engine.id)
                env.settings.addCustomSearchEngine(updated)
            }
        }
    }
}

private struct CustomSearchEngineForm: View {
    @Environment(\.dismiss) private var dismiss

    var engine: SearchEngineRecord?
    var onSave: (SearchEngineRecord) -> Void

    @State private var name: String
    @State private var template: String
    @State private var homepage: String

    init(engine: SearchEngineRecord?, onSave: @escaping (SearchEngineRecord) -> Void) {
        self.engine = engine
        self.onSave = onSave
        _name = State(initialValue: engine?.name ?? "")
        _template = State(initialValue: engine?.searchUrlTemplate ?? "https://example.com/search?q={searchTerms}")
        _homepage = State(initialValue: engine?.homepageUrl ?? "")
    }

    private var isValid: Bool {
        !name.trimmingCharacters(in: .whitespaces).isEmpty && template.contains("{searchTerms}")
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("名称") {
                    TextField("例如：站内搜索", text: $name)
                }
                Section {
                    TextField("网址模板", text: $template)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                } header: {
                    Text("网址模板")
                } footer: {
                    Text("用 {searchTerms} 表示搜索词。")
                }
                Section("主页（可选）") {
                    TextField("https://example.com", text: $homepage)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                }
            }
            .navigationTitle(engine == nil ? "添加搜索引擎" : "编辑搜索引擎")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") {
                        onSave(
                            SearchEngineRecord(
                                id: engine?.id ?? "custom-\(UUID().uuidString)",
                                kind: .custom,
                                name: name,
                                searchUrlTemplate: template,
                                homepageUrl: homepage,
                                isEditable: true,
                                position: engine?.position ?? 0
                            )
                        )
                        dismiss()
                    }
                    .disabled(!isValid)
                }
            }
        }
    }
}
