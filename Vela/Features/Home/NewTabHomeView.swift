//
//  NewTabHomeView.swift
//  Vela
//
//  The native new-tab surface: the user's own favourites, and recently closed
//  tabs.
//
//  The surface is native rather than a web document because there is no
//  custom-homepage runtime to load one into.
//
//  Favourites are their own store, not a view of the bookmarks. The old grid
//  held bookmark ids, so a bookmark rename or deletion reached the home and a
//  home edit reached the bookmarks; the two lists were one list seen twice.
//  A tile is a copy now — its own name, address and name-visibility — and both
//  directions are independent. A bookmark can still be saved *to* the home in
//  the add sheet, but from that moment the tile belongs to the home.
//

import SwiftUI
import UIKit

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
    /// The tile being edited, and whether the sheet is creating a new one.
    @State private var editingFavorite: HomeFavorite?
    @State private var showingNewFavorite = false
    /// The width of the content column, measured once per layout. The
    /// favourites grid uses it to choose a column count that suits the window
    /// instead of always drawing five over-stretched cells.
    @State private var contentWidth: CGFloat = 0
    @State private var recentlyClosed: [RecentlyClosedTabRecord] = []
    /// The custom background, reloaded whenever the settings document's stamp
    /// moves — which happens the moment a picture is saved or cleared behind
    /// the settings sheet, so the change is live without leaving the screen.
    @State private var backgroundImage: UIImage?
    /// Whether the custom picture is bright enough to need dark text.
    @State private var backgroundIsLight = true

    @AppStorage("org.vela.browser.home-bookmarks-expanded") private var favoritesExpanded = true
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
                    .foregroundStyle(homeSecondaryText)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(Capsule().fill(palette.controlFill.opacity(0.6)))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, 2)
                }

                // The home carries its own favourites shelf, and the
                // recently-closed list behind it. The section's plus is how a
                // tile is added without saving a bookmark first — the two
                // stores are independent now, so the home needs its own door
                // in.
                if showsFavoriteSection {
                    favoriteBlock
                }
                if !recentlyClosed.isEmpty {
                    recentlyClosedBlock
                }

                if favorites.isEmpty && recentlyClosed.isEmpty {
                    // An empty home used to be a blank field, which reads as a
                    // failed page rather than a start page. One quiet line is
                    // enough to make the space intentional.
                    VStack(spacing: 14) {
                        AccentGlyphBadge(
                            systemImage: isPrivate ? "eyeglasses" : "safari",
                            size: 76,
                            iconSize: 34
                        )
                        Text(isPrivate ? "无痕浏览" : "开始浏览")
                            .font(.title3.weight(.semibold))
                            .foregroundStyle(homePrimaryText)
                        Text(isPrivate ? "不留下访问记录" : "输入网址，或添加主页收藏")
                            .font(.footnote)
                            .foregroundStyle(homeSecondaryText)
                            .multilineTextAlignment(.center)

                        // 无痕模式 keeps the shelf read-only: adding here would
                        // write a shared favourite from a private session.
                        if !isPrivate {
                            Button {
                                showingNewFavorite = true
                            } label: {
                                Label("添加主页收藏", systemImage: "plus")
                                    .font(.footnote.weight(.semibold))
                                    .foregroundStyle(homePrimaryText)
                                    .padding(.horizontal, 14)
                                    .padding(.vertical, 8)
                                    .background(palette.controlFill.opacity(0.7), in: Capsule())
                            }
                            .buttonStyle(.plain)
                            .padding(.top, 2)
                        }
                    }
                    .shadow(color: homeTextShadow, radius: 8, y: 1)
                    .frame(maxWidth: .infinity)
                    .padding(.top, 28)
                    .padding(.bottom, 40)
                }
            }
            .padding(.horizontal, BrowserSpacing.regular)
            .padding(.top, BrowserSpacing.regular)
            // The extra run of bottom padding is what lets the last block sit
            // clear of the home indicator even though the surface itself runs
            // edge to edge below the safe area.
            .padding(.bottom, BrowserSpacing.loose + 12)
            .background {
                GeometryReader { geo in
                    Color.clear.preference(key: HomeContentWidthKey.self, value: geo.size.width)
                }
            }
            .onPreferenceChange(HomeContentWidthKey.self) { width in
                if abs(width - contentWidth) > 0.5 {
                    contentWidth = width
                }
            }
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
        .task(id: env.settings.preferences.backgroundImageStamp) {
            reloadBackgroundImage()
        }
        .sheet(item: $editingFavorite) { favorite in
            HomeFavoriteEditSheet(favorite: favorite) { title, url, showsTitle in
                env.homeFavorites.update(
                    id: favorite.id,
                    title: title,
                    url: url,
                    showsTitle: showsTitle
                )
            }
            .environment(env)
            .browserAmbientSheet()
        }
        .sheet(isPresented: $showingNewFavorite) {
            HomeFavoriteEditSheet(favorite: nil) { title, url, showsTitle in
                env.homeFavorites.add(url: url, title: title, showsTitle: showsTitle)
            }
            .environment(env)
            .browserAmbientSheet()
        }
    }

    // MARK: - Start page

    /// A start-page section: a larger title and a fold, rather than the small
    /// list header the rest of the app uses. The home is read at a glance and
    /// from further away than a settings row.
    private func homeSection<Content: View>(
        _ title: String,
        count: Int? = nil,
        isExpanded: Binding<Bool>,
        addAction: (() -> Void)? = nil,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: BrowserSpacing.compact + 2) {
            HStack(spacing: 8) {
                Button {
                    withAnimation(.snappy(duration: 0.24)) { isExpanded.wrappedValue.toggle() }
                } label: {
                    HStack(spacing: 7) {
                        Text(title)
                            .font(.title3.weight(.semibold))
                            .foregroundStyle(homePrimaryText)

                        if let count {
                            Text("\(count)")
                                .font(.caption.weight(.medium))
                                .monospacedDigit()
                                .padding(.horizontal, 7)
                                .padding(.vertical, 2)
                                .background(palette.controlFill.opacity(0.75), in: Capsule())
                                .foregroundStyle(homeSecondaryText)
                        }

                        Spacer(minLength: 0)

                        Image(systemName: "chevron.right")
                            .font(.system(size: 12, weight: .bold))
                            .foregroundStyle(homeSecondaryText.opacity(0.65))
                            .rotationEffect(.degrees(isExpanded.wrappedValue ? 90 : 0))
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                // A section that owns its own inventory needs its own way in.
                // The plus is small and sits beside the fold so the title row
                // still reads as one line.
                if let addAction {
                    Button(action: addAction) {
                        Image(systemName: "plus")
                            .font(.system(size: 13, weight: .bold))
                            .foregroundStyle(homeSecondaryText)
                            .frame(width: 28, height: 28)
                            .background(palette.controlFill.opacity(0.75), in: Circle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("添加收藏")
                }
            }

            if isExpanded.wrappedValue {
                content()
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .shadow(color: homeTextShadow, radius: 8, y: 1)
    }

    // MARK: - Background

    /// The home has no backdrop of its own.
    ///
    /// The shell draws the custom picture full-bleed, behind the top bar as
    /// well as the home, and the ambient field when there is no picture. A
    /// second copy here would be scaled to a different rectangle and leave a
    /// seam under the chrome, so the home stays clear.
    private var homeBackground: some View {
        Color.clear
            .ignoresSafeArea()
    }

    /// Text that sits directly on the picture gets its ink from the picture.
    ///
    /// The palette's ink is a reliable contrast against the palette surface,
    /// but not against a photograph: dark-mode white text over a bright sky
    /// disappears. The mean luminance picks black or white, and a soft shadow
    /// in the opposite tone keeps the edge readable across clouds.
    private var homePrimaryText: Color {
        guard backgroundImage != nil else { return palette.primaryText }
        return backgroundIsLight ? Color(white: 0.08) : .white
    }

    private var homeSecondaryText: Color {
        guard backgroundImage != nil else { return palette.secondaryText }
        return backgroundIsLight ? Color(white: 0.26) : .white.opacity(0.86)
    }

    private var homeTextShadow: Color {
        guard backgroundImage != nil else { return .clear }
        return backgroundIsLight ? .white.opacity(0.45) : .black.opacity(0.45)
    }

    private func reloadBackgroundImage() {
        guard let stamp = env.settings.preferences.backgroundImageStamp,
              let image = BackgroundImageStore.load(stamp: stamp) else {
            backgroundImage = nil
            backgroundIsLight = true
            return
        }
        backgroundImage = image
        backgroundIsLight = ChromeBackdrop.topStripIsLight(image) ?? true
    }

    // MARK: - Favourites

    /// The home's own shelf. Reading the service directly is what makes a
    /// rename, a name-visibility flip or a removal repaint the grid without a
    /// reload call at the call site.
    private var favorites: [HomeFavorite] {
        env.homeFavorites.favorites
    }

    /// Whether one tile draws its name. A tile that has never been edited
    /// follows the 外观 ▸ 主页图标 default; once it has an opinion of its own,
    /// that wins.
    private func showsTitle(for favorite: HomeFavorite) -> Bool {
        favorite.showsTitle ?? (env.settings.preferences.homeTileShowsTitle ?? true)
    }

    /// How many favourites fit in a row at the measured width.
    ///
    /// A fixed five columns was fine on a phone and left each tile a huge
    /// square with a 40-point icon floating in it on an iPad. The row is
    /// measured instead, so the grid stays a favourites shelf at every size.
    /// The cell width is fixed (`HomeTileStyle.cellWidth`), which is what
    /// makes 间距 behave like a spacing control rather than like a column
    /// count in disguise.
    private var tileColumnCount: Int {
        HomeTileStyle.columnCount(
            width: contentWidth > 1 ? contentWidth : 360,
            iconSize: tileIconSize,
            spacing: tileSpacing
        )
    }

    /// The width the grid gives one tile.
    private var tileCellWidth: CGFloat {
        HomeTileStyle.cellWidth(iconSize: tileIconSize)
    }

    /// The shelf is on the regular home even when empty if there is anything
    /// else on screen: its header is where the add button lives. A private
    /// home with nothing on it keeps the single quiet empty state.
    private var showsFavoriteSection: Bool {
        !favorites.isEmpty || (!isPrivate && !recentlyClosed.isEmpty)
    }

    /// The plus is a regular-mode affordance: a private session must not
    /// write a shared favourite.
    private var addFavoriteAction: (() -> Void)? {
        guard !isPrivate else { return nil }
        return { showingNewFavorite = true }
    }

    private var favoriteBlock: some View {
        homeSection(
            "收藏",
            isExpanded: $favoritesExpanded,
            addAction: addFavoriteAction
        ) {
            // Laid out in eager rows rather than a lazy grid. A lazy grid that
            // survives a rotation keeps the cell geometry it laid out for the
            // old width — the stranded-rows failure the tab overview fixes by
            // re-keying — and the odd misplaced tile after a turn is exactly
            // that. A favourites collection is short, so laziness buys nothing
            // here and determinism is worth more. Each cell is the same fixed
            // width and the row starts at the section's leading edge, so the
            // spacing between icons is the number the setting names and a
            // short last row still lines up with the rows above it. Centring
            // the row left a wide screen with a shelf floating in the middle
            // of it, away from the 收藏 heading it belongs to.
            VStack(alignment: .leading, spacing: tileSpacing) {
                if favorites.isEmpty {
                    Text("还没有收藏。点右上角的 + 添加。")
                        .font(.footnote)
                        .foregroundStyle(homeSecondaryText)
                        .padding(.vertical, 4)
                } else {
                    ForEach(favoriteRows) { row in
                        HStack(alignment: .top, spacing: tileSpacing) {
                            ForEach(row.favorites) { favorite in
                                favoriteCell(favorite)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
        }
    }

    /// The favourites chunked into rows of `tileColumnCount`.
    private struct FavoriteRow: Identifiable {
        let favorites: [HomeFavorite]
        var id: String { favorites.map(\.id).joined(separator: "-") }
    }

    private var favoriteRows: [FavoriteRow] {
        stride(from: 0, to: favorites.count, by: tileColumnCount).map { start in
            let end = min(start + tileColumnCount, favorites.count)
            return FavoriteRow(favorites: Array(favorites[start..<end]))
        }
    }

    /// The tile customisation from 外观 ▸ 主页图标, resolved to concrete values.
    private var tileIconSize: CGFloat {
        CGFloat(env.settings.preferences.homeTileIconSize ?? 40)
    }

    private var tileSpacing: CGFloat {
        CGFloat(env.settings.preferences.homeTileSpacing ?? 12)
    }

    private var tileCornerRadius: CGFloat? {
        HomeTileStyle.cornerRadius(
            shape: env.settings.preferences.homeTileShape,
            iconSize: tileIconSize
        )
    }

    /// A favourite tile. The icon is the tile; the name below it is a choice
    /// the long-press editor owns. Size, shape and spacing answer to 主页设置;
    /// the tile itself is the shared `HomeFavoriteTile`, so the settings
    /// preview draws the same thing.
    private func favoriteCell(_ favorite: HomeFavorite) -> some View {
        let titleVisible = showsTitle(for: favorite)
        return Button {
            guard let url = BrowserUrlResolver.storedUrl(favorite.url) else { return }
            onNavigate(url)
        } label: {
            HomeFavoriteTile(
                favorite: favorite,
                showsTitle: titleVisible,
                iconSize: tileIconSize,
                cornerRadius: tileCornerRadius,
                titleColor: homePrimaryText,
                titleShadow: homeTextShadow
            )
            .contentShape(Rectangle())
        }
        .frame(width: tileCellWidth)
        .buttonStyle(HomeTileButtonStyle())
        .contextMenu {
            Button("在新标签页打开", systemImage: "plus.square.on.square") {
                guard let url = BrowserUrlResolver.storedUrl(favorite.url) else { return }
                env.tabManager.openTab(
                    url: url,
                    openSource: .shortcut,
                    activate: false
                )
            }
            Button("编辑", systemImage: "pencil") {
                editingFavorite = favorite
            }
            Button(
                titleVisible ? "隐藏名称" : "显示名称",
                systemImage: titleVisible ? "eye.slash" : "eye"
            ) {
                env.homeFavorites.setShowsTitle(id: favorite.id, value: !titleVisible)
            }
            Divider()
            // Removing a tile removes the tile and nothing else. The store is
            // the home's; the bookmark list is a different inventory.
            Button("从主页移除", systemImage: "minus.square", role: .destructive) {
                env.homeFavorites.remove(id: favorite.id)
            }
        }
        .accessibilityLabel(favorite.displayTitle)
    }

    // MARK: - Recently closed

    private var recentlyClosedBlock: some View {
        homeSection(
            "最近关闭",
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
/// The width of the home's content column, reported once per layout so the
/// favourites grid can choose its column count from the real width.
private struct HomeContentWidthKey: PreferenceKey {
    static var defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
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
