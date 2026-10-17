//
//  NewTabHomeView.swift
//  Vela
//
//  The native new-tab surface: the user's bookmarks, and recently closed tabs.
//
//  The surface is native rather than a web document because there is no
//  custom-homepage runtime to load one into.
//
//  The grid shows the bookmark store — every saved URL, flattened from both
//  roots — because the home page and the bookmark list are the same inventory
//  seen from two places: what the user saved is what the user wants one tap
//  away, and keeping a third copy of that answer ("most visited") only
//  guaranteed the three lists disagreed. Saving on this surface adds to the
//  store, deleting removes from it, and both are visible everywhere else.
//

import SwiftUI
import UIKit

/// Which bookmarks the home grid shows.
///
/// The home is a curation, not an index: a bookmark reaches it either through
/// the add sheet's "同时添加到主页" switch or through the home's own add tile,
/// and it leaves through the tile's long-press menu. The ids live in the
/// defaults store; the first launch after this store existed seeds it with
/// every bookmark there is, so the grid the user already had does not vanish
/// underneath them.
enum HomeBookmarkStore {
    static let idsKey = "org.vela.browser.home-bookmark-ids"
    static let seededKey = "org.vela.browser.home-bookmarks-seeded"

    static func homeIds(among allIds: [String]) -> Set<String> {
        let defaults = UserDefaults.standard
        if !defaults.bool(forKey: seededKey) {
            let seed = Set(allIds)
            defaults.set(Array(seed), forKey: idsKey)
            defaults.set(true, forKey: seededKey)
            return seed
        }
        return Set(defaults.stringArray(forKey: idsKey) ?? [])
    }

    static func add(_ id: String) {
        var ids = Set(UserDefaults.standard.stringArray(forKey: idsKey) ?? [])
        ids.insert(id)
        UserDefaults.standard.set(Array(ids), forKey: idsKey)
    }

    static func remove(_ id: String) {
        var ids = Set(UserDefaults.standard.stringArray(forKey: idsKey) ?? [])
        ids.remove(id)
        UserDefaults.standard.set(Array(ids), forKey: idsKey)
    }
}

