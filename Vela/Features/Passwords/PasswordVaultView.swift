//
//  PasswordVaultView.swift
//  Vela
//
//  The password vault: a biometric lock, the saved logins behind it, the
//  editor, and the one-page handoff that fills a login form.
//
//  The vault is a list because a password manager is used by finding a site,
//  not by browsing a hierarchy. Every row can be copied, filled into the page
//  behind the sheet, edited or deleted; the detail screen exists for the two
//  things a row has no room for — revealing the password and reading notes.
//

import SwiftUI
import UIKit
import WebKit

struct PasswordVaultView: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.browserPalette) private var palette

    @State private var searchText = ""
    @State private var selectedCredential: VaultCredential?
    @State private var editingCredential: VaultCredential?
    @State private var isUnlocking = false
    @State private var notice: String?
    @State private var confirmDeleteAll = false

    private var credentials: [VaultCredential] { env.passwords.credentials }

    private var filteredCredentials: [VaultCredential] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return credentials }
        return credentials.filter { credential in
            credential.title.localizedCaseInsensitiveContains(query)
                || credential.host.localizedCaseInsensitiveContains(query)
                || credential.username.localizedCaseInsensitiveContains(query)
        }
    }

    /// The page behind the vault, when it has a login form worth filling.
    private var pageHost: String? {
        guard let tab = env.tabManager.activeTab, !tab.isHome else { return nil }
        return URL(string: tab.url)?.host
    }

    private var pageWebView: WKWebView? {
        guard let tab = env.tabManager.activeTab, !tab.isHome else { return nil }
        return env.tabManager.webView(for: tab.id)
    }

    var body: some View {
        Group {
            if env.passwords.isUnlocked {
                unlockedContent
            } else {
                lockedContent
            }
        }
        .navigationTitle("密码与保险箱")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            if !env.passwords.isUnlocked {
                await requestUnlock()
            }
        }
        .sheet(item: $selectedCredential) { credential in
            PasswordDetailView(credential: credential, pageHost: pageHost) {
                // A deleted detail leaves nothing to keep selected.
                selectedCredential = nil
            }
        }
        .sheet(item: $editingCredential) { credential in
            PasswordEditorView(credential: credential) { saved in
                editingCredential = nil
                if let saved {
                    notice = "已保存「\(saved.title)」"
                }
            }
        }
        .alert(
            notice ?? "",
            isPresented: Binding(
                get: { notice != nil },
                set: { if !$0 { notice = nil } }
            )
        ) {
            Button("好") { notice = nil }
        }
        .alert("删除保险箱中的全部密码？", isPresented: $confirmDeleteAll) {
            Button("全部删除", role: .destructive) {
                do {
                    try env.passwords.deleteAll()
                    notice = "保险箱已清空"
                } catch {
                    notice = error.localizedDescription
                }
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("此操作无法撤销，钥匙串中的条目会被永久删除。")
        }
    }

    // MARK: - Locked

    private var lockedContent: some View {
        VStack(spacing: BrowserSpacing.regular) {
            Spacer(minLength: 0)

            ZStack {
                Circle()
                    .fill(palette.accent.opacity(0.14))
                    .frame(width: 92, height: 92)
                Image(systemName: "lock.fill")
                    .font(.system(size: 34, weight: .semibold))
                    .foregroundStyle(palette.accent)
            }

            VStack(spacing: 6) {
                Text("保险箱已锁定")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(palette.primaryText)
                Text("密码保存在 iOS 钥匙串中，只在解锁后读取。")
                    .font(.subheadline)
                    .foregroundStyle(palette.secondaryText)
                    .multilineTextAlignment(.center)
            }

            if let error = env.passwords.lastError {
                Text(error)
                    .font(.footnote)
                    .foregroundStyle(.red)
            }

            Button {
                Task { @MainActor in await requestUnlock() }
            } label: {
                HStack(spacing: 8) {
                    if isUnlocking {
                        ProgressView()
                            .tint(.white)
                    } else {
                        Image(systemName: "faceid")
                    }
                    Text(isUnlocking ? "验证中…" : "解锁保险箱")
                }
                .font(.system(size: 15, weight: .semibold))
                .frame(maxWidth: 260, minHeight: 46)
            }
            .buttonStyle(.borderedProminent)
            .disabled(isUnlocking)

            Text("使用面容 ID、触控 ID 或设备密码")
                .font(.caption2)
                .foregroundStyle(palette.secondaryText)

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 28)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .browserSurfaceBackground(opacity: 0.30)
    }

    private func requestUnlock() async {
        guard !isUnlocking else { return }
        isUnlocking = true
        await env.passwords.unlock()
        isUnlocking = false
    }

    // MARK: - Unlocked

    private var unlockedContent: some View {
        Group {
            if credentials.isEmpty {
                EmptyState(
                    systemImage: "key",
                    title: "还没有保存密码",
                    message: "点右上角的加号新建一条，或在网页登录后打开这里保存当前登录信息。",
                    actionTitle: "添加密码",
                    action: { startNewCredential() }
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .browserSurfaceBackground(opacity: 0.30)
            } else {
                listContent
            }
        }
        .searchable(text: $searchText, placement: .navigationBarDrawer(displayMode: .automatic), prompt: "搜索网站或用户名")
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Menu {
                    if let pageHost, !pageHost.isEmpty, pageWebView != nil {
                        Button("保存当前页面的登录信息", systemImage: "square.and.arrow.down") {
                            captureCurrentLogin()
                        }
                    }
                    Button("锁定保险箱", systemImage: "lock") {
                        env.passwords.lock()
                    }
                    Button("删除全部密码", systemImage: "trash", role: .destructive) {
                        confirmDeleteAll = true
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .accessibilityLabel("更多")
            }
            ToolbarItem(placement: .confirmationAction) {
                Button {
                    startNewCredential()
                } label: {
                    Image(systemName: "plus")
                }
                .accessibilityLabel("添加密码")
            }
        }
    }

    private var listContent: some View {
        List {
            Section {
                ForEach(filteredCredentials) { credential in
                    Button {
                        selectedCredential = credential
                    } label: {
                        credentialRow(credential)
                    }
                    .buttonStyle(.plain)
                    .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                        Button("删除", role: .destructive) {
                            delete(credential)
                        }
                        Button("编辑") {
                            editingCredential = credential
                        }
                        .tint(.blue)
                    }
                    .swipeActions(edge: .leading, allowsFullSwipe: true) {
                        if canFill(credential) {
                            Button("填充") {
                                fill(credential)
                            }
                            .tint(.green)
                        }
                    }
                    .contextMenu {
                        Button("复制用户名", systemImage: "person.crop.circle") {
                            UIPasteboard.general.string = credential.username
                            notice = "用户名已复制"
                        }
                        Button("复制密码", systemImage: "key") {
                            UIPasteboard.general.string = credential.password
                            notice = "密码已复制"
                        }
                        if canFill(credential) {
                            Button("填充到当前网页", systemImage: "rectangle.and.pencil.and.ellipsis") {
                                fill(credential)
                            }
                        }
                        Button("编辑", systemImage: "pencil") {
                            editingCredential = credential
                        }
                        Button("删除", systemImage: "trash", role: .destructive) {
                            delete(credential)
                        }
                    }
                }
            } footer: {
                Text("密码只保存在本机钥匙串中，使用面容 ID / 触控 ID 或设备密码解锁，不会同步到其他设备。")
            }

            Section {
                Toggle("打开保险箱时验证身份", isOn: Binding(
                    get: { env.settings.preferences.vaultRequireBiometrics ?? true },
                    set: { value in env.settings.update { $0.vaultRequireBiometrics = value } }
                ))
            } footer: {
                Text("关闭后，打开保险箱不再要求面容 ID / 触控 ID 或设备密码；条目仍然只存放在钥匙串中。")
            }
        }
        .listStyle(.insetGrouped)
        .browserListSurface(rowsAreCards: true)
    }

    private func credentialRow(_ credential: VaultCredential) -> some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(palette.accent.opacity(0.14))
                Image(systemName: "key.fill")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(palette.accent)
            }
            .frame(width: 34, height: 34)

            VStack(alignment: .leading, spacing: 2) {
                Text(credential.title)
                    .font(.body)
                    .foregroundStyle(palette.primaryText)
                    .lineLimit(1)
                Text(credential.username.isEmpty ? credential.host : "\(credential.host) · \(credential.username)")
                    .font(.caption)
                    .foregroundStyle(palette.secondaryText)
                    .lineLimit(1)
            }

            Spacer(minLength: 6)

            if canFill(credential) {
                Image(systemName: "rectangle.and.pencil.and.ellipsis")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(palette.accent)
            }
            Image(systemName: "chevron.right")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(palette.secondaryText.opacity(0.6))
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
    }

    // MARK: - Actions

    private func startNewCredential() {
        editingCredential = VaultCredential(
            title: "",
            host: pageHost ?? "",
            username: "",
            password: ""
        )
    }

    private func canFill(_ credential: VaultCredential) -> Bool {
        guard let pageHost, pageWebView != nil else { return false }
        return credential.matches(host: pageHost)
    }

    private func fill(_ credential: VaultCredential) {
        guard let webView = pageWebView else { return }
        Task { @MainActor in
            let success = await env.passwords.fill(credential, in: webView)
            notice = success ? "已填充到当前网页" : "这个页面没有找到可填充的登录表单"
        }
    }

    private func captureCurrentLogin() {
        guard let webView = pageWebView else { return }
        Task { @MainActor in
            guard let captured = await env.passwords.captureCredentials(from: webView) else {
                notice = "没有找到已填写的登录表单"
                return
            }
            let host = pageHost ?? ""
            let title = env.tabManager.activeTab?.title ?? VaultCredential.fallbackTitle(for: host)
            editingCredential = VaultCredential(
                title: title.isEmpty ? VaultCredential.fallbackTitle(for: host) : title,
                host: host,
                username: captured.username,
                password: captured.password
            )
        }
    }

    private func delete(_ credential: VaultCredential) {
        do {
            try env.passwords.delete(id: credential.id)
            notice = "已删除「\(credential.title)」"
            if selectedCredential?.id == credential.id {
                selectedCredential = nil
            }
        } catch {
            notice = error.localizedDescription
        }
    }
}

