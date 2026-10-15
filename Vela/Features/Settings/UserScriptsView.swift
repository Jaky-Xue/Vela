//
//  UserScriptsView.swift
//  Vela
//
//  The user-script manager. Ported from
//  `AiraBrowser/entry/src/main/ets/app/pages/UserScriptsPage.ets`,
//  `UserScriptDetailPage.ets` and `UserScriptSourceEditPage.ets`
//  (Aira Browser 3.7.4, GPL-3.0).
//
//  Install sources are the three Aira supports: paste, a URL, or a file. The
//  detail screen reports the grants a script asks for and marks the ones Vela
//  cannot honour, which is the honest thing to do — silently dropping a grant
//  makes a script that half-works look like a bug in the browser.
//

import SwiftUI
import UIKit
import UniformTypeIdentifiers

struct UserScriptsView: View {
    @EnvironmentObject private var env: AppEnvironment

    @State private var scripts: [InstalledUserScriptState] = []
    @State private var showingInstall = false
    @State private var installSource: InstallSource = .paste
    @State private var pasteText = ""
    @State private var urlText = ""
    @State private var isImporting = false
    @State private var installError: String?
    @State private var installWarnings: [String] = []
    @State private var showingFilePicker = false

    private enum InstallSource: String, CaseIterable, Identifiable {
        case paste, url, file
        var id: String { rawValue }
        var displayName: String {
            switch self {
            case .paste: return "粘贴代码"
            case .url: return "从网址安装"
            case .file: return "从文件导入"
            }
        }
    }

    var body: some View {
        List {
            Section {
                Toggle("启用用户脚本", isOn: Binding(
                    get: { env.settings.preferences.userScriptsEnabled },
                    set: { value in env.settings.update { $0.userScriptsEnabled = value } }
                ))
            } footer: {
                Text("用户脚本在网页里运行，可以修改页面内容。无痕模式下不会执行任何脚本。")
            }

            if scripts.isEmpty {
                Section {
                    BrowserEmptyState(
                        systemImage: "curlybraces",
                        title: "还没有用户脚本",
                        message: "脚本可以给网页加功能，例如去除浮窗、增强阅读体验。"
                    )
                    .listRowBackground(Color.clear)
                }
            } else {
                Section {
                    ForEach(scripts) { script in
                        NavigationLink {
                            UserScriptDetailView(script: script, onChanged: reload)
                        } label: {
                            HStack(spacing: 12) {
                                Image(systemName: "curlybraces")
                                    .font(.system(size: 14, weight: .semibold))
                                    .foregroundStyle(.white)
                                    .frame(width: 28, height: 28)
                                    .background(Color.orange, in: RoundedRectangle(cornerRadius: 7, style: .continuous))

                                VStack(alignment: .leading, spacing: 2) {
                                    Text(script.displayName)
                                        .lineLimit(1)
                                    HStack(spacing: 5) {
                                        if !script.version.isEmpty {
                                            Text("v\(script.version)")
                                        }
                                        if script.hasUnsupportedGrants {
                                            Text("· 部分功能不可用")
                                                .foregroundStyle(.orange)
                                        }
                                        Text("· \(script.matches.count + script.includes.count) 条匹配规则")
                                    }
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                                }

                                Spacer(minLength: 0)

                                Toggle("", isOn: Binding(
                                    get: { script.enabled },
                                    set: { value in
                                        try? env.userScripts.setEnabled(value, id: script.id)
                                        reload()
                                    }
                                ))
                                .labelsHidden()
                            }
                        }
                    }
                    .onDelete { offsets in
                        for index in offsets {
                            try? env.userScripts.remove(id: scripts[index].id)
                        }
                        reload()
                    }
                } header: {
                    Text("\(scripts.count) 个脚本")
                } footer: {
                    Text("关闭的脚本会保留设置，但不会在页面上运行。")
                }
            }

            Section {
                Button("安装新脚本", systemImage: "plus") {
                    resetInstallForm()
                    showingInstall = true
                }
            }
        }
        .navigationTitle("用户脚本")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear(perform: reload)
        .sheet(isPresented: $showingInstall) {
            installSheet
        }
        .fileImporter(
            isPresented: $showingFilePicker,
            allowedContentTypes: [.javascript, .plainText, .data],
            allowsMultipleSelection: false
        ) { result in
            handleFileImport(result)
        }
    }

    // MARK: - Install

