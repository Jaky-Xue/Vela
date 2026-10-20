//
//  UserScriptsView.swift
//  Vela
//
//  The user-script manager.
//
//  Three install sources: paste, a URL, or a file. Installing resolves the
//  script's `@require` and `@resource` dependencies before it is saved, so the
//  page injection can stay synchronous. The detail screen reports the grants a
//  script asks for and marks the ones this app cannot honour — silently
//  dropping a grant makes a script that half-works look like a bug in the
//  browser.
//

import SwiftUI
import UIKit
import UniformTypeIdentifiers

@MainActor
struct UserScriptsView: View {
    @Environment(AppEnvironment.self) private var env

    @State private var showingInstall = false
    @State private var installSource: InstallSource = .paste
    @State private var pasteText = ""
    @State private var urlText = ""
    @State private var isDownloading = false
    @State private var installError: String?
    @State private var installWarnings: [String] = []
    @State private var showingFilePicker = false
    @State private var pendingDelete: InstalledUserScriptState?
    @State private var checkAllMessage: String?
    /// A transient confirmation that an install succeeded. The sheet dismisses
    /// on success, so without this the only feedback was the script appearing in
    /// the list — which a reinstall of an existing script does not even do.
    @State private var installNotice: String?

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

    private var scripts: [InstalledUserScriptState] { env.userScripts.scripts }

