//
//  LoginSettingsView.swift
//  Vela
//
//  设置 ▸ 账号 ▸ 登录.
//
//  One page for every provider, drawn as an account page rather than a list of
//  switches: the state of the browser's sign-in is the subject, so it gets the
//  top of the screen — an avatar, the account it belongs to, and which
//  providers are signed in — and the actions follow underneath.
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
    /// The provider whose sign-in page is open in a small window.
    @State private var signInProvider: WebAccountProvider?
    /// Addresses are masked until asked for: the list names who the user
    /// signs in as, and a settings screen is often read over a shoulder.
    @AppStorage("org.vela.browser.login-reveals-addresses") private var revealsAddresses = false

    private var service: WebAccountService { env.services.webAccounts }

    /// Google first, Apple second — the order the page is laid out in.
    private var accounts: [WebAccount] {
        WebAccountProvider.allCases.flatMap { service.accounts(for: $0) }
    }

    private var signedInProviders: [WebAccountProvider] {
        WebAccountProvider.allCases.filter { service.session(for: $0) == .signedIn }
    }

    var body: some View {
        List {
            Section {
                hero
                    .listRowInsets(EdgeInsets(top: 6, leading: 16, bottom: 14, trailing: 16))
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
            }

            Section {
                BrowserActivityGrid()
                    .listRowInsets(EdgeInsets(top: 12, leading: 12, bottom: 12, trailing: 12))
            } header: {
                Text("活跃")
            }

            Section {
                ForEach(WebAccountProvider.allCases) { provider in
                    providerCard(provider)
                }
            } header: {
                Text("服务商")
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
                Text("账号")
            } footer: {
                if accounts.isEmpty {
                    Text("添加只是在本机记下一个地址和备注，方便以后一键打开，不是登录。")
                }
            }

            Section {
                Button(role: .destructive) {
                    confirmingSignOut = true
                } label: {
                    HStack {
                        Spacer(minLength: 0)
                        if service.signingOutProvider != nil {
                            ProgressView().controlSize(.small)
                        }
                        Text("退出所有账号")
                            .font(.body.weight(.semibold))
                        Spacer(minLength: 0)
                    }
                    .frame(height: 26)
                }
                .disabled(service.signingOutProvider != nil)
            } footer: {
                Text("清除浏览器里所有 Google 与 Apple 站点的登录状态，并清空本机账号列表。不能撤销。")
            }
        }
        .settingsList()
        .navigationTitle("登录")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    revealsAddresses.toggle()
                } label: {
                    Image(systemName: revealsAddresses ? "eye.slash" : "eye")
                }
                .accessibilityLabel(revealsAddresses ? "隐藏邮箱" : "显示邮箱")
            }
        }
        .task {
            await service.refreshSessions()
        }
        .onAppear {
            // Coming back from a sign-in window: the cookie jar has changed.
            Task { await service.refreshSessions() }
        }
        .sheet(isPresented: $showingAddAccount) {
            addAccountSheet
                .browserAmbientSheet()
        }
        // The sign-in page opens in front of the settings, in a small window,
        // and shares the browser's cookie jar: what is signed in there is
        // signed in for the browser.
        .sheet(item: $signInProvider) { provider in
            LoginWebSheet(
                provider: provider,
                userAgent: env.settings.preferences.customUserAgent
            ) {
                Task { await service.refreshSessions() }
            }
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

    // MARK: - Hero

    /// The page's subject: the account the browser is known by, and which
    /// providers that covers. When nothing is signed in it is still the
    /// subject — 「登录」 — rather than a blank space above a list.
    private var hero: some View {
        VStack(spacing: 10) {
            ZStack {
                Circle()
                    .fill(
                        LinearGradient(
                            colors: heroTint,
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                    .frame(width: 76, height: 76)
                    .shadow(color: heroTint[0].opacity(0.35), radius: 16, y: 7)

                Image(systemName: "person.fill")
                    .font(.system(size: 32, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.94))
            }
            .padding(.top, 10)

            HStack(spacing: 6) {
                Text(heroTitle)
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(palette.primaryText)
                    .lineLimit(1)

                if !signedInProviders.isEmpty {
                    Text("在线")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(signedInGreen)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 2)
                        .overlay {
                            Capsule()
                                .strokeBorder(signedInGreen.opacity(0.55), lineWidth: 1)
                        }
                }
            }

            Text(heroSubtitle)
                .font(.footnote)
                .foregroundStyle(palette.secondaryText)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 16)
    }

    private var heroTitle: String {
        if let first = accounts.first {
            return first.label.isEmpty ? displayAddress(first.email) : first.label
        }
        return "登录"
    }

    private var heroSubtitle: String {
        let signed = signedInProviders.map(\.displayName)
        if signed.count == WebAccountProvider.allCases.count {
            return "Google 与 Apple 均已登录"
        }
        if signed.count == 1 {
            return "\(signed[0]) 已登录 · 另一个服务商未登录"
        }
        return "尚未登录任何服务商"
    }

    /// The avatar's colour follows the state: blue when something is signed
    /// in, quiet graphite when nothing is.
    private var heroTint: [Color] {
        guard !signedInProviders.isEmpty else {
            return [Color(white: 0.42), Color(white: 0.28)]
        }
        return [
            Color(red: 0.36, green: 0.58, blue: 0.98),
            Color(red: 0.20, green: 0.40, blue: 0.94)
        ]
    }

    private var signedInGreen: Color {
        Color(red: 0.20, green: 0.62, blue: 0.35)
    }

    // MARK: - Provider cards

    private func providerCard(_ provider: WebAccountProvider) -> some View {
        let session = service.session(for: provider)
        return Button {
            signInProvider = provider
        } label: {
            HStack(spacing: 12) {
                providerMark(provider)
                VStack(alignment: .leading, spacing: 2) {
                    Text(provider.displayName)
                        .foregroundStyle(palette.primaryText)
                    HStack(spacing: 5) {
                        Circle()
                            .fill(sessionColor(session))
                            .frame(width: 6, height: 6)
                        Text(sessionLabel(session))
                            .font(.caption)
                            .foregroundStyle(palette.secondaryText)
                    }
                }
                Spacer(minLength: 0)
                if session == .unknown {
                    ProgressView().controlSize(.small)
                } else {
                    Text(session == .signedIn ? "重新登录" : "登录")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(palette.accent)
                }
                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(palette.secondaryText.opacity(0.5))
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(provider.displayName)，\(sessionLabel(session))")
    }

    /// The provider's own mark: a rounded tile in the brand's colour with its
    /// glyph, the way a sign-in list names its services.
    private func providerMark(_ provider: WebAccountProvider) -> some View {
        let colors: [Color] = provider == .google
            ? [Color(red: 0.26, green: 0.52, blue: 0.96), Color(red: 0.10, green: 0.45, blue: 0.91)]
            : [Color(white: 0.30), Color(white: 0.12)]
        return RoundedRectangle(cornerRadius: 10, style: .continuous)
            .fill(LinearGradient(colors: colors, startPoint: .top, endPoint: .bottom))
            .frame(width: 36, height: 36)
            .overlay {
                Image(systemName: provider == .google ? "g.circle" : "apple.logo")
                    .font(.system(size: 17, weight: .bold))
                    .foregroundStyle(.white)
            }
            .overlay {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.16), lineWidth: 0.5)
            }
    }

    private func sessionLabel(_ session: WebAccountService.BrowserSession) -> String {
        switch session {
        case .unknown: return "正在检查登录状态"
        case .signedIn: return "已登录"
        case .signedOut: return "未登录"
        }
    }

    private func sessionColor(_ session: WebAccountService.BrowserSession) -> Color {
        switch session {
        case .signedIn: return signedInGreen
        case .unknown, .signedOut: return palette.secondaryText.opacity(0.4)
        }
    }

    // MARK: - Accounts

    private func accountRow(_ account: WebAccount) -> some View {
        Button {
            openAccountPage(account.provider)
        } label: {
            HStack(spacing: 12) {
                ZStack {
                    Circle()
                        .fill(palette.accent.opacity(0.16))
                        .frame(width: 36, height: 36)
                    Text(initial(of: account.email))
                        .font(.system(size: 15, weight: .semibold, design: .rounded))
                        .foregroundStyle(palette.accent)
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text(displayAddress(account.email))
                        .foregroundStyle(palette.primaryText)
                        .lineLimit(1)
                        .privacySensitive()
                    Text(accountSubtitle(account))
                        .font(.caption)
                        .foregroundStyle(palette.secondaryText)
                        .lineLimit(1)
                }

                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(palette.secondaryText.opacity(0.5))
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

    private func initial(of email: String) -> String {
        String(email.first.map(String.init) ?? "?").uppercased()
    }

    private func accountSubtitle(_ account: WebAccount) -> String {
        account.label.isEmpty
            ? account.provider.displayName
            : "\(account.provider.displayName) · \(account.label)"
    }

    /// The address as the list draws it: masked unless revealed, keeping the
    /// first character and the domain so two accounts stay tellable apart.
    private func displayAddress(_ email: String) -> String {
        guard !revealsAddresses else { return email }
        let parts = email.split(separator: "@", maxSplits: 1)
        guard parts.count == 2, let head = parts[0].first else { return "•••" }
        return "\(head)•••@\(parts[1])"
    }

    // MARK: - Add sheet

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

    // MARK: - Actions

    private func openAccountPage(_ provider: WebAccountProvider) {
        guard let url = provider.accountPageURL else { return }
        _ = env.tabManager.openTab(url: url, openSource: .shortcut, activate: true)
    }
}
