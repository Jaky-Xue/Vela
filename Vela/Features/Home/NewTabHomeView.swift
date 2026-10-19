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

    /// Whether this surface is the private mode's home — the ordinary home
    /// and the private one are the same view, and the badge is what tells
    /// them apart on screen.
    var isPrivate: Bool = false

    var onNavigate: (URL) -> Void
    /// A vertical drag on the surface, handed the distance the finger moved:
    /// negative is upward (the page pushed down, the bar away), positive is
    /// downward. The home has no document scroll to read — a short home never
    /// scrolls, and its bounce reports offsets that return to zero — so its
    /// drags are what the command bar listens to.
    var onChromeSwipe: ((CGFloat) -> Void)? = nil

    @State private var bookmarkNodes: [BookmarkNode] = []
    @State private var recentlyClosed: [RecentlyClosedTabRecord] = []
    /// The custom background, reloaded whenever the settings document's stamp
    /// moves — which happens the moment a picture is saved or cleared behind
    /// the settings sheet, so the change is live without leaving the screen.
    @State private var backgroundImage: UIImage?

    @AppStorage("org.vela.browser.home-bookmarks-expanded") private var bookmarksExpanded = true
    @AppStorage("org.vela.browser.home-recently-closed-expanded") private var recentlyClosedExpanded = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: BrowserSpacing.loose) {
                if isPrivate {
                    HStack(spacing: 6) {
                        Image(systemName: "eyeglasses")
                        Text("无痕模式")
                    }
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(palette.secondaryText)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(Capsule().fill(palette.controlFill.opacity(0.6)))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, 2)
                }
                // The home carries what the user has saved: the favourites
                // grid, and the recently-closed list behind it. There is no
                // add tile — a bookmark joins the home when it is added, so
                // an empty collection hides its section rather than offering
                // a control the flow no longer needs.
                if !bookmarkNodes.isEmpty {
                    bookmarkBlock
                }
                if !recentlyClosed.isEmpty {
                    recentlyClosedBlock
                }

                if bookmarkNodes.isEmpty && recentlyClosed.isEmpty {
                    // An empty home used to be a blank field, which reads as a
                    // failed page rather than a start page. One quiet line is
                    // enough to make the space intentional.
                    VStack(spacing: 12) {
                        Image(systemName: isPrivate ? "eyeglasses" : "safari")
                            .font(.system(size: 38, weight: .light))
                            .foregroundStyle(palette.secondaryText.opacity(0.55))
                        Text(isPrivate ? "无痕浏览" : "开始浏览")
                            .font(.title3.weight(.semibold))
                            .foregroundStyle(palette.primaryText)
                        Text(isPrivate
                             ? "这个标签页的访问记录不会留下。"
                             : "从地址栏输入网址；把常用网站加入收藏后会出现在这里。")
                            .font(.footnote)
                            .foregroundStyle(palette.secondaryText)
                            .multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.top, 64)
                    .padding(.bottom, 40)
                }
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
        // The bar hides on a drag the way it hides on a page's scroll: up
        // moves the page out of the way, down brings it back. The flick's
        // predicted distance joins in so a short throw still carries.
        .simultaneousGesture(
            DragGesture(minimumDistance: 24)
                .onEnded { value in
                    let vertical = value.translation.height
                    guard abs(vertical) > abs(value.translation.width) else { return }
                    let predicted = value.predictedEndTranslation.height
                    onChromeSwipe?(abs(predicted) > abs(vertical) ? predicted : vertical)
                }
        )
        .task(id: env.settings.preferences.homeBackgroundStamp) {
            reloadBackgroundImage()
        }
        .onAppear {
            loadBookmarks()
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
            // The shell's ambient background is the home's backdrop; a second
            // opaque surface here would cover exactly the light the background
            // style exists to show.
            Color.clear
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

    /// The favourites grid's row width, in tiles — five flexible slots, what
    /// a home screen's density reads as.
    static let tileColumnCount = 5

    private var bookmarkBlock: some View {
        CollapsibleSection(
            title: "收藏",
            systemImage: nil,
            count: nil,
            isExpanded: $bookmarksExpanded
        ) {
            // Laid out in eager rows rather than a lazy grid. A lazy grid that
            // survives a rotation keeps the cell geometry it laid out for the
            // old width — the stranded-rows failure the tab overview fixes by
            // re-keying — and the odd misplaced tile after a turn is exactly
            // that. A favourites collection is short, so laziness buys nothing
            // here and determinism is worth more. Five slots to a row, the
            // tail padded with spacers, so every tile keeps the width a full
            // row gives it however many tiles the last row holds.
            VStack(spacing: tileSpacing) {
                ForEach(bookmarkRows) { row in
                    HStack(spacing: tileSpacing) {
                        ForEach(row.nodes) { node in
                            bookmarkCell(node)
                        }
                        ForEach(0..<(Self.tileColumnCount - row.nodes.count), id: \.self) { _ in
                            Color.clear
                                .frame(maxWidth: .infinity)
                        }
                    }
                }
            }
        }
    }

    /// The favourites chunked into rows of five.
    private struct BookmarkRow: Identifiable {
        let nodes: [BookmarkNode]
        var id: String { nodes.map(\.id).joined(separator: "-") }
    }

    private var bookmarkRows: [BookmarkRow] {
        stride(from: 0, to: bookmarkNodes.count, by: Self.tileColumnCount).map { start in
            BookmarkRow(nodes: Array(bookmarkNodes[start..<min(start + Self.tileColumnCount, bookmarkNodes.count)]))
        }
    }

    /// The tile customisation from 主页 settings, resolved to concrete values.
    private var tileIconSize: CGFloat {
        CGFloat(env.settings.preferences.homeTileIconSize ?? 40)
    }

    private var tileSpacing: CGFloat {
        CGFloat(env.settings.preferences.homeTileSpacing ?? 12)
    }

    /// The chosen shape, as the corner radius the icon tile is drawn with.
    /// A square tile at half its size in radius is a circle, so the three
    /// settings land on three radii and nothing else about the tile changes.
    private var tileCornerRadius: CGFloat? {
        switch env.settings.preferences.homeTileShape ?? "rounded" {
        case "circle": return tileIconSize / 2
        case "square": return 3
        default: return nil
        }
    }

    /// A bookmark tile: the site's icon on its own uniform tile, and nothing
    /// else — the icon is the label, the way a home screen reads. Size, shape
    /// and spacing answer to 主页 settings; the tile itself is the icon
    /// component's, so every favourite reads as one shelf of equals.
    private func bookmarkCell(_ node: BookmarkNode) -> some View {
        Button {
            guard let url = BrowserUrlResolver.storedUrl(node.url) else { return }
            onNavigate(url)
        } label: {
            SiteIconView(
                host: node.displayHost,
                size: tileIconSize,
                cornerRadius: tileCornerRadius
            )
            .frame(maxWidth: .infinity)
            .aspectRatio(1, contentMode: .fit)
            .contentShape(Rectangle())
        }
        .buttonStyle(HomeTileButtonStyle())
        .contextMenu {
            Button("在新标签页打开", systemImage: "plus.square.on.square") {
                guard let url = BrowserUrlResolver.storedUrl(node.url) else { return }
                env.tabManager.openTab(
                    url: url,
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
                            // The mode routes the restore: a page opened from
                            // the home is a new page like any other.
                            env.tabManager.openTab(
                                url: url,
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
/// The press feedback for a home tile.
private struct HomeTileButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.92 : 1)
            .opacity(configuration.isPressed ? 0.7 : 1)
            .animation(.spring(response: 0.24, dampingFraction: 0.72), value: configuration.isPressed)
    }
}