    var body: some View {
        List {
            if let installNotice {
                Section {
                    Label(installNotice, systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                        .font(.footnote.weight(.medium))
                }
            }

            Section {
                Toggle("启用用户脚本", isOn: Binding(
                    get: { env.settings.preferences.userScriptsEnabled },
                    set: { value in env.settings.update { $0.userScriptsEnabled = value } }
                ))
                Toggle(isOn: Binding(
                    get: { env.settings.userScriptSettings.autoUpdateEnabled },
                    set: { value in
                        env.settings.updateUserScriptSettings { $0.autoUpdateEnabled = value }
                    }
                )) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("自动检查更新")
                        Text("启动时检查超过一天的脚本；也可以在列表里手动检查全部。")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            } footer: {
                Text("用户脚本在网页里运行，可以修改页面内容。无痕模式下不会执行任何脚本。")
            }

            if scripts.isEmpty {
                Section {
                    EmptyState(
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
                            UserScriptDetailView(script: script)
                        } label: {
                            row(script)
                        }
                        .contextMenu {
                            Button("检查更新", systemImage: "arrow.clockwise") {
                                Task { await checkUpdate(script) }
                            }
                            Button("删除脚本", systemImage: "trash", role: .destructive) {
                                pendingDelete = script
                            }
                        }
                        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                            Button(role: .destructive) {
                                pendingDelete = script
                            } label: {
                                Label("删除", systemImage: "trash")
                            }
                        }
                    }
                } header: {
                    HStack {
                        Text("\(scripts.count) 个脚本")
                        Spacer()
                        if env.userScripts.isCheckingUpdates {
                            ProgressView()
                                .controlSize(.small)
                        }
                    }
                } footer: {
                    Text("关闭的脚本会保留设置，但不会在页面上运行。左滑或长按可以删除。")
                }
            }

            Section {
                Button("安装新脚本", systemImage: "plus") {
                    resetInstallForm()
                    showingInstall = true
                }
            }

            if let checkAllMessage {
                Section("更新检查") {
                    Text(checkAllMessage)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .browserListSurface()
        .navigationTitle("用户脚本")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    Task { await checkAllUpdates() }
                } label: {
                    Image(systemName: "arrow.triangle.2.circlepath")
                }
                .disabled(scripts.isEmpty || env.userScripts.isCheckingUpdates)
                .accessibilityLabel("检查全部更新")
            }
        }
        .onAppear { env.userScripts.reload() }
        .task(id: installNotice) {
            // Auto-dismiss the success banner. `id` is the notice string, so a
            // second install cancels this task and starts a fresh window rather
            // than the first install's timer clearing the new one early. The
            // cancellation check matters: `try?` around the sleep swallows the
            // CancellationError, so without it the cancelled task would still
            // fall through and clear the newer notice.
            guard installNotice != nil else { return }
            try? await Task.sleep(for: .seconds(4))
            guard !Task.isCancelled else { return }
            installNotice = nil
        }
        .sheet(isPresented: $showingInstall) {
            installSheet
        }
        .alert(
            "删除「\(pendingDelete?.displayName ?? "")」？",
            isPresented: Binding(
                get: { pendingDelete != nil },
                set: { if !$0 { pendingDelete = nil } }
            )
        ) {
            Button("取消", role: .cancel) { pendingDelete = nil }
            Button("删除", role: .destructive) {
                if let script = pendingDelete {
                    env.userScripts.delete(id: script.id)
                }
                pendingDelete = nil
            }
        } message: {
            Text("脚本保存的数据（GM_setValue）也会一起删除。")
        }
    }

    // MARK: - Row

    private func row(_ script: InstalledUserScriptState) -> some View {
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

                if let status = env.userScripts.updateStatus[script.id] {
                    Text(status)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                } else if script.requireUrls.count != script.requireSources.count {
                    Text("缺少 @require 依赖，可在详情中重新下载")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 0)

            Toggle("", isOn: Binding(
                get: { script.enabled },
                set: { value in
                    env.userScripts.setEnabled(value, id: script.id)
                }
            ))
            .labelsHidden()
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
                        Text("Vela 会下载该地址的内容、解析元数据，并把 @require / @resource 一起保存下来。")
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

                if isDownloading || env.userScripts.isInstalling {
                    Section {
                        HStack(spacing: 10) {
                            ProgressView()
                            Text(isDownloading ? "正在下载脚本…" : "正在下载依赖并保存…")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
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
            // The picker is presented from the sheet, not from the list
            // behind it: a presentation asked for by a covered view does not
            // appear, which is why choosing a file did nothing at all.
            .fileImporter(
                isPresented: $showingFilePicker,
                allowedContentTypes: [.javaScript, .plainText, .data],
                allowsMultipleSelection: false
            ) { result in
                handleFileImport(result)
            }
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
                    .disabled(isDownloading || env.userScripts.isInstalling
                        || installSource == .file
                        || (installSource == .paste && pasteText.isEmpty)
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
        isDownloading = false
    }

    private func performInstall() {
        installError = nil
        installWarnings = []

        switch installSource {
        case .paste:
            Task { await install(text: pasteText, source: .paste, sourceUrl: "") }

        case .url:
            let trimmed = urlText.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let url = URL(string: trimmed),
                  url.scheme == "https" || url.scheme == "http" else {
                installError = "请输入一个有效的网址。"
                return
            }
            isDownloading = true
            Task {
                defer { isDownloading = false }
                do {
                    let (data, _) = try await URLSession.shared.data(from: url)
                    guard let text = String(data: data, encoding: .utf8) else {
                        installError = "无法读取该地址的内容。"
                        return
                    }
                    await install(text: text, source: .url, sourceUrl: trimmed)
                } catch {
                    installError = "下载失败：\(error.localizedDescription)"
                }
            }

        case .file:
            break
        }
    }

    private func install(
        text: String,
        source: UserScriptPackageSource,
        sourceUrl: String
    ) async {
        let result = await env.userScripts.install(
            text: text,
            source: source,
            sourceUrl: sourceUrl
        )
        switch result {
        case let .success(outcome):
            installWarnings = outcome.warnings
            if outcome.warnings.isEmpty {
                // A clean install dismisses the sheet, so without this banner the
                // only feedback was the script appearing in the list — which a
                // reinstall of an existing script does not even do.
                installNotice = "已安装「\(outcome.script.displayName)」"
                showingInstall = false
            }
            // With warnings the sheet stays open so the user can read them; the
            // script is installed either way.
        case let .failure(error):
            installError = error.localizedDescription
        }
    }

    private func handleFileImport(_ result: Result<[URL], Error>) {
        switch result {
        case let .success(urls):
            guard let url = urls.first else { return }
            let needsScope = url.startAccessingSecurityScopedResource()
            defer { if needsScope { url.stopAccessingSecurityScopedResource() } }
            do {
                // Files arrive as bytes, not text: a script saved by an editor
                // as UTF-16 or with a byte-order mark used to fail here as if
                // the file were unreadable.
                let data = try Data(contentsOf: url)
                guard let text = String(data: data, encoding: .utf8)
                    ?? String(data: data, encoding: .utf16)
                    ?? String(data: data, encoding: .isoLatin1) else {
                    installError = "无法读取文件：编码不受支持。"
                    return
                }
                Task {
                    await install(text: text, source: .file, sourceUrl: url.absoluteString)
                }
            } catch {
                installError = "无法读取文件：\(error.localizedDescription)"
            }
        case let .failure(error):
            installError = error.localizedDescription
        }
    }

    // MARK: - Updates

    private func checkUpdate(_ script: InstalledUserScriptState) async {
        let result = await env.userScripts.checkForUpdate(script)
        checkAllMessage = "\(script.displayName)：\(result.displayName)"
    }

    private func checkAllUpdates() async {
        checkAllMessage = nil
        let results = await env.userScripts.checkAllUpdates()
        guard !results.isEmpty else {
            checkAllMessage = "没有可检查的脚本。"
            return
        }
        let updated = results.values.filter {
            if case .updated = $0 { return true }
            return false
        }.count
        let failed = results.values.filter {
            if case .failed = $0 { return true }
            return false
        }.count
        checkAllMessage = "已检查 \(results.count) 个脚本：\(updated) 个更新，\(failed) 个失败。"
    }
}

// MARK: - Detail

@MainActor
struct UserScriptDetailView: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.dismiss) private var dismiss

    var script: InstalledUserScriptState

    @State private var showDeleteConfirm = false
    @State private var showEditor = false
    @State private var editedSource = ""
    @State private var isSaving = false
    @State private var isChecking = false
    @State private var isRefreshingDependencies = false
    @State private var editError: String?
    @State private var notice: String?

    private var current: InstalledUserScriptState {
        env.userScripts.script(id: script.id) ?? script
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
                        env.userScripts.setEnabled(value, id: current.id)
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
                    Text("带橙色标记的是华为扩展接口或原生窗口控制，iOS 上没有对应能力；脚本仍可安装，调用时会返回空值。跨域请求、Cookie、下载、打开标签和每标签存储都由 Vela 通过原生桥接提供。")
                } else {
                    Text("这些权限都由 Vela 提供：GM_xmlhttpRequest / GM_fetch 走系统网络层并带上当前网站的 Cookie，GM_cookie 读写 WebKit 的 Cookie 存储，GM_openInTab 和 GM_download 走浏览器自己的标签与下载队列。")
                }
            }

            Section {
                LabeledContent("@require 依赖", value: "\(current.requireUrls.count) 个")
                LabeledContent("@resource 资源", value: "\(current.resourceDeclarations.count) 个")
                if current.requireUrls.count != current.requireSources.count
                    || current.resourceDeclarations.count != current.resources.count {
                    Text("部分依赖没有下载成功，脚本可能缺少函数或资源。")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
                Button {
                    Task { await refreshDependencies() }
                } label: {
                    HStack {
                        if isRefreshingDependencies { ProgressView().controlSize(.small) }
                        Label("重新下载依赖", systemImage: "arrow.triangle.2.circlepath")
                    }
                }
                .disabled(isRefreshingDependencies)
            } header: {
                Text("依赖")
            } footer: {
                Text("@require 会在脚本之前执行；@resource 通过 GM_getResourceText / GM_getResourceURL 读取。")
            }

            Section {
                if let updated = current.lastCheckedAt {
                    LabeledContent("最近检查", value: updated.formatted(date: .abbreviated, time: .shortened))
                }
                if let status = env.userScripts.updateStatus[current.id] {
                    Text(status)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                Button {
                    Task { await checkForUpdate() }
                } label: {
                    HStack {
                        if isChecking { ProgressView().controlSize(.small) }
                        Label("检查更新", systemImage: "arrow.clockwise")
                    }
                }
                .disabled(isChecking || (current.updateUrl.isEmpty
                    && current.downloadUrl.isEmpty
                    && current.sourceUrl.isEmpty))
            } header: {
                Text("更新")
            } footer: {
                if current.updateUrl.isEmpty && current.downloadUrl.isEmpty && current.sourceUrl.isEmpty {
                    Text("这个脚本没有 @updateURL、@downloadURL 或安装地址，无法检查更新。")
                } else {
                    Text("优先使用 @updateURL，其次 @downloadURL，最后使用安装地址。版本号或（无版本号时）代码内容变化才会替换。")
                }
            }

            Section {
                Button("编辑代码", systemImage: "square.and.pencil") {
                    // The stored source is the body alone; the editor needs the
                    // metadata block too, or every save fails to re-parse.
                    editedSource = env.userScripts.editableSource(for: current)
                    showEditor = true
                }
                Button("删除脚本", systemImage: "trash", role: .destructive) {
                    showDeleteConfirm = true
                }
            }

            if let notice {
                Section {
                    Text(notice)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .navigationTitle("脚本详情")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showEditor) {
            editorSheet
        }
        .alert("删除「\(current.displayName)」？", isPresented: $showDeleteConfirm) {
            Button("取消", role: .cancel) {}
            Button("删除", role: .destructive) {
                env.userScripts.delete(id: current.id)
                dismiss()
            }
        } message: {
            Text("脚本保存的数据（GM_setValue）和依赖也会一起删除。")
        }
    }

    private var editorSheet: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if let editError {
                    HStack(alignment: .top, spacing: 8) {
                        Text(editError)
                            .font(.caption)
                            .foregroundStyle(.red)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Button("仍然保存") {
                            saveRawSource()
                        }
                        .font(.caption.weight(.semibold))
                        .buttonStyle(.borderless)
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 6)
                }
                TextEditor(text: $editedSource)
                    .font(.system(size: 12, design: .monospaced))
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    // A flexible height is what makes the whole script reachable:
                    // without it the editor sized to a few lines and the rest of
                    // the source read as cut off, especially on a long script.
                    .frame(maxHeight: .infinity)
                    .scrollContentBackground(.hidden)
                    .padding(.horizontal, 8)
            }
            .navigationTitle("编辑代码")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") {
                        showEditor = false
                        editError = nil
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") {
                        Task { await saveEditedSource() }
                    }
                    .disabled(isSaving)
                }
            }
        }
    }

    private func saveEditedSource() async {
        isSaving = true
        defer { isSaving = false }
        let result = await env.userScripts.saveEditedSource(editedSource, for: current)
        switch result {
        case let .saved(warnings):
            showEditor = false
            editError = nil
            notice = warnings.isEmpty
                ? "脚本已保存。"
                : "脚本已保存，但有以下提示：\n" + warnings.joined(separator: "\n")
        case let .invalid(message, warnings):
            // The editor is a sheet; an alert attached to the screen behind it
            // would not be presented. The banner inside the editor carries the
            // error and the escape hatch.
            editError = warnings.isEmpty
                ? message
                : message + "\n" + warnings.joined(separator: "\n")
        }
    }

    private func saveRawSource() {
        do {
            try env.userScripts.saveRawSource(editedSource, for: current)
            showEditor = false
            editError = nil
            notice = "代码已保存，元数据块仍保持原样。"
        } catch {
            editError = "保存失败：\(error.localizedDescription)"
        }
    }

    private func checkForUpdate() async {
        isChecking = true
        defer { isChecking = false }
        let result = await env.userScripts.checkForUpdate(current)
        notice = result.displayName
    }

    private func refreshDependencies() async {
        isRefreshingDependencies = true
        defer { isRefreshingDependencies = false }
        let warnings = await env.userScripts.refreshDependencies(for: current)
        notice = warnings.isEmpty ? "依赖已更新。" : warnings.joined(separator: "\n")
    }
}
