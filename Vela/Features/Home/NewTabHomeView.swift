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
    var settings: SettingsService
    var favoritesService: HomeFavoritesService
    var tabManager: TabManager
    @Environment(\.browserPalette) private var palette
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

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

    /// The coordinate space the shelf reports its slots in, and the one a
    /// carried tile is drawn in.
    private static let favoriteDragSpace = "vela.home.favorites"
    /// The tile under the finger, once a long press has lifted it.
    @State private var draggingFavoriteID: String?
    @State private var favoriteDragTranslation: CGSize = .zero
    @State private var favoriteDragStartCenter: CGPoint = .zero
    @State private var favoriteDragStartSize: CGSize = .zero
    /// The shelf's frame and the height each cell asked for, both in
    /// `favoriteDragSpace`. Slot geometry is derived from these rather than
    /// from the tiles' own frames, which are mid-flight during a reorder.
    @State private var favoriteGridFrame: CGRect = .zero
    @State private var favoriteCellHeights: [Int: CGFloat] = [:]
    /// A drag ends by lifting the finger: that release is not a tap, and its
    /// vertical travel is not a chrome swipe either.
    @State private var suppressFavoriteTap = false
    @State private var suppressChromeSwipe = false
    /// Derived from the current privacy boundary, never a stale copy of regular data.
    var recentlyClosed: [RecentlyClosedTabRecord] {
        isPrivate ? [] : tabManager.recentlyClosed.filter { $0.privacyMode == .regular }
    }
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
        }
        // The surface reaches the bottom edge of the screen: a strip of dead
        // background above the home indicator reads as something sitting on
        // top of the page, which is exactly what the user called occlusion.
        .ignoresSafeArea(edges: .bottom)
        .coordinateSpace(.named(Self.favoriteDragSpace))
        // The carried tile is a sibling of the scroll view rather than a child
        // of it, so the shelf's own clip cannot cut it off at the edge.
        .overlay(alignment: .topLeading) { floatingFavoriteLayer }
        // The carried tile owns the finger; a scroll underneath it would move
        // every slot the tile is being aimed at.
        .scrollDisabled(draggingFavoriteID != nil)
        .background { homeBackground }
        .scrollDismissesKeyboard(.immediately)
        // The bar hides on a drag the way it hides on a page's scroll: up
        // moves the page out of the way, down brings it back. The flick's
        // predicted distance joins in so a short throw still carries.
        .simultaneousGesture(
            DragGesture(minimumDistance: 24)
                .onEnded { value in
                    // Carrying a tile up or down the shelf is a reorder, not a
                    // request to push the command bar away.
                    guard !suppressChromeSwipe else { return }
                    let vertical = value.translation.height
                    guard abs(vertical) > abs(value.translation.width) else { return }
                    let predicted = value.predictedEndTranslation.height
                    onChromeSwipe?(abs(predicted) > abs(vertical) ? predicted : vertical)
                }
        )
        .task(id: settings.preferences.backgroundImageStamp) {
            reloadBackgroundImage()
        }
        .sheet(item: $editingFavorite) { favorite in
            HomeFavoriteEditSheet(settings: settings, favorite: favorite) { title, url, showsTitle in
                favoritesService.update(
                    id: favorite.id,
                    title: title,
                    url: url,
                    showsTitle: showsTitle
                )
            }
            .browserAmbientSheet()
        }
        .sheet(isPresented: $showingNewFavorite) {
            HomeFavoriteEditSheet(settings: settings, favorite: nil) { title, url, showsTitle in
                favoritesService.add(url: url, title: title, showsTitle: showsTitle)
            }
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
        guard let stamp = settings.preferences.backgroundImageStamp,
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
        isPrivate ? [] : favoritesService.favorites
    }

    /// Whether one tile draws its name. A tile that has never been edited
    /// follows the 外观 ▸ 主页图标 default; once it has an opinion of its own,
    /// that wins.
    private func showsTitle(for favorite: HomeFavorite) -> Bool {
        favorite.showsTitle ?? (settings.preferences.homeTileShowsTitle ?? true)
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
                    // The same fixed-width cells the lazy grid drew, but
                    // placed by the layout itself so a reorder is one animated
                    // frame change per tile and the rows shift together.
                    HomeFavoriteGridLayout(
                        cellWidth: tileCellWidth,
                        spacing: tileSpacing
                    ) {
                        ForEach(Array(favorites.enumerated()), id: \.element.id) { index, favorite in
                            favoriteCell(favorite, index: index)
                        }
                    }
                    .background {
                        GeometryReader { proxy in
                            Color.clear.preference(
                                key: HomeFavoriteGridFrameKey.self,
                                value: proxy.frame(in: CoordinateSpace.named(Self.favoriteDragSpace))
                            )
                        }
                    }
                    .onPreferenceChange(HomeFavoriteCellHeightKey.self) { heights in
                        favoriteCellHeights = heights
                    }
                    .onPreferenceChange(HomeFavoriteGridFrameKey.self) { frame in
                        favoriteGridFrame = frame
                    }
                    // Tiles appearing and disappearing animate; a reorder is
                    // already inside its own spring and is not keyed on the
                    // count.
                    .animation(BrowserMotion.layout(reduceMotion), value: favorites.count)
                }
            }
        }
    }

    /// The tile customisation from 外观 ▸ 主页图标, resolved to concrete values.
    private var tileIconSize: CGFloat {
        CGFloat(settings.preferences.homeTileIconSize ?? 40)
    }

    private var tileSpacing: CGFloat {
        CGFloat(settings.preferences.homeTileSpacing ?? 12)
    }

    private var tileCornerRadius: CGFloat? {
        HomeTileStyle.cornerRadius(
            shape: settings.preferences.homeTileShape,
            iconSize: tileIconSize
        )
    }

    /// A favourite tile. The icon is the tile; the name below it is a choice
    /// the long-press editor owns. Size, shape and spacing answer to 主页设置;
    /// the tile itself is the shared `HomeFavoriteTile`, so the settings
    /// preview draws the same thing.
    private func favoriteCell(_ favorite: HomeFavorite, index: Int) -> some View {
        let titleVisible = showsTitle(for: favorite)
        return Button {
            // A long press already carried this tile; the release that ended
            // it is not a tap.
            if suppressFavoriteTap {
                suppressFavoriteTap = false
                return
            }
            guard draggingFavoriteID == nil else { return }
            guard let url = BrowserUrlResolver.storedUrl(favorite.url) else { return }
            onNavigate(url)
        } label: {
            favoriteTileLabel(favorite, showsTitle: titleVisible)
        }
        .frame(width: tileCellWidth)
        .buttonStyle(HomeTileButtonStyle())
        // The carried copy is the only tile the finger can see; the slot keeps
        // its space as a gap the other tiles slide around.
        .opacity(draggingFavoriteID == favorite.id ? 0 : 1)
        .simultaneousGesture(favoriteDragGesture(favorite))
        .background {
            GeometryReader { proxy in
                Color.clear.preference(
                    key: HomeFavoriteCellHeightKey.self,
                    value: [index: proxy.size.height]
                )
            }
        }
        .contextMenu {
            Button("在新标签页打开", systemImage: "plus.square.on.square") {
                guard let url = BrowserUrlResolver.storedUrl(favorite.url) else { return }
                tabManager.openTab(
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
                favoritesService.setShowsTitle(id: favorite.id, value: !titleVisible)
            }
            Divider()
            // Removing a tile removes the tile and nothing else. The store is
            // the home's; the bookmark list is a different inventory.
            Button("从主页移除", systemImage: "minus.square", role: .destructive) {
                favoritesService.remove(id: favorite.id)
            }
        }
        .accessibilityLabel(favorite.displayTitle)
        .accessibilityHint(draggingFavoriteID == nil ? "长按并拖动可排序" : "")
    }

    /// The tile itself, without the button or the gesture: the shelf draws it
    /// in its slot, and the floating copy draws the same view at the finger.
    private func favoriteTileLabel(_ favorite: HomeFavorite, showsTitle: Bool) -> some View {
        HomeFavoriteTile(
            favorite: favorite,
            showsTitle: showsTitle,
            iconSize: tileIconSize,
            cornerRadius: tileCornerRadius,
            titleColor: homePrimaryText,
            titleShadow: homeTextShadow
        )
        .contentShape(Rectangle())
    }

    // MARK: - Carrying a favourite

    /// The tile the finger is carrying, drawn at the finger rather than in its
    /// slot, exactly like the menu panel's tiles.
    @ViewBuilder
    private var floatingFavoriteLayer: some View {
        if let id = draggingFavoriteID,
           let favorite = favorites.first(where: { $0.id == id }) {
            favoriteTileLabel(favorite, showsTitle: showsTitle(for: favorite))
                .frame(width: favoriteDragStartSize.width, height: favoriteDragStartSize.height)
                .scaleEffect(reduceMotion ? 1 : 1.06)
                .shadow(color: Color.black.opacity(0.3), radius: 14, y: 7)
                .opacity(0.94)
                .allowsHitTesting(false)
                .position(
                    x: favoriteDragStartCenter.x + favoriteDragTranslation.width,
                    y: favoriteDragStartCenter.y + favoriteDragTranslation.height
                )
                .transition(.scale(scale: 0.88).combined(with: .opacity))
        }
    }

    /// The shelf's cell geometry, derived from what the grid reported.
    private struct FavoriteGridGeometry {
        var columns: Int
        var cellWidth: CGFloat
        var rowHeights: [CGFloat]
        var origin: CGPoint
    }

    private var favoriteGridGeometry: FavoriteGridGeometry? {
        guard favoriteGridFrame.width > 1, !favorites.isEmpty else { return nil }
        let columns = HomeTileStyle.columnCount(
            width: favoriteGridFrame.width,
            cellWidth: tileCellWidth,
            spacing: tileSpacing
        )
        var rowHeights: [CGFloat] = []
        var index = 0
        while index < favorites.count {
            var height: CGFloat = 0
            for cellIndex in index..<min(index + columns, favorites.count) {
                height = max(height, favoriteCellHeights[cellIndex] ?? 0)
            }
            // The first frame has not measured the cells yet; a drag that
            // cannot compute a slot must not start.
            guard height > 0 else { return nil }
            rowHeights.append(height)
            index += columns
        }
        return FavoriteGridGeometry(
            columns: columns,
            cellWidth: tileCellWidth,
            rowHeights: rowHeights,
            origin: favoriteGridFrame.origin
        )
    }

    private func favoriteSlotCenter(at index: Int) -> CGPoint? {
        guard let geometry = favoriteGridGeometry, index < favorites.count else { return nil }
        let row = index / geometry.columns
        let column = index % geometry.columns
        var y = geometry.origin.y
        for earlierRow in 0..<row {
            y += geometry.rowHeights[earlierRow] + tileSpacing
        }
        return CGPoint(
            x: geometry.origin.x + CGFloat(column) * (geometry.cellWidth + tileSpacing) + geometry.cellWidth / 2,
            y: y + geometry.rowHeights[row] / 2
        )
    }

    private func favoriteSlotIndex(at point: CGPoint, count: Int) -> Int? {
        guard let geometry = favoriteGridGeometry, count > 0, !geometry.rowHeights.isEmpty else { return nil }
        let column = min(
            max(Int((point.x - geometry.origin.x) / (geometry.cellWidth + tileSpacing)), 0),
            geometry.columns - 1
        )
        var y = geometry.origin.y
        var row = 0
        while row < geometry.rowHeights.count - 1, point.y >= y + geometry.rowHeights[row] + tileSpacing / 2 {
            y += geometry.rowHeights[row] + tileSpacing
            row += 1
        }
        return min(row * geometry.columns + column, count - 1)
    }

    private func favoriteDragGesture(_ favorite: HomeFavorite) -> some Gesture {
        LongPressGesture(minimumDuration: 0.32)
            .sequenced(before: DragGesture(minimumDistance: 0, coordinateSpace: .named(Self.favoriteDragSpace)))
            .onChanged { value in
                guard !isPrivate, case .second(true, let drag?) = value else { return }
                // A long press that stays where it started is the tile's
                // context menu; picking the tile up waits for real movement.
                let dx = drag.translation.width
                let dy = drag.translation.height
                guard dx * dx + dy * dy > 36 else { return }
                beginFavoriteDrag(favorite)
                moveFavorite(favorite, translation: drag.translation, at: drag.location)
            }
            .onEnded { _ in
                endFavoriteDrag()
            }
    }

    private func beginFavoriteDrag(_ favorite: HomeFavorite) {
        guard draggingFavoriteID == nil,
              let index = favorites.firstIndex(where: { $0.id == favorite.id }),
              let center = favoriteSlotCenter(at: index),
              let geometry = favoriteGridGeometry else { return }
        favoriteDragStartCenter = center
        favoriteDragStartSize = CGSize(
            width: geometry.cellWidth,
            height: geometry.rowHeights[index / geometry.columns]
        )
        suppressFavoriteTap = true
        suppressChromeSwipe = true
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        draggingFavoriteID = favorite.id
    }

    private func moveFavorite(_ favorite: HomeFavorite, translation: CGSize, at finger: CGPoint) {
        guard draggingFavoriteID == favorite.id else { return }
        favoriteDragTranslation = translation
        guard let source = favorites.firstIndex(where: { $0.id == favorite.id }),
              let slot = favoriteSlotIndex(at: finger, count: favorites.count),
              slot != source else { return }
        // SwiftUI's move semantics: an item moving forwards lands after the
        // slot it was dragged over, one moving backwards lands on it.
        let destination = source < slot ? slot + 1 : slot
        withAnimation(BrowserMotion.tileDrag(reduceMotion)) {
            favoritesService.move(fromOffsets: IndexSet(integer: source), toOffset: destination)
        }
    }

    private func endFavoriteDrag() {
        guard draggingFavoriteID != nil else { return }
        withAnimation(reduceMotion ? nil : .spring(response: 0.3, dampingFraction: 0.88)) {
            draggingFavoriteID = nil
            favoriteDragTranslation = .zero
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
            suppressFavoriteTap = false
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
            suppressChromeSwipe = false
        }
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
                            tabManager.openTab(
                                url: url,
                                openSource: .restore
                            )
                        }
                        tabManager.removeRecentlyClosedRecord(id: record.id)
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

}

