//
//  NewTabHomeView.swift
//  Vela
//
//  The native new-tab surface: most-visited shortcuts and recently closed.
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

    private let columns = [GridItem(.adaptive(minimum: 78, maximum: 104), spacing: BrowserSpacing.compact)]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: BrowserSpacing.loose) {
                if !shortcuts.isEmpty { shortcutBlock }
                if !recentlyClosed.isEmpty { recentlyClosedBlock }
                if shortcuts.isEmpty && recentlyClosed.isEmpty { emptyHint }
            }
            .padding(.horizontal, BrowserSpacing.regular + 4)
            .padding(.top, BrowserSpacing.regular)
            .padding(.bottom, BrowserSpacing.loose)
        }
        .background(palette.surface)
        .scrollDismissesKeyboard(.immediately)
        .onAppear(perform: reload)
    }

    // MARK: - Empty state

    /// What a home with no history shows.
    ///
    /// With the greeting gone, a fresh install would otherwise present a bare
    /// black rectangle, which reads as a broken page rather than an empty one.
    private var emptyHint: some View {
        VStack(spacing: BrowserSpacing.compact) {
            Image(systemName: "sparkles")
                .font(.system(size: 22, weight: .medium))
                .foregroundStyle(palette.secondaryText.opacity(0.7))
            Text("开始浏览后，常用网站会出现在这里。")
                .font(.subheadline)
                .foregroundStyle(palette.secondaryText)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 96)
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
                SiteIconView(host: entry.host, size: 42)
                Text(entry.displayHost)
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(palette.secondaryText)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, BrowserSpacing.compact)
            .padding(.horizontal, BrowserSpacing.tight)
            .background(
                RoundedRectangle(cornerRadius: BrowserRadius.card, style: .continuous)
                    .fill(palette.card.opacity(0.55))
            )
            .overlay {
                // A top-edge catch of light, the same treatment the chrome
                // uses, so the tiles belong to the same material family.
                RoundedRectangle(cornerRadius: BrowserRadius.card, style: .continuous)
                    .strokeBorder(
                        LinearGradient(
                            colors: [.white.opacity(0.35), .white.opacity(0.04)],
                            startPoint: .top,
                            endPoint: .bottom
                        ),
                        lineWidth: 0.5
                    )
                    .allowsHitTesting(false)
            }
            .contentShape(RoundedRectangle(cornerRadius: BrowserRadius.card, style: .continuous))
        }
        .buttonStyle(ShortcutTileButtonStyle())
        .contextMenu {
            Button("在新标签页打开", systemImage: "plus.square.on.square") {
                guard let url = URL(string: entry.url) else { return }
                env.tabManager.openTab(
                    url: url,
                    privacyMode: .regular,
                    openSource: .shortcut,
                    activate: false
                )
            }
            Button("从常用网站中移除", systemImage: "xmark.circle", role: .destructive) {
                env.history.remove(entry)
                reload()
            }
        }
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
                        if let url = URL(string: record.url) {
                            env.tabManager.openTab(
                                url: url,
                                privacyMode: record.privacyMode,
                                openSource: .restore
                            )
                        }
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

/// The press feedback for a shortcut tile.
///
/// The tile has no panel of its own — the icon and the label float on the
/// surface — so without this a tap on a shortcut is completely silent until the
/// page it opens appears.
private struct ShortcutTileButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.94 : 1)
            .opacity(configuration.isPressed ? 0.7 : 1)
            .animation(.spring(response: 0.24, dampingFraction: 0.72), value: configuration.isPressed)
    }
}