    private var installSheet: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("来源", selection: $installSource) {
                        ForEach(InstallSource.allCases) { source in
                            Text(source.displayName).tag(source)
                        }
                    }
                    .pickerStyle(.segmented)
                }

                switch installSource {
                case .paste:
                    Section {
                        TextEditor(text: $pasteText)
                            .font(.system(size: 12, design: .monospaced))
                            .frame(minHeight: 180)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                    } header: {
                        Text("脚本代码")
                    } footer: {
                        Text("粘贴完整的用户脚本，包括开头的 // ==UserScript== 元数据块。")
                    }

                case .url:
                    Section {
                        TextField("https://example.com/script.user.js", text: $urlText)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .keyboardType(.URL)
                    } footer: {
                        Text("Vela 会下载该地址的内容并解析元数据。")
                    }

                case .file:
                    Section {
                        Button("选择 .user.js 文件", systemImage: "doc.badge.plus") {
                            showingFilePicker = true
                        }
                    } footer: {
                        Text("也可以把脚本文件放到「文件」App 里，再从 Vela 导入。")
                    }
                }

                if let installError {
                    Section {
                        Label(installError, systemImage: "exclamationmark.triangle")
                            .font(.footnote)
                            .foregroundStyle(.red)
                    }
                }

                if !installWarnings.isEmpty {
                    Section("提示") {
                        ForEach(installWarnings, id: \.self) { warning in
                            Text(warning)
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .navigationTitle("安装用户脚本")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") {
                        showingInstall = false
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("安装") {
                        performInstall()
                    }
                    .disabled(installSource == .file || (installSource == .paste && pasteText.isEmpty)
                        || (installSource == .url && urlText.isEmpty))
                }
            }
        }
    }

    private func resetInstallForm() {
        pasteText = ""
        urlText = ""
        installError = nil
        installWarnings = []
    }

    private func performInstall() {
        installError = nil
        installWarnings = []

        switch installSource {
        case .paste:
            install(text: pasteText, source: .paste, sourceUrl: "")

        case .url:
            let trimmed = urlText.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let url = URL(string: trimmed),
                  url.scheme == "https" || url.scheme == "http" else {
                installError = "请输入一个有效的网址。"
                return
            }
            Task {
                do {
                    let (data, _) = try await URLSession.shared.data(from: url)
                    guard let text = String(data: data, encoding: .utf8) else {
                        installError = "无法读取该地址的内容。"
                        return
                    }
                    install(text: text, source: .url, sourceUrl: trimmed)
                } catch {
                    installError = "下载失败：\(error.localizedDescription)"
                }
            }

        case .file:
            break
        }
    }

    private func install(text: String, source: UserScriptPackageSource, sourceUrl: String) {
        let result = UserScriptParser.parse(text, installSource: source, sourceUrl: sourceUrl)
        installWarnings = result.warnings

        guard result.valid, let candidate = result.candidate else {
            installError = result.errorMessage
            return
        }

        // An update replaces the existing script in place rather than adding a
        // second copy. Identity is name plus namespace, which is what the
        // userscript metadata convention uses.
        let existing = scripts.first {
            $0.name == candidate.name && $0.namespace == candidate.namespace
        }

        var script = InstalledUserScriptState(candidate: candidate)
        if let existing {
            script.id = existing.id
            script.createdAt = existing.createdAt
        }

        do {
            try env.userScripts.upsert(script)
            reload()
            showingInstall = false
        } catch {
            installError = "安装失败：\(error.localizedDescription)"
        }
    }

    private func handleFileImport(_ result: Result<[URL], Error>) {
        switch result {
        case let .success(urls):
            guard let url = urls.first else { return }
            // A file chosen through the picker is outside the sandbox, so access
            // has to be requested explicitly and released afterwards.
            let needsScope = url.startAccessingSecurityScopedResource()
            defer { if needsScope { url.stopAccessingSecurityScopedResource() } }
            do {
                let text = try String(contentsOf: url, encoding: .utf8)
                install(text: text, source: .file, sourceUrl: url.absoluteString)
            } catch {
                installError = "无法读取文件：\(error.localizedDescription)"
            }
        case let .failure(error):
            installError = error.localizedDescription
        }
    }

    private func reload() {
        scripts = (try? env.userScripts.allScripts()) ?? []
    }
}

// MARK: - Detail

struct UserScriptDetailView: View {
    @EnvironmentObject private var env: AppEnvironment
    @Environment(\.dismiss) private var dismiss

    var script: InstalledUserScriptState
    var onChanged: () -> Void

    @State private var showDeleteConfirm = false
    @State private var isEditing = false
    @State private var editedSource: String = ""

    private var current: InstalledUserScriptState {
        (try? env.userScripts.script(id: script.id)) ?? script
    }