// MARK: - Grid layout

/// Places the favourites shelf in fixed-width cells, one row at a time.
///
/// `LazyVGrid` laid the shelf out before; it only places the cells it has
/// built, and a reorder across rows it never built cannot animate as one
/// movement. Every slot here is arithmetic, so dragging a tile moves the whole
/// shelf — including the rows below — in the same spring. Rows keep their own
/// heights because a tile may hide its name, which is why the pitch is not a
/// single constant.
private struct HomeFavoriteGridLayout: Layout {
    var cellWidth: CGFloat
    var spacing: CGFloat

    private var gap: CGFloat { max(0, spacing) }

    private struct Metrics {
        var columns: Int
        var rowHeights: [CGFloat]
    }

    private func metrics(for width: CGFloat, subviews: Subviews) -> Metrics {
        let columns = HomeTileStyle.columnCount(width: width, cellWidth: cellWidth, spacing: gap)
        var rowHeights: [CGFloat] = []
        var index = 0
        while index < subviews.count {
            let end = min(index + columns, subviews.count)
            var height: CGFloat = 0
            for cellIndex in index..<end {
                height = max(
                    height,
                    subviews[cellIndex].sizeThatFits(ProposedViewSize(width: cellWidth, height: nil)).height
                )
            }
            rowHeights.append(height)
            index = end
        }
        return Metrics(columns: columns, rowHeights: rowHeights)
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout Void) -> CGSize {
        let width = proposal.width ?? 0
        let metrics = metrics(for: width, subviews: subviews)
        guard !metrics.rowHeights.isEmpty else { return CGSize(width: width, height: 0) }
        let height = metrics.rowHeights.reduce(0, +) + gap * CGFloat(metrics.rowHeights.count - 1)
        return CGSize(width: width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout Void) {
        let metrics = metrics(for: bounds.width, subviews: subviews)
        var y = bounds.minY
        for row in metrics.rowHeights.indices {
            let height = metrics.rowHeights[row]
            for column in 0..<metrics.columns {
                let index = row * metrics.columns + column
                guard index < subviews.count else { break }
                subviews[index].place(
                    at: CGPoint(
                        x: bounds.minX + CGFloat(column) * (cellWidth + gap) + cellWidth / 2,
                        y: y + height / 2
                    ),
                    anchor: .center,
                    proposal: ProposedViewSize(width: cellWidth, height: height)
                )
            }
            y += height + gap
        }
    }
}

/// The height one cell asked for, by its place in the shelf. Heights do not
/// change while a drag animates, which is what lets the slot arithmetic ignore
/// the tiles' moving frames.
private struct HomeFavoriteCellHeightKey: PreferenceKey {
    static var defaultValue: [Int: CGFloat] = [:]
    static func reduce(value: inout [Int: CGFloat], nextValue: () -> [Int: CGFloat]) {
        value.merge(nextValue(), uniquingKeysWith: { $1 })
    }
}

/// Where the shelf itself sits on the home, once its width has settled.
private struct HomeFavoriteGridFrameKey: PreferenceKey {
    static var defaultValue: CGRect = .zero
    static func reduce(value: inout CGRect, nextValue: () -> CGRect) {
        let next = nextValue()
        if next != .zero {
            value = next
        }
    }
}

/// The press feedback for a home tile.
private struct HomeTileButtonStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.92 : 1)
            .opacity(configuration.isPressed ? 0.7 : 1)
            .animation(reduceMotion ? nil : .spring(response: 0.24, dampingFraction: 0.72), value: configuration.isPressed)
    }
}