struct NewTabHomeView: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.browserPalette) private var palette

    var onNavigate: (URL) -> Void

    @State private var bookmarkNodes: [BookmarkNode] = []
    @State private var frequentSites: [HistoryUrl] = []
    @State private var recentlyClosed: [RecentlyClosedTabRecord] = []
    @State private var showAddBookmark = false
    /// The custom background, reloaded whenever the settings document's stamp
    /// moves — which happens the moment a picture is saved or cleared behind
    /// the settings sheet, so the change is live without leaving the screen.
    @State private var backgroundImage: UIImage?

    @AppStorage("org.vela.browser.home-bookmarks-expanded") private var bookmarksExpanded = true
    @AppStorage("org.vela.browser.home-frequent-expanded") private var frequentExpanded = true
    @AppStorage("org.vela.browser.home-recently-closed-expanded") private var recentlyClosedExpanded = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: BrowserSpacing.loose) {
                if bookmarkNodes.isEmpty {
                    // No bookmarks yet: the dashed add tile alone. A header
                    // over an empty grid is furniture for a collection that
                    // does not exist.
                    LazyVGrid(
                        columns: Self.tileColumns,
                        spacing: 14
                    ) {
                        addBookmarkTile
                    }
                } else {
                    bookmarkBlock
                }
                if !frequentSites.isEmpty { frequentBlock }
                if !recentlyClosed.isEmpty { recentlyClosedBlock }
            }
            .padding(.horizontal, BrowserSpacing.regular)
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
        .background { homeBackground }
        .scrollDismissesKeyboard(.immediately)
        .task(id: env.settings.preferences.homeBackgroundStamp) {
            reloadBackgroundImage()
        }
        .onAppear {
            loadBookmarks()
            loadFrequentSites()
        }
        .sheet(isPresented: $showAddBookmark) {
            AddBookmarkSheet { url, title in
                let node = env.bookmarks.addBookmark(url: url, title: title, parentNodeId: nil)
                // Added from the home tile, so it belongs on the home surface —
                // whether the store created it or the bookmark already existed.
                if let id = node?.id ?? env.bookmarks.bookmark(for: url)?.id {
                    HomeBookmarkStore.add(id)
                }
                loadBookmarks()
            }
        }
    }

    // MARK: - Background

    /// The custom background picture, or the plain palette surface when none
    /// is set. The photo is drawn as it is — no veil over it; the tiles and
    /// the recently-closed card carry their own fills, and the command bar is
    /// glass. The stamp is the reload key — `save` and `clear` both move it,
    /// which is what makes a change made in settings appear here immediately.
    @ViewBuilder
    private var homeBackground: some View {
        if let backgroundImage {
            Image(uiImage: backgroundImage)
                .resizable()
                .scaledToFill()
                .ignoresSafeArea()
        } else {
            palette.surface
                .ignoresSafeArea()
        }
    }

    private func reloadBackgroundImage() {
        guard let stamp = env.settings.preferences.homeBackgroundStamp else {
            backgroundImage = nil
            return
        }
        backgroundImage = HomeBackgroundStore.load(stamp: stamp)
    }

    // MARK: - Bookmarks

    /// Flattens both bookmark roots into the grid's inventory, depth-first and
    /// in saved order, then keeps only the ones the user has put on the home
    /// surface. Folders are walked through, not shown: the home grid is
    /// destinations only.
    private func loadBookmarks() {
        var all: [BookmarkNode] = []

        func walk(_ items: [BookmarkTreeItem]) {
            for item in items {
                if item.node.isFolder {
                    walk(item.children)
                } else if item.node.url != nil {
                    all.append(item.node)
                }
            }
        }

        for role in [BookmarkRootRole.toolbar, .other] {
            guard let rootId = env.bookmarks.rootNodeId(for: role) else { continue }
            walk(env.bookmarks.children(of: rootId))
        }

        let homeIds = HomeBookmarkStore.homeIds(among: all.map(\.id))
        bookmarkNodes = all.filter { homeIds.contains($0.id) }
    }

    /// The grid the tiles share — four flexible columns, the count Safari's
    /// start page uses for favorites in portrait, here and in the empty
    /// state's single-tile grid.
    static let tileColumns = Array(repeating: GridItem(.flexible(), spacing: 12), count: 4)

    private var bookmarkBlock: some View {
        CollapsibleSection(
            title: "个人收藏",
            systemImage: nil,
            count: nil,
            isExpanded: $bookmarksExpanded
        ) {
            LazyVGrid(
                columns: Self.tileColumns,
                spacing: 14
            ) {
                ForEach(bookmarkNodes) { node in
                    bookmarkCell(node)
                }
                addBookmarkTile
            }
        }
    }

    /// A bookmark tile: the site's icon on a rounded square with the site's
    /// own name beneath it — the shape Safari's favorites use, which is what
    /// this start page is modelled on.
    private func bookmarkCell(_ node: BookmarkNode) -> some View {
        Button {
            guard let url = BrowserUrlResolver.storedUrl(node.url) else { return }
            onNavigate(url)
        } label: {
            VStack(spacing: 6) {
                SiteIconView(host: node.displayHost, size: 40)
                    .frame(maxWidth: .infinity)
                    .aspectRatio(1, contentMode: .fit)
                    .background(
                        RoundedRectangle(cornerRadius: BrowserRadius.card, style: .continuous)
                            .fill(palette.card.opacity(0.6))
                    )
                    .overlay {
                        RoundedRectangle(cornerRadius: BrowserRadius.card, style: .continuous)
                            .strokeBorder(
                                LinearGradient(
                                    colors: [.white.opacity(0.14), .white.opacity(0.03)],
                                    startPoint: .top,
                                    endPoint: .bottom
                                ),
                                lineWidth: 0.5
                            )
                            .allowsHitTesting(false)
                    }

                Text(node.title.isEmpty ? node.displayHost : node.title)
                    .font(.caption)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                    .foregroundStyle(palette.primaryText)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(HomeTileButtonStyle())
        .contextMenu {
            Button("在新标签页打开", systemImage: "plus.square.on.square") {
                guard let url = BrowserUrlResolver.storedUrl(node.url) else { return }
                env.tabManager.openTab(
                    url: url,
                    privacyMode: .regular,
                    openSource: .shortcut,
                    activate: false
                )
            }
            Button("从主页移除", systemImage: "minus.square", role: .destructive) {
                HomeBookmarkStore.remove(node.id)
                loadBookmarks()
            }
            Button("删除书签", systemImage: "trash", role: .destructive) {
                env.bookmarks.removeNode(id: node.id)
                loadBookmarks()
            }
        }
        .accessibilityLabel(node.title.isEmpty ? node.displayHost : node.title)
    }

    // MARK: - Frequently visited

    /// The hosts the user actually revisits, ranked by visit count — the
    /// start page's answer to Safari's 经常访问. One tile per host: the
    /// highest-count entry stands for it, so a site reached through five
    /// different pages shows once.
    private func loadFrequentSites() {
        let ranked = env.history.allVisited()
            .filter { !$0.hidden }
            .sorted { ($0.visitCount, $0.lastVisitAt) > ($1.visitCount, $1.lastVisitAt) }

        var seenHosts = Set<String>()
        var top: [HistoryUrl] = []
        for entry in ranked {
            guard let host = URL(string: entry.url)?.host else { continue }
            let normalized = host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
            guard !normalized.isEmpty, seenHosts.insert(normalized).inserted else { continue }
            top.append(entry)
            if top.count >= 8 { break }
        }
        frequentSites = top
    }

    private var frequentBlock: some View {
        CollapsibleSection(
            title: "经常访问",
            systemImage: nil,
            count: nil,
            isExpanded: $frequentExpanded
        ) {
            LazyVGrid(
                columns: Self.tileColumns,
                spacing: 14
            ) {
                ForEach(frequentSites) { entry in
                    frequentCell(entry)
                }
            }
        }
    }

    private func frequentCell(_ entry: HistoryUrl) -> some View {
        Button {
            guard let url = URL(string: entry.url) else { return }
            onNavigate(url)
        } label: {
            VStack(spacing: 6) {
                SiteIconView(host: entry.host, size: 40)
                    .frame(maxWidth: .infinity)
                    .aspectRatio(1, contentMode: .fit)
                    .background(
                        RoundedRectangle(cornerRadius: BrowserRadius.card, style: .continuous)
                            .fill(palette.card.opacity(0.6))
                    )
                    .overlay {
                        RoundedRectangle(cornerRadius: BrowserRadius.card, style: .continuous)
                            .strokeBorder(
                                LinearGradient(
                                    colors: [.white.opacity(0.14), .white.opacity(0.03)],
                                    startPoint: .top,
                                    endPoint: .bottom
                                ),
                                lineWidth: 0.5
                            )
                            .allowsHitTesting(false)
                    }

                Text(entry.title.isEmpty ? entry.host : entry.title)
                    .font(.caption)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                    .foregroundStyle(palette.primaryText)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(HomeTileButtonStyle())
        .contextMenu {
            Button("在新标签页打开", systemImage: "plus.square.on.square") {
                guard let url = URL(string: entry.url) else { return }
                env.tabManager.openTab(
                    url: url,
                    privacyMode: .regular,
                    openSource: .history,
                    activate: false
                )
            }
        }
        .accessibilityLabel(entry.title.isEmpty ? entry.host : entry.title)
    }

    /// The tile that saves a new bookmark, in the same labelled shape as the
    /// tiles beside it, dashed where they are solid.
    private var addBookmarkTile: some View {
        Button {
            showAddBookmark = true
        } label: {
            VStack(spacing: 6) {
                Image(systemName: "plus")
                    .font(.system(size: 20, weight: .medium))
                    .foregroundStyle(palette.secondaryText)
                    .frame(maxWidth: .infinity)
                    .aspectRatio(1, contentMode: .fit)
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

                Text("添加")
                    .font(.caption)
                    .foregroundStyle(palette.secondaryText)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(HomeTileButtonStyle())
        .accessibilityLabel("添加书签")
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
                        reloadRecentlyClosed()
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

    private func reloadRecentlyClosed() {
        recentlyClosed = env.tabManager.recentlyClosed.filter { $0.privacyMode == .regular }
    }
}

// MARK: - Add sheet

/// The form behind the "添加" tile.
///
/// Two fields, because a bookmark is a name and an address. The name is
/// optional — an untitled bookmark takes its host, which is what the tiles
/// show anyway.
private struct AddBookmarkSheet: View {
    @Environment(\.dismiss) private var dismiss

    var onAdd: (String, String) -> Void

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
            .navigationTitle("添加书签")
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
        onAdd(url.absoluteString, name.isEmpty ? (url.host ?? url.absoluteString) : name)
        dismiss()
    }
}

/// The press feedback for a home tile.
private struct HomeTileButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.92 : 1)
            .opacity(configuration.isPressed ? 0.7 : 1)
            .animation(.spring(response: 0.24, dampingFraction: 0.72), value: configuration.isPressed)
    }
}
