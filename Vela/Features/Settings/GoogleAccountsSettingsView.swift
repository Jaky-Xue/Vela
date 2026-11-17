//
//  GoogleAccountsSettingsView.swift
//  Vela
//
//  设置 ▸ Google 账号.
//
//  Two facts, side by side and kept apart: whether the *browser* is signed in
//  to Google (read from its own cookie jar), and the list of addresses the
//  user has noted for one-tap access. The list is not a credential store — the
//  password never leaves Google's page — and the signed-in address cannot be
//  read from a cookie, which is why the list does not fill itself in.
//

import SwiftUI

struct GoogleAccountsSettingsView: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.browserPalette) private var palette

    @State private var showingAddAccount = false
    @State private var addEmail = ""
    @State private var addLabel = ""
    @State private var confirmingSignOut = false

    private var service: GoogleAccountService { env.services.googleAccounts }

    var body: some View {
        List {
            Section {
                HStack(spacing: 10) {
                    Image(systemName: sessionSymbol)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(sessionTint)
                        .frame(width: 24)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(sessionTitle)
                            .foregroundStyle(palette.primaryText)
                        Text(sessionDetail)
                            .font(.caption)
                            .foregroundStyle(palette.secondaryText)
                    }
                    Spacer(minLength: 0)
                    if service.browserSession == .unknown {
                        ProgressView()
                            .controlSize(.small)
                    }
                }
            } header: {
                Text("浏览器中的 Google 登录")
            } footer: {
                Text("登录在 Google 自己的页面完成，Vela 不保存密码，也不上传下面的账号。")
            }

            Section {
                ForEach(service.accounts) { account in
                    accountRow(account)
                }
                Button {
                    addEmail = ""
                    addLabel = ""
                    showingAddAccount = true
                } label: {
                    Label("添加账号", systemImage: "plus.circle")
                }
            } header: {
                Text("已添加的账号")
            } footer: {
                if service.accounts.isEmpty {
                    Text("添加只是在本机记下一个地址和备注，方便以后一键打开，不是登录。")
                }
            }

            Section {
                Button {
                    openGoogleSignIn()
                } label: {
                    Label("在新标签页登录 Google", systemImage: "person.crop.circle.badge.plus")
                }
            } footer: {
                Text("会打开 Google 的登录页。登录后回到这里，上面的状态会更新。")
            }

            Section {
                Button(role: .destructive) {
                    confirmingSignOut = true
                } label: {
                    HStack {
                        Label("退出所有 Google 账号", systemImage: "rectangle.portrait.and.arrow.right")
                        if service.isSigningOut {
                            Spacer()
                            ProgressView().controlSize(.small)
                        }
                    }
                }
                .disabled(service.isSigningOut)
            } footer: {
                Text("清除浏览器里所有 Google 站点的登录状态，并清空本机列表。不能撤销。")
            }
        }
        .settingsList()
        .navigationTitle("Google 账号")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            await service.refreshSession()
        }
        .onAppear {
            // Coming back from the sign-in tab: the cookie jar has changed.
            Task { await service.refreshSession() }
        }
        .sheet(isPresented: $showingAddAccount) {
            addAccountSheet
                .browserAmbientSheet()
        }
        .alert("退出所有 Google 账号？", isPresented: $confirmingSignOut) {
            Button("取消", role: .cancel) {}
            Button("退出并清除", role: .destructive) {
                Task { await service.signOutEverywhere() }
            }
        } message: {
            Text("浏览器里所有 Google 站点的登录会被清除，本机列表也会清空。")
        }
    }

    // MARK: - Rows

    private func accountRow(_ account: GoogleAccount) -> some View {
        Button {
            openGoogleAccountPage()
        } label: {
            HStack(spacing: 12) {
                Image(systemName: "person.crop.circle")
                    .font(.system(size: 18, weight: .regular))
                    .foregroundStyle(palette.secondaryText)
                    .frame(width: 24)
                VStack(alignment: .leading, spacing: 2) {
                    Text(account.email)
                        .foregroundStyle(palette.primaryText)
                        .lineLimit(1)
                    if !account.label.isEmpty {
                        Text(account.label)
                            .font(.caption)
                            .foregroundStyle(palette.secondaryText)
                            .lineLimit(1)
                    }
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
            Button("打开我的 Google 账号", systemImage: "safari") {
                openGoogleAccountPage()
            }
            Button("从列表移除", systemImage: "minus.circle", role: .destructive) {
                service.remove(id: account.id)
            }
        }
    }

    private var addAccountSheet: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("邮箱地址", text: $addEmail)
                        .keyboardType(.emailAddress)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    TextField("备注（可选）", text: $addLabel)
                } footer: {
                    Text("只保存在这台设备上，用于主页和这里的显示。")
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
                        service.add(email: addEmail, label: addLabel)
                        showingAddAccount = false
                    }
                    .disabled(GoogleAccountService.normalizedEmail(addEmail) == nil)
                }
            }
        }
    }

    // MARK: - Session copy

    private var sessionTitle: String {
        switch service.browserSession {
        case .unknown: return "正在检查登录状态"
        case .signedIn: return "浏览器已登录 Google"
        case .signedOut: return "浏览器未登录 Google"
        }
    }

    private var sessionDetail: String {
        switch service.browserSession {
        case .unknown: return "读取浏览器自己的 Cookie。"
        case .signedIn: return "具体地址不写在 Cookie 里，所以无法在这里显示。"
        case .signedOut: return "在下面的登录页登录后，这里会自动更新。"
        }
    }

    private var sessionSymbol: String {
        switch service.browserSession {
        case .unknown: return "hourglass"
        case .signedIn: return "checkmark.shield.fill"
        case .signedOut: return "person.crop.circle.badge.xmark"
        }
    }

    private var sessionTint: Color {
        switch service.browserSession {
        case .unknown: return palette.secondaryText
        case .signedIn: return Color(red: 0.20, green: 0.62, blue: 0.35)
        case .signedOut: return palette.secondaryText
        }
    }

    // MARK: - Actions

    private func openGoogleSignIn() {
        guard let url = URL(
            string: "https://accounts.google.com/ServiceLogin?continue=https%3A%2F%2Fmyaccount.google.com%2F"
        ) else { return }
        _ = env.tabManager.openTab(url: url, openSource: .shortcut, activate: true)
    }

    private func openGoogleAccountPage() {
        guard let url = URL(string: "https://myaccount.google.com/") else { return }
        _ = env.tabManager.openTab(url: url, openSource: .shortcut, activate: true)
    }
}
