//
//  NewTabHomeView.swift
//  Vela
//
//  The native new-tab surface. Ported from `features/newtab/`,
//  `BrowserHomePresentationViewModel.ets` and
//  `BrowserHomeActionAvailabilityCoordinator.ets`
//  (Aira Browser 3.7.4, GPL-3.0).
//
//  Aira's home is a configurable web document the user can replace with their
//  own HTML (`CustomHomepageSettingsPage`, ADR 0046). Vela keeps the native
//  surface because the port has no custom-homepage runtime, and renders the same
//  three sections in the same order: search, most-visited shortcuts, and
//  recently closed.
//
//  Shortcuts are derived from history rather than stored separately. ADR 0044
//  ("home web shortcuts are independent from bookmarks") is the reason Aira
//  keeps them apart; on iOS, deriving them costs one indexed query and removes
//  an entire second store from the port.
//

import SwiftUI
import UIKit

struct NewTabHomeView: View {
    @EnvironmentObject private var env: AppEnvironment
    @Environment(\.browserPalette) private var palette

    var onNavigate: (URL) -> Void
    var onOpenBookmarks: () -> Void

    @State private var query = ""
    @State private var shortcuts: [HistoryUrl] = []
    @State private var recentlyClosed: [RecentlyClosedTabRecord] = []

    private let columns = [GridItem(.adaptive(minimum: 72, maximum: 96), spacing: 16)]

    var body: some View {
        ScrollView {
            VStack(spacing: 28) {
                searchField
                if !shortcuts.isEmpty { shortcutGrid }
                if !recentlyClosed.isEmpty { recentlyClosedSection }
                footer
            }
            .padding(.horizontal, 20)
            .padding(.top, 44)
            .padding(.bottom, 140)
        }
        .background(palette.surface)
        .onAppear(perform: reload)
    }

    // MARK: - Search

    private var searchField: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 15))
                .foregroundStyle(.secondary)
            TextField(
                "用 \(env.settings.preferences.searchEngine.activeEngine.name) 搜索或输入网址",
                text: $query
            )
            .textFieldStyle(.plain)
            .font(.system(size: 16))
            .autocorrectionDisabled()
            .textInputAutocapitalization(.never)
            .keyboardType(.URL)
            .submitLabel(.go)
            .onSubmit(submit)
        }
        .padding(.horizontal, 14)
        .frame(height: 46)
        .background(Color(.secondarySystemFill), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private func submit() {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let engine = env.settings.preferences.searchEngine.activeEngine
        guard let url = BrowserUrlResolver.resolveNavigation(input: trimmed, searchEngine: engine) else { return }
        if BrowserUrlResolver.isSearchQuery(trimmed) {
            try? env.searchHistory.record(
                query: trimmed,
                searchEngineId: engine.id,
                boundary: env.tabManager.activeTab?.dataBoundary ?? .persistent
            )
        }
        query = ""
        onNavigate(url)
    }

    // MARK: - Shortcuts

    private var shortcutGrid: some View {
        LazyVGrid(columns: columns, spacing: 18) {
            ForEach(shortcuts) { entry in
                Button {
                    guard let url = URL(string: entry.url) else { return }
                    onNavigate(url)
                } label: {
                    VStack(spacing: 7) {
                        SiteIconView(host: entry.host, size: 48)
                        Text(entry.displayHost)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                .buttonStyle(.plain)
                .contextMenu {
                    Button("在新标签页打开", systemImage: "plus.square.on.square") {
                        guard let url = URL(string: entry.url) else { return }
                        let tab = env.tabManager.createTab(
                            url: url.absoluteString,
                            privacyMode: .regular,
                            openSource: .shortcut,
                            activate: false
                        )
                        _ = env.tabManager.ensureWebView(for: tab)
                    }
                    Button("从常用网站中移除", systemImage: "xmark.circle", role: .destructive) {
                        env.history.remove(entry)
                        reload()
                    }
                }
            }
        }
    }

    // MARK: - Recently closed

    private var recentlyClosedSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("最近关闭")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.secondary)

            VStack(spacing: 0) {
                ForEach(recentlyClosed.prefix(5)) { record in
                    Button {
                        let tab = env.tabManager.createTab(
                            url: record.url,
                            privacyMode: record.privacyMode,
                            openSource: .restore
                        )
                        _ = env.tabManager.ensureWebView(for: tab)
                        env.tabManager.removeRecentlyClosedRecord(id: record.id)
                        reload()
                    } label: {
                        HStack(spacing: 10) {
                            SiteIconView(
                                host: URL(string: record.url)?.host ?? "",
                                size: 24
                            )
                            VStack(alignment: .leading, spacing: 1) {
                                Text(record.title.isEmpty ? record.url : record.title)
                                    .font(.system(size: 13))
                                    .lineLimit(1)
                                    .foregroundStyle(.primary)
                                Text(URL(string: record.url)?.host ?? "")
                                    .font(.system(size: 11))
                                    .lineLimit(1)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer(minLength: 0)
                            Image(systemName: "arrow.up.left")
                                .font(.system(size: 11))
                                .foregroundStyle(.tertiary)
                        }
                        .padding(.vertical, 7)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)

                    if record.id != recentlyClosed.prefix(5).last?.id {
                        Divider().padding(.leading, 34)
                    }
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 4)
            .background(Color(.secondarySystemFill), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
    }

    // MARK: - Footer

    private var footer: some View {
        VStack(spacing: 10) {
            Divider()
            HStack(spacing: 18) {
                Button {
                    onOpenBookmarks()
                } label: {
                    Label("书签", systemImage: "book")
                        .font(.system(size: 13))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)

                Button {
                    env.tabManager.createTab(privacyMode: .private, openSource: .user)
                } label: {
                    Label("无痕标签页", systemImage: "eyeglasses")
                        .font(.system(size: 13))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)

                Spacer()
            }
        }
        .padding(.top, 8)
    }

    // MARK: - Data

    /// Rebuilds the shortcuts and recently-closed lists.
    ///
    /// Shortcuts are the most-visited *hosts* rather than the most-visited URLs,
    /// so a site that spreads its content over many paths still appears once.
    /// Ranking is by visit count first: a daily destination should outrank a
    /// page that happened to be reloaded twenty times in one session.
    private func reload() {
        var seenHosts = Set<String>()
        var picked: [HistoryUrl] = []

        for entry in env.history.allVisited().sorted(by: { $0.visitCount > $1.visitCount }) {
            guard !entry.host.isEmpty, seenHosts.insert(entry.host).inserted else { continue }
            picked.append(entry)
            if picked.count >= 8 { break }
        }

        shortcuts = picked
        recentlyClosed = env.tabManager.recentlyClosed.filter { $0.privacyMode == .regular }
    }
}
