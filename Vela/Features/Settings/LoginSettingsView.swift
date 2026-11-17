//
//  LoginSettingsView.swift
//  Vela
//
//  设置 ▸ 账号 ▸ 登录.
//
//  One screen for every provider, because a person signs in to Google and
//  Apple for the same reason and should not have to remember which settings
//  page holds which.
//
//  Two facts live side by side and are kept apart: whether the *browser* is
//  signed in to a provider (read from its own cookie jar), and the list of
//  addresses the user has noted for one-tap access. The list is not a
//  credential store — the password never leaves the provider's page — and the
//  signed-in address cannot be read from a cookie, which is why the list does
//  not fill itself in.
//

import SwiftUI

struct LoginSettingsView: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.browserPalette) private var palette

    @State private var showingAddAccount = false
    @State private var addProvider: WebAccountProvider = .google
    @State private var addEmail = ""
    @State private var addLabel = ""
    @State private var confirmingSignOut = false

    private var service: WebAccountService { env.services.webAccounts }

    /// Google first, Apple second — the order the session rows and the logged
    /// out buttons are listed in.
    private var accounts: [WebAccount] {
        WebAccountProvider.allCases.flatMap { service.accounts(for: $0) }
    }

    var body: some View {
        List {
            Section {
                ForEach(WebAccountProvider.allCases) { provider in
                    sessionRow(provider)
                }
            } header: {
                Text("浏览器中的登录")
            } footer: {
                Text("登录在服务商自己的页面完成，Vela 不保存密码，也不上传下面的账号。")
            }

            Section {
                ForEach(accounts) { account in
                    accountRow(account)
                }
                Button {
                    addProvider = .google
                    addEmail = ""
                    addLabel = ""
                    showingAddAccount = true
                } label: {
                    Label("添加账号", systemImage: "plus.circle")
                }
            } header: {
                Text("已添加的账号")
            } footer: {
                if accounts.isEmpty {
                    Text("添加只是在本机记下一个地址和备注，方便以后一键打开，不是登录。")
                }
            }

            Section {
                ForEach(WebAccountProvider.allCases) { provider in
                    Button {
                        openSignIn(provider)
                    } label: {
                        Label(
                            "登录 \(provider.displayName)",
                            systemImage: provider == .google ? "g.circle" : "apple.logo"
                        )
                    }
                }
            } header: {
                Text("登录")
            } footer: {
                Text("会打开服务商的登录页。登录后回到这里，上面的状态会更新。")
            }

            Section {
                Button(role: .destructive) {
                    confirmingSignOut = true
                } label: {
                    HStack {
                        Label("退出所有账号", systemImage: "rectangle.portrait.and.arrow.right")
                        if service.signingOutProvider != nil {
                            Spacer()
                            ProgressView().controlSize(.small)
                        }
                    }
                }
                .disabled(service.signingOutProvider != nil)
            } footer: {
                Text("清除浏览器里所有 Google 与 Apple 站点的登录状态，并清空本机账号列表。不能撤销。")
            }
        }
        .settingsList()
        .navigationTitle("登录")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            await service.refreshSessions()
        }
        .onAppear {
            // Coming back from a sign-in tab: the cookie jar has changed.
            Task { await service.refreshSessions() }
        }
        .sheet(isPresented: $showingAddAccount) {
            addAccountSheet
                .browserAmbientSheet()
        }
        .alert("退出所有账号？", isPresented: $confirmingSignOut) {
            Button("取消", role: .cancel) {}
            Button("退出并清除", role: .destructive) {
                Task { await service.signOutAll() }
            }
        } message: {
            Text("浏览器里所有 Google 与 Apple 站点的登录会被清除，本机账号列表也会清空。")
        }
    }

    // MARK: - Rows

    private func sessionRow(_ provider: WebAccountProvider) -> some View {
        let session = service.session(for: provider)
        return HStack(spacing: 10) {
            Image(systemName: provider == .google ? "g.circle" : "apple.logo")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(palette.primaryText)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text(provider.displayName)
                    .foregroundStyle(palette.primaryText)
                Text(sessionDetail(session, provider: provider))
                    .font(.caption)
                    .foregroundStyle(palette.secondaryText)
            }
            Spacer(minLength: 0)
            if session == .unknown {
                ProgressView().controlSize(.small)
            } else {
                Text(session == .signedIn ? "已登录" : "未登录")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(session == .signedIn ? signedInTint : palette.secondaryText)
            }
        }
    }

    private func accountRow(_ account: WebAccount) -> some View {
        Button {
            openAccountPage(account.provider)
        } label: {
            HStack(spacing: 12) {
                Image(systemName: account.provider == .google ? "g.circle" : "apple.logo")
                    .font(.system(size: 16, weight: .regular))
                    .foregroundStyle(palette.secondaryText)
                    .frame(width: 24)
                VStack(alignment: .leading, spacing: 2) {
                    Text(account.email)
                        .foregroundStyle(palette.primaryText)
                        .lineLimit(1)
                    Text(accountSubtitle(account))
                        .font(.caption)
                        .foregroundStyle(palette.secondaryText)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
                Image(systemName: "arrow.up.forward")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(palette.secondaryText.opacity(0.7))
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button("打开 \(account.provider.displayName) 账号页", systemImage: "safari") {
                openAccountPage(account.provider)
            }
            Button("从列表移除", systemImage: "minus.circle", role: .destructive) {
                service.remove(id: account.id)
            }
        }
    }

    private func accountSubtitle(_ account: WebAccount) -> String {
        account.label.isEmpty
            ? account.provider.displayName
            : "\(account.provider.displayName) · \(account.label)"
    }

    private var addAccountSheet: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("服务", selection: $addProvider) {
                        ForEach(WebAccountProvider.allCases) { provider in
                            Text(provider.displayName).tag(provider)
                        }
                    }
                    .pickerStyle(.segmented)

                    TextField("邮箱地址", text: $addEmail)
                        .keyboardType(.emailAddress)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    TextField("备注（可选）", text: $addLabel)
                } footer: {
                    Text("只保存在这台设备上，用于这里的显示。")
                }
            }
            .navigationTitle("添加账号")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { showingAddAccount = false }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("添加") {
                        service.add(provider: addProvider, email: addEmail, label: addLabel)
                        showingAddAccount = false
                    }
                    .disabled(WebAccountService.normalizedEmail(addEmail) == nil)
                }
            }
        }
    }

    // MARK: - Session copy

    private func sessionDetail(
        _ session: WebAccountService.BrowserSession,
        provider: WebAccountProvider
    ) -> String {
        switch session {
        case .unknown: return "正在读取浏览器自己的 Cookie。"
        case .signedIn: return "具体地址不写在 Cookie 里，无法在这里显示。"
        case .signedOut: return "在下面登录 \(provider.displayName) 后会自动更新。"
        }
    }

    private var signedInTint: Color {
        Color(red: 0.20, green: 0.62, blue: 0.35)
    }

    // MARK: - Actions

    private func openSignIn(_ provider: WebAccountProvider) {
        guard let url = provider.signInURL else { return }
        _ = env.tabManager.openTab(url: url, openSource: .shortcut, activate: true)
    }

    private func openAccountPage(_ provider: WebAccountProvider) {
        guard let url = provider.accountPageURL else { return }
        _ = env.tabManager.openTab(url: url, openSource: .shortcut, activate: true)
    }
}