    var body: some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: 6) {
                    Text(current.displayName)
                        .font(.title3.weight(.semibold))
                    if !current.description.isEmpty {
                        Text(current.description)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    HStack(spacing: 8) {
                        if !current.version.isEmpty {
                            Label("v\(current.version)", systemImage: "number")
                        }
                        if !current.namespace.isEmpty {
                            Label(current.namespace, systemImage: "shippingbox")
                        }
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
                .padding(.vertical, 4)

                Toggle("启用", isOn: Binding(
                    get: { current.enabled },
                    set: { value in
                        try? env.userScripts.setEnabled(value, id: current.id)
                        onChanged()
                    }
                ))
            }

            Section {
                if current.matches.isEmpty && current.includes.isEmpty {
                    Text("没有匹配规则")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(current.matches, id: \.self) { pattern in
                        Label(pattern, systemImage: "link")
                            .font(.system(size: 12, design: .monospaced))
                    }
                    ForEach(current.includes, id: \.self) { pattern in
                        Label(pattern, systemImage: "text.magnifyingglass")
                            .font(.system(size: 12, design: .monospaced))
                    }
                }
            } header: {
                Text("运行于")
            }

            if !current.excludes.isEmpty || !current.excludeMatches.isEmpty {
                Section("排除") {
                    ForEach(current.excludeMatches + current.excludes, id: \.self) { pattern in
                        Text(pattern)
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Section {
                LabeledContent("运行时机", value: current.runAt.displayName)
                if current.noframes {
                    LabeledContent("作用范围", value: "仅顶层框架")
                }
            }

            Section {
                if current.grants.isEmpty || current.grants == [.none] {
                    Text("没有申请特殊权限")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(current.grants, id: \.self) { grant in
                        HStack {
                            Text(grant.rawValue)
                                .font(.system(size: 12, design: .monospaced))
                            Spacer()
                            if grant.isSupportedByVela {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundStyle(.green)
                            } else {
                                Image(systemName: "xmark.circle.fill")
                                    .foregroundStyle(.orange)
                            }
                        }
                    }
                }
            } header: {
                Text("申请的权限")
            } footer: {
                if current.hasUnsupportedGrants {
                    Text("带橙色标记的权限在 iOS 上不可用：WebKit 不允许注入的脚本直接发起跨域请求、读取 Cookie 或下载文件。脚本仍然可以安装和运行，只是调用这些接口时会返回空值。")
                } else {
                    Text("这些权限都由 Vela 提供。")
                }
            }

            if let updated = current.lastCheckedAt {
                Section {
                    LabeledContent("最近检查更新", value: updated.formatted(date: .abbreviated, time: .shortened))
                }
            }

            Section {
                Button("编辑代码", systemImage: "square.and.pencil") {
                    editedSource = current.source
                    isEditing = true
                }
                if !current.updateUrl.isEmpty || !current.downloadUrl.isEmpty {
                    Button("检查更新", systemImage: "arrow.clockwise") {
                        Task { await checkForUpdate() }
                    }
                }
                Button("删除脚本", systemImage: "trash", role: .destructive) {
                    showDeleteConfirm = true
                }
            }
        }
        .navigationTitle("脚本详情")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $isEditing) {
            NavigationStack {
                TextEditor(text: $editedSource)
                    .font(.system(size: 12, design: .monospaced))
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .navigationTitle("编辑代码")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("取消") { isEditing = false }
                        }
                        ToolbarItem(placement: .confirmationAction) {
                            Button("保存") {
                                saveEditedSource()
                                isEditing = false
                            }
                        }
                    }
            }
        }
        .alert("删除「\(current.displayName)」？", isPresented: $showDeleteConfirm) {
            Button("取消", role: .cancel) {}
            Button("删除", role: .destructive) {
                try? env.userScripts.remove(id: current.id)
                onChanged()
                dismiss()
            }
        } message: {
            Text("脚本保存的数据也会一起删除。")
        }
    }

    /// Re-parses the edited source so a changed metadata block takes effect.
    ///
    /// Editing the body alone keeps the metadata; editing the block updates the
    /// matches too, which is what a user who pasted a modified script expects.
    private func saveEditedSource() {
        let result = UserScriptParser.parse(
            editedSource,
            installSource: current.installSource.packageSource,
            sourceUrl: current.sourceUrl
        )
        guard result.valid, var candidate = result.candidate else {
            // An unparseable edit still saves the body: the user may be mid-edit
            // and losing the whole script would be worse than a stale block.
            var updated = current
            updated.source = editedSource
            updated.updatedAt = Date()
            try? env.userScripts.upsert(updated)
            onChanged()
            return
        }

        candidate.installSource = current.installSource.packageSource
        var updated = InstalledUserScriptState(candidate: candidate)
        updated.id = current.id
        updated.createdAt = current.createdAt
        updated.enabled = current.enabled
        updated.updatedAt = Date()
        try? env.userScripts.upsert(updated)
        onChanged()
    }

    private func checkForUpdate() async {
        let urlString = current.updateUrl.isEmpty ? current.downloadUrl : current.updateUrl
        guard let url = URL(string: urlString) else { return }
        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            guard let text = String(data: data, encoding: .utf8) else { return }
            let result = UserScriptParser.parse(text, installSource: .url, sourceUrl: urlString)
            guard result.valid, let candidate = result.candidate else { return }

            // Only replace when the remote version is actually different, so a
            // script without a version does not get rewritten on every check.
            guard candidate.version != current.version || !current.version.isEmpty else { return }

            var updated = InstalledUserScriptState(candidate: candidate)
            updated.id = current.id
            updated.createdAt = current.createdAt
            updated.lastCheckedAt = Date()
            try? env.userScripts.upsert(updated)
            onChanged()
        } catch {
            // A failed update check is not worth interrupting the user for.
        }
    }
}