// MARK: - Detail

struct PasswordDetailView: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.browserPalette) private var palette
    @Environment(\.dismiss) private var dismiss

    var pageHost: String?
    /// Called when the credential behind this screen changed or disappeared.
    var onChanged: () -> Void

    @State private var record: VaultCredential
    @State private var revealed = false
    @State private var editing: VaultCredential?
    @State private var notice: String?

    init(credential: VaultCredential, pageHost: String?, onChanged: @escaping () -> Void) {
        self.pageHost = pageHost
        self.onChanged = onChanged
        _record = State(initialValue: credential)
    }

    private var webView: WKWebView? {
        guard let tab = env.tabManager.activeTab, !tab.isHome else { return nil }
        return env.tabManager.webView(for: tab.id)
    }

    private var canFill: Bool {
        guard let pageHost, webView != nil else { return false }
        return record.matches(host: pageHost)
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    detailRow(label: "用户名", value: record.username.isEmpty ? "—" : record.username) {
                        copy(record.username, message: "用户名已复制")
                    }

                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text("密码")
                                .font(.caption)
                                .foregroundStyle(palette.secondaryText)
                            Spacer()
                            Button {
                                revealed.toggle()
                            } label: {
                                Image(systemName: revealed ? "eye.slash" : "eye")
                            }
                            .buttonStyle(.plain)
                            .foregroundStyle(palette.secondaryText)
                            .accessibilityLabel(revealed ? "隐藏密码" : "显示密码")

                            Button {
                                copy(record.password, message: "密码已复制")
                            } label: {
                                Image(systemName: "doc.on.doc")
                            }
                            .buttonStyle(.plain)
                            .foregroundStyle(palette.accent)
                            .accessibilityLabel("复制密码")
                        }
                        Text(revealed ? record.password : String(repeating: "•", count: 12))
                            .font(.system(revealed ? .body : .title3, design: .monospaced))
                            .foregroundStyle(palette.primaryText)
                            .textSelection(.enabled)
                    }
                    .padding(.vertical, 4)

                    detailRow(label: "网站", value: record.host) {
                        copy(record.host, message: "网站地址已复制")
                    }
                }

                if !record.notes.isEmpty {
                    Section("备注") {
                        Text(record.notes)
                            .foregroundStyle(palette.primaryText)
                    }
                }

                Section {
                    if canFill {
                        Button {
                            fill()
                        } label: {
                            Label("填充到当前网页", systemImage: "rectangle.and.pencil.and.ellipsis")
                        }
                    }
                    Button {
                        editing = record
                    } label: {
                        Label("编辑", systemImage: "pencil")
                    }
                    Button(role: .destructive) {
                        delete()
                    } label: {
                        Label("删除密码", systemImage: "trash")
                    }
                } footer: {
                    Text("创建于 \(record.createdAt.formatted(date: .abbreviated, time: .shortened))")
                }
            }
            .listStyle(.insetGrouped)
            .browserListSurface(rowsAreCards: true)
            .navigationTitle(record.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                }
            }
            .sheet(item: $editing) { draft in
                PasswordEditorView(credential: draft) { saved in
                    editing = nil
                    if let saved {
                        record = env.passwords.credential(id: saved.id) ?? saved
                        onChanged()
                    }
                }
            }
            .alert(
                notice ?? "",
                isPresented: Binding(
                    get: { notice != nil },
                    set: { if !$0 { notice = nil } }
                )
            ) {
                Button("好") { notice = nil }
            }
        }
        .browserAmbientSheet()
    }

    private func detailRow(label: String, value: String, action: @escaping () -> Void) -> some View {
        HStack {
            Text(label)
                .font(.caption)
                .foregroundStyle(palette.secondaryText)
            Spacer()
            Text(value)
                .foregroundStyle(palette.primaryText)
                .lineLimit(1)
            Button(action: action) {
                Image(systemName: "doc.on.doc")
            }
            .buttonStyle(.plain)
            .foregroundStyle(palette.accent)
            .accessibilityLabel("复制\(label)")
        }
    }

    private func copy(_ value: String, message: String) {
        guard !value.isEmpty else { return }
        UIPasteboard.general.string = value
        notice = message
    }

    private func fill() {
        guard let webView else { return }
        Task { @MainActor in
            let success = await env.passwords.fill(record, in: webView)
            notice = success ? "已填充到当前网页" : "这个页面没有找到可填充的登录表单"
        }
    }

    private func delete() {
        do {
            try env.passwords.delete(id: record.id)
            onChanged()
            dismiss()
        } catch {
            notice = error.localizedDescription
        }
    }
}

