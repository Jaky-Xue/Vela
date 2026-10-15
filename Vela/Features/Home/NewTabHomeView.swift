//
//  NewTabHomeView.swift
//  Vela
//
//  The native new-tab surface: search, most-visited shortcuts and recently
//  closed, in that order.
//
//  The surface is native rather than a web document because there is no
//  custom-homepage runtime to load one into.
//
//  Shortcuts are derived from history rather than stored separately. Keeping them
//  apart from bookmarks is deliberate — a shortcut is a place you went, not a
//  place you saved — and deriving them costs one indexed query instead of an
//  entire second store.
//
//  Every block below the search box is collapsible, and the shortcut grid folds
//  after eight. Rendering everything in full works until a profile has imported
//  history, at which point the home page becomes a wall of icons above a wall of
//  rows. The fold state is remembered per surface.
//

import SwiftUI
import UIKit

struct NewTabHomeView: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.browserPalette) private var palette

    var onNavigate: (URL) -> Void
    var onOpenBookmarks: () -> Void

    @State private var shortcuts: [HistoryUrl] = []
    @State private var recentlyClosed: [RecentlyClosedTabRecord] = []
    /// How many shortcuts the grid shows before folding. The rest are behind
    /// the "更多" row.
    @State private var showAllShortcuts = false

    @AppStorage("org.vela.browser.home-shortcuts-expanded") private var shortcutsExpanded = true
    @AppStorage("org.vela.browser.home-recently-closed-expanded") private var recentlyClosedExpanded = false

    /// Eight fits two rows of four at the default text size, which is the most
    /// that reads as a set rather than as a list.
    private static let shortcutCollapseThreshold = 8
    /// Loaded, but not shown until asked for.
    private static let shortcutFetchLimit = 16

    private let columns = [GridItem(.adaptive(minimum: 72, maximum: 96), spacing: BrowserSpacing.regular)]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: BrowserSpacing.loose) {
                if !shortcuts.isEmpty { shortcutBlock }
                if !recentlyClosed.isEmpty { recentlyClosedBlock }
                footer
            }
            .padding(.horizontal, BrowserSpacing.regular + 4)
            .padding(.top, BrowserSpacing.regular)
            .padding(.bottom, BrowserSpacing.loose)
        }
        .background(palette.surface)
        .scrollDismissesKeyboard(.immediately)
        .onAppear(perform: reload)
    }

    // MARK: - Shortcuts

    private var visibleShortcuts: [HistoryUrl] {
        showAllShortcuts ? shortcuts : Array(shortcuts.prefix(Self.shortcutCollapseThreshold))
    }

    private var shortcutBlock: some View {
        CollapsibleSection(
            title: "常用网站",
            systemImage: "square.grid.2x2",
            count: shortcuts.count,
            isExpanded: $shortcutsExpanded
        ) {
            VStack(alignment: .leading, spacing: BrowserSpacing.compact) {
                LazyVGrid(columns: columns, spacing: BrowserSpacing.regular + 2) {
                    ForEach(visibleShortcuts) { entry in
                        shortcutCell(entry)
                    }
                }

                if shortcuts.count > Self.shortcutCollapseThreshold {
                    Button {
                        withAnimation(.snappy(duration: 0.25)) {
                            showAllShortcuts.toggle()
                        }
                    } label: {
                        HStack(spacing: 4) {
                            Text(showAllShortcuts ? "收起" : "更多")
                            Image(systemName: "chevron.right")
                                .font(.system(size: 10, weight: .bold))
                                .rotationEffect(.degrees(showAllShortcuts ? -90 : 90))
                        }
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(palette.accent)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private func shortcutCell(_ entry: HistoryUrl) -> some View {
        Button {
            guard let url = URL(string: entry.url) else { return }
            onNavigate(url)
        } label: {
            VStack(spacing: BrowserSpacing.tight) {
                SiteIconView(host: entry.host, size: 52, faviconUrl: faviconUrl(for: entry))
                    .shadow(color: .black.opacity(0.12), radius: 6, y: 2)
                Text(entry.displayHost)
                    .font(.caption2)
                    .foregroundStyle(palette.secondaryText)
                    .lineLimit(1)
            }
            .contentShape(Rectangle())
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

    /// A favicon URL for a shortcut, or `nil`.
    ///
    /// WebKit does not expose a page's icon to the host app, so the only route
    /// is the site's own `/favicon.ico` — which most sites serve and the rest
    /// 404, in which case `SiteIconView` falls back to its letter swatch.
    private func faviconUrl(for entry: HistoryUrl) -> String? {
        guard let host = URL(string: entry.url)?.host, !host.isEmpty else { return nil }
        return "https://\(host)/favicon.ico"
    }

    // MARK: - Recently closed

    private var recentlyClosedBlock: some View {
        CollapsibleSection(
            title: "最近关闭",
            systemImage: "arrow.up.left",
            count: recentlyClosed.count,
            isExpanded: $recentlyClosedExpanded
        ) {
            VStack(spacing: 0) {
                ForEach(Array(recentlyClosed.prefix(5).enumerated()), id: \.element.id) { index, record in
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
                        HStack(spacing: BrowserSpacing.compact) {
                            SiteIconView(host: URL(string: record.url)?.host ?? "", size: 24)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(record.title.isEmpty ? record.url : record.title)
                                    .font(.footnote)
                                    .lineLimit(1)
                                    .foregroundStyle(palette.primaryText)
                                Text(URL(string: record.url)?.host ?? "")
                                    .font(.caption2)
                                    .lineLimit(1)
                                    .foregroundStyle(palette.secondaryText)
                            }
                            Spacer(minLength: 0)
                            Image(systemName: "arrow.up.left")
                                .font(.system(size: 11))
                                .foregroundStyle(palette.secondaryText.opacity(0.6))
                        }
                        .padding(.vertical, BrowserSpacing.tight + 1)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)

                    if index < min(recentlyClosed.count, 5) - 1 {
                        Rectangle()
                            .fill(palette.separator)
                            .frame(height: 0.5)
                            .padding(.leading, 34)
                    }
                }
            }
            .padding(.horizontal, BrowserSpacing.compact + 2)
            .padding(.vertical, BrowserSpacing.hairline)
            .browserCard(
                material: .thinMaterial,
                radius: BrowserRadius.chip + 4,
                elevation: BrowserElevation(radius: 10, y: 4, opacity: 0.06),
                tint: palette.card.opacity(0.4)
            )
        }
    }

    // MARK: - Footer

    private var footer: some View {
        HStack(spacing: BrowserSpacing.regular + 2) {
            Button {
                onOpenBookmarks()
            } label: {
                Label("书签", systemImage: "book")
                    .font(.footnote)
            }
            .buttonStyle(.plain)
            .foregroundStyle(palette.secondaryText)

            Button {
                env.tabManager.createTab(privacyMode: .private, openSource: .user)
            } label: {
                Label("无痕标签页", systemImage: "eyeglasses")
                    .font(.footnote)
            }
            .buttonStyle(.plain)
            .foregroundStyle(palette.secondaryText)

            Spacer()
        }
        .padding(.top, BrowserSpacing.tight)
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
            if picked.count >= Self.shortcutFetchLimit { break }
        }

        shortcuts = picked
        recentlyClosed = env.tabManager.recentlyClosed.filter { $0.privacyMode == .regular }
    }
}
