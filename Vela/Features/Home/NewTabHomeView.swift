//
//  NewTabHomeView.swift
//  Vela
//
//  The native new-tab surface: most-visited shortcuts and recently closed.
//
//  The surface is native rather than a web document because there is no
//  custom-homepage runtime to load one into.
//
//  Shortcuts come from two sources. The user can pin a site themselves — the
//  "添加" tile, or "固定为快捷方式" on a tile's long-press menu — and those are
//  kept verbatim, because a pinned shortcut is a decision, not a statistic.
//  Everything else is derived from history rather than stored separately:
//  keeping them apart from bookmarks is deliberate — a shortcut is a place you
//  went, not a place you saved — and deriving them costs one indexed query
//  instead of an entire second store. Pinned entries win their host, so a site
//  never appears twice.
//
//  Every block below the search box is collapsible, and the shortcut grid folds
//  after eight. Rendering everything in full works until a profile has imported
//  history, at which point the home page becomes a wall of icons above a wall of
//  rows. The fold state is remembered per surface.
//

import SwiftUI
import UIKit

/// A shortcut the user pinned themselves.
struct HomeShortcut: Codable, Identifiable, Equatable {
    var id: String
    var title: String
    var urlString: String

    var url: URL? { URL(string: urlString) }
    var host: String { URL(string: urlString)?.host ?? "" }
}

/// Where the user's pinned shortcuts live.
///
/// `UserDefaults` rather than the database: the list is a handful of entries the
/// user authored one at a time, it has no queries asked of it beyond "all of
/// them", and a store with no query is a store with no table worth writing.
private enum HomeShortcutStore {
    static let key = "org.vela.browser.home-custom-shortcuts"

    static func load() -> [HomeShortcut] {
        guard let data = UserDefaults.standard.data(forKey: key) else { return [] }
        return (try? JSONDecoder().decode([HomeShortcut].self, from: data)) ?? []
    }

    static func save(_ shortcuts: [HomeShortcut]) {
        UserDefaults.standard.set(try? JSONEncoder().encode(shortcuts), forKey: key)
    }
}