// MARK: - Editor

struct PasswordEditorView: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.browserPalette) private var palette
    @Environment(\.dismiss) private var dismiss

    /// Called with the saved record, or nil when the editor was dismissed.
    var onFinish: (VaultCredential?) -> Void

    @State private var record: VaultCredential
    @State private var revealed = false
    @State private var errorMessage: String?
    @State private var isSaving = false

    init(credential: VaultCredential, onFinish: @escaping (VaultCredential?) -> Void) {
        self.onFinish = onFinish
        _record = State(initialValue: credential)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("名称（如 GitHub）", text: $record.title)
                    TextField("网站（如 github.com）", text: $record.host)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                    TextField("用户名或邮箱", text: $record.username)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.emailAddress)
                }

                Section {
                    HStack {
                        if revealed {
                            TextField("密码", text: $record.password)
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                        } else {
                            SecureField("密码", text: $record.password)
                        }

                        Button {
                            revealed.toggle()
                        } label: {
                            Image(systemName: revealed ? "eye.slash" : "eye")
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(palette.secondaryText)
                        .accessibilityLabel(revealed ? "隐藏密码" : "显示密码")
                    }

                    Button {
                        record.password = env.passwords.generatePassword()
                        revealed = true
                    } label: {
                        Label("生成一个强密码", systemImage: "wand.and.stars")
                    }
                } header: {
                    Text("密码")
                } footer: {
                    if let errorMessage {
                        Text(errorMessage)
                            .foregroundStyle(.red)
                    } else {
                        Text("保存后，密码只写入 iOS 钥匙串，不进入设置或数据库。")
                    }
                }

                Section("备注") {
                    TextField("可选", text: $record.notes, axis: .vertical)
                        .lineLimit(2...5)
                }
            }
            .navigationTitle(existing ? "编辑密码" : "新建密码")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") {
                        onFinish(nil)
                        dismiss()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") { save() }
                        .disabled(isSaving)
                }
            }
        }
        .browserAmbientSheet()
    }

    private var existing: Bool {
        env.passwords.credential(id: record.id) != nil
    }

    private func save() {
        let host = VaultCredential.normalizeHost(record.host)
        guard !host.isEmpty else {
            errorMessage = "请填写网站地址。"
            return
        }
        guard !record.password.isEmpty else {
            errorMessage = "密码不能为空。"
            return
        }

        record.host = host
        if record.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            record.title = VaultCredential.fallbackTitle(for: host)
        }

        isSaving = true
        do {
            try env.passwords.save(record)
            isSaving = false
            onFinish(record)
            dismiss()
        } catch {
            isSaving = false
            errorMessage = error.localizedDescription
        }
    }
}