struct NewTabHomeView: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.browserPalette) private var palette

    var onNavigate: (URL) -> Void

    @State private var shortcuts: [HistoryUrl] = []
    @State private var recentlyClosed: [RecentlyClosedTabRecord] = []
    @State private var customShortcuts: [HomeShortcut] = []
    @State private var showAddShortcut = false
    /// How many tiles the grid shows before folding. The rest are behind the
    /// "更多" row.
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
                shortcutBlock
                if !recentlyClosed.isEmpty { recentlyClosedBlock }
            }
            .padding(.horizontal, BrowserSpacing.regular + 4)
            .padding(.top, BrowserSpacing.regular)
            // The extra run of bottom padding is what lets the last block sit
            // clear of the home indicator even though the surface itself runs
            // edge to edge below the safe area.
            .padding(.bottom, BrowserSpacing.loose + 12)
        }
        // The surface reaches the bottom edge of the screen: a strip of dead
        // background above the home indicator reads as something sitting on
        // top of the page, which is exactly what the user called occlusion.
        .ignoresSafeArea(edges: .bottom)
        .background(palette.surface)
        .scrollDismissesKeyboard(.immediately)
        .onAppear {
            customShortcuts = HomeShortcutStore.load()
            reload()
        }
        .sheet(isPresented: $showAddShortcut) {
            AddShortcutSheet { shortcut in
                customShortcuts.append(shortcut)
                HomeShortcutStore.save(customShortcuts)
            }
        }
    }

    // MARK: - Tiles

    /// One grid cell, from either source.
    private enum HomeTile: Identifiable {
        case custom(HomeShortcut)
        case visited(HistoryUrl)

        var id: String {
            switch self {
            case .custom(let shortcut): return "custom-\(shortcut.id)"
            case .visited(let entry): return "visited-\(entry.url)"
            }
        }
    }

    /// The grid's content: pinned shortcuts first, then history, one tile per
    /// host — a pinned entry claims its host, so a site never appears twice.
    private var tiles: [HomeTile] {
        var result: [HomeTile] = customShortcuts.map { .custom($0) }
        let pinnedHosts = Set(customShortcuts.map(\.host))
        for entry in shortcuts where !pinnedHosts.contains(entry.host) {
            result.append(.visited(entry))
        }
        return result
    }

    private var visibleTiles: [HomeTile] {
        showAllShortcuts ? tiles : Array(tiles.prefix(Self.shortcutCollapseThreshold))
    }

    private var shortcutBlock: some View {
        CollapsibleSection(
            title: "常用网站",
            systemImage: "square.grid.2x2",
            count: tiles.count,
            isExpanded: $shortcutsExpanded
        ) {
            VStack(alignment: .leading, spacing: BrowserSpacing.compact) {
                LazyVGrid(columns: columns, spacing: BrowserSpacing.regular + 2) {
                    ForEach(visibleTiles) { tile in
                        tileCell(tile)
                    }
                    addTile
                }

                if tiles.count > Self.shortcutCollapseThreshold {
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

    @ViewBuilder
    private func tileCell(_ tile: HomeTile) -> some View {
        switch tile {
        case .custom(let shortcut):
            Button {
                if let url = shortcut.url {
                    onNavigate(url)
                }
            } label: {
                tileVisual(
                    icon: SiteIconView(host: shortcut.host, size: 42),
                    label: shortcut.title
                )
            }
            .buttonStyle(ShortcutTileButtonStyle())
            .contextMenu {
                Button("在新标签页打开", systemImage: "plus.square.on.square") {
                    guard let url = shortcut.url else { return }
                    env.tabManager.openTab(
                        url: url,
                        privacyMode: .regular,
                        openSource: .shortcut,
                        activate: false
                    )
                }
                Button("移除快捷方式", systemImage: "xmark.circle", role: .destructive) {
                    customShortcuts.removeAll { $0.id == shortcut.id }
                    HomeShortcutStore.save(customShortcuts)
                }
            }

        case .visited(let entry):
            Button {
                guard let url = URL(string: entry.url) else { return }
                onNavigate(url)
            } label: {
                tileVisual(
                    icon: SiteIconView(host: entry.host, size: 42),
                    label: entry.displayHost
                )
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
                Button("固定为快捷方式", systemImage: "pin") {
                    let shortcut = HomeShortcut(
                        id: UUID().uuidString,
                        title: entry.displayHost,
                        urlString: entry.url
                    )
                    customShortcuts.append(shortcut)
                    HomeShortcutStore.save(customShortcuts)
                }
                Button("从常用网站中移除", systemImage: "xmark.circle", role: .destructive) {
                    env.history.remove(entry)
                    reload()
                }
            }
        }
    }

    /// The visual both tile kinds share, so a pinned site and a visited one
    /// read as the same object in the same grid.
    private func tileVisual(icon: some View, label: String) -> some View {
        VStack(spacing: BrowserSpacing.tight) {
            icon
            Text(label)
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

    /// The tile that adds a pinned shortcut.
    ///
    /// A dashed outline rather than a filled card: it is the one cell that is
    /// an invitation rather than a destination, and the outline says so
    /// without a word of explanation.
    private var addTile: some View {
        Button {
            showAddShortcut = true
        } label: {
            VStack(spacing: BrowserSpacing.tight) {
                Image(systemName: "plus")
                    .font(.system(size: 19, weight: .medium))
                Text("添加")
                    .font(.caption2.weight(.medium))
            }
            .foregroundStyle(palette.secondaryText)
            .frame(maxWidth: .infinity)
            .padding(.vertical, BrowserSpacing.compact)
            .padding(.horizontal, BrowserSpacing.tight)
            .frame(minHeight: 84)
            .background(
                RoundedRectangle(cornerRadius: BrowserRadius.card, style: .continuous)
                    .fill(palette.card.opacity(0.2))
            )
            .overlay {
                RoundedRectangle(cornerRadius: BrowserRadius.card, style: .continuous)
                    .strokeBorder(
                        palette.secondaryText.opacity(0.35),
                        style: StrokeStyle(lineWidth: 1, dash: [4, 3])
                    )
            }
            .contentShape(RoundedRectangle(cornerRadius: BrowserRadius.card, style: .continuous))
        }
        .buttonStyle(ShortcutTileButtonStyle())
        .accessibilityLabel("添加快捷方式")
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

    /// Rebuilds the history-derived shortcut list.
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

// MARK: - Add sheet

/// The form behind the "添加" tile.
///
/// Two fields, because a pinned shortcut is a name and an address. The name is
/// optional — an untitled shortcut takes its host, which is what the
/// history-derived tiles show anyway.
private struct AddShortcutSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.browserPalette) private var palette

    var onAdd: (HomeShortcut) -> Void

    @State private var urlText = ""
    @State private var title = ""

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("example.com", text: $urlText)
                        .keyboardType(.URL)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                } header: {
                    Text("网址")
                }

                Section {
                    TextField("默认取自网址", text: $title)
                } header: {
                    Text("名称")
                }

                if !urlText.isEmpty && resolvedUrl == nil {
                    Text("请输入有效的网址。")
                        .font(.footnote)
                        .foregroundStyle(.red)
                }
            }
            .navigationTitle("添加快捷方式")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("添加") { commit() }
                        .disabled(resolvedUrl == nil)
                }
            }
        }
        .presentationDetents([.medium])
    }

    /// The address as it would be saved: schemeless input is assumed to be
    /// https, and anything the browser could not navigate to is refused here
    /// rather than after it lands on the tab.
    private var resolvedUrl: URL? {
        var trimmed = urlText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if !trimmed.contains("://") { trimmed = "https://" + trimmed }
        guard let url = URL(string: trimmed),
              let scheme = url.scheme?.lowercased(),
              scheme == "https" || scheme == "http",
              !(url.host ?? "").isEmpty else { return nil }
        return url
    }

    private func commit() {
        guard let url = resolvedUrl else { return }
        let name = title.trimmingCharacters(in: .whitespaces)
        onAdd(HomeShortcut(
            id: UUID().uuidString,
            title: name.isEmpty ? (url.host ?? url.absoluteString) : name,
            urlString: url.absoluteString
        ))
        dismiss()
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
