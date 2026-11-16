//
//  MenuPanelView.swift
//  Vela
//
//  The panel the menu button opens.
//
//  A grid of icon tiles rather than the system's stacked text buttons: a
//  browser's menu holds twenty-odd destinations, and a sheet that lists them
//  as rows either scrolls or truncates. The grid shows the user's arrangement
//  at once, with the actions that need a page greyed out on the surfaces that
//  have none — which is how the user learns what is available without tapping
//  it.
//
//  The panel edits itself. The 编辑 button in the header turns the grid into
//  the same reorderable list 设置 ▸ 菜单面板 used to be the only way to reach:
//  rows drag, the red minus hides a built-in (a shortcut is deleted), hidden
//  tiles are one tap from returning, and a new URL shortcut is created here.
//  Opening 设置 to rearrange the menu was a detour for a control the user was
//  already looking at.
//
//  Script commands belong to site details; this panel only presents browser actions.
//

import SwiftUI
import UIKit

/// The menu panel: a header row, the grid of tiles, and the editor behind the
/// pencil.
struct MenuPanelView: View {
    var settings: SettingsService
    @Environment(\.browserPalette) private var palette

    /// Whether the panel's target is a loaded page — `false` greys out every
    /// action that needs one.
    var canActOnPage: Bool
    /// Whether the browser is in private mode, which adds the private-session
    /// exit to the private-tab tile's long-press menu.
    var isPrivateMode: Bool
    /// Whether 无痕模式 is on — the tile is a switch, and this is its state.
    var isPrivateBrowsingOn: Bool
    /// Whether the current site has been given an explicit 桌面版 answer. The
    /// automatic identity does not light this tile: a desktop identity the
    /// device chose for itself is not a switch the user turned on.
    var isDesktopSiteOn: Bool = false
    /// Clears the current site's 桌面/手机 choice. The panel does not know the
    /// host; the shell holds the tab and supplies the action.
    var onResetSiteDisplay: (() -> Void)? = nil
    /// What the panel is acting on — the page's title, or "菜单" on a
    /// page-less surface. Drawn in the header row.
    var pageTitle: String
    var onPerform: (VelaMenuAction) -> Void
    var onOpenShortcut: (MenuShortcut) -> Void
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    /// Whether the panel is showing its editor instead of its grid.
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isEditing = false
    @State private var showingShortcutEditor = false

    /// The coordinate space the grid reports its slots in, and the one the
    /// carried tile is drawn in.
    private static let panelSpace = "vela.menu.panel"

    /// The tile under the finger, once a long press has lifted it.
    @State private var draggingTileID: String?
    @State private var dragTranslation: CGSize = .zero
    @State private var dragStartCenter: CGPoint = .zero
    @State private var dragStartSize: CGSize = .zero
    /// The grid's frame and the height of one cell, both in `panelSpace`.
    /// Slot geometry is derived from these rather than from the tiles' own
    /// frames: a tile in flight under the finger would otherwise report a
    /// position between two slots and reorder the grid a second time.
    @State private var gridFrame: CGRect = .zero
    @State private var cellContentHeight: CGFloat = 0
    /// A drag ends by lifting the finger, and that release must not also run
    /// the tile's action.
    @State private var suppressTileTap = false

    private var columnSpacing: CGFloat { BrowserSpacing.compact }
    private var rowSpacing: CGFloat { BrowserSpacing.regular + 2 }
    private var minimumCellWidth: CGFloat { dynamicTypeSize.isAccessibilitySize ? 120 : 58 }

    /// The grid's cell geometry, derived from the width it was laid out at.
    private struct GridMetrics {
        var columns: Int
        var cellWidth: CGFloat
        var cellHeight: CGFloat
        var origin: CGPoint
    }

    private var gridMetrics: GridMetrics? {
        let contentWidth = min(gridFrame.width, 390)
        guard contentWidth > 0, cellContentHeight > 0 else { return nil }
        let columns = max(1, Int((contentWidth + columnSpacing) / (minimumCellWidth + columnSpacing)))
        let cellWidth = (contentWidth - columnSpacing * CGFloat(columns - 1)) / CGFloat(columns)
        guard cellWidth > 0 else { return nil }
        return GridMetrics(
            columns: columns,
            cellWidth: cellWidth,
            cellHeight: cellContentHeight,
            origin: CGPoint(
                x: gridFrame.minX + (gridFrame.width - contentWidth) / 2,
                y: gridFrame.minY
            )
        )
    }

    /// The centre of one slot, in the order the grid currently shows.
    private func slotCenter(at index: Int) -> CGPoint? {
        guard let metrics = gridMetrics else { return nil }
        let row = index / metrics.columns
        let column = index % metrics.columns
        return CGPoint(
            x: metrics.origin.x + CGFloat(column) * (metrics.cellWidth + columnSpacing) + metrics.cellWidth / 2,
            y: metrics.origin.y + CGFloat(row) * (metrics.cellHeight + rowSpacing) + metrics.cellHeight / 2
        )
    }

    /// The slot a point falls in. Points past the last row resolve to the last
    /// slot, so carrying a tile below the grid sends it to the end.
    private func slotIndex(at point: CGPoint, count: Int) -> Int? {
        guard let metrics = gridMetrics, count > 0 else { return nil }
        let column = min(
            max(Int((point.x - metrics.origin.x) / (metrics.cellWidth + columnSpacing)), 0),
            metrics.columns - 1
        )
        let row = max(Int((point.y - metrics.origin.y) / (metrics.cellHeight + rowSpacing)), 0)
        return min(row * metrics.columns + column, count - 1)
    }

    /// The live arrangement. Reading the settings service rather than a value
    /// passed in is what makes an edit repaint the grid behind it.
    private var layout: MenuLayout { settings.menuLayout }
    private var tiles: [MenuTile] { layout.visibleTiles }
    /// The editor is a list with drag handles and its own sections; the compact
    /// detent is too short to drag in without hunting for the row.
    private var panelDetents: Set<PresentationDetent> {
        isEditing || dynamicTypeSize.isAccessibilitySize ? [.medium, .large] : [.height(460), .large]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: BrowserSpacing.regular) {
            Capsule()
                .fill(palette.secondaryText.opacity(0.35))
                .frame(width: 36, height: 4)
                .frame(maxWidth: .infinity)
                .padding(.top, 8)

            if isEditing {
                editingHeader
                editingList
            } else {
                headerRow
                tileGrid

            }
        }
        .frame(maxWidth: .infinity)
        .coordinateSpace(.named(Self.panelSpace))
        // Drawn above the scroll view rather than inside it, so a tile carried
        // to the panel's edge is not cut off by the scroll view's clip.
        .overlay(alignment: .topLeading) { floatingTileLayer }
        .background { AmbientSurfaceFill(opacity: palette.visualStyle.menuVeil) }
        .presentationDetents(panelDetents)
        .presentationDragIndicator(.hidden)
        .sheet(isPresented: $showingShortcutEditor) {
            MenuShortcutEditorView { shortcut in
                showingShortcutEditor = false
                guard let shortcut else { return }
                settings.menuLayout = layout.adding(shortcut)
            }
            .browserAmbientSheet()
        }
    }

    // MARK: - Grid

    /// The tiles, laid out by `MenuTileGridLayout`.
    ///
    /// Not a lazy grid: a lazy grid re-lays out only the cells it has built,
    /// and a reorder would then move the visible tiles in a way the carried
    /// tile cannot follow. The custom layout measures one cell and places
    /// every tile in its slot itself, so a reorder is one animated frame
    /// change per tile and the rows shift together.
    private var tileGrid: some View {
        ScrollView {
            if tiles.isEmpty {
                Text("暂无菜单")
                    .font(.footnote)
                    .foregroundStyle(palette.secondaryText)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, BrowserSpacing.loose)
                    .padding(.horizontal, BrowserSpacing.regular)
            } else {
                MenuTileGridLayout(
                    minimumCellWidth: minimumCellWidth,
                    columnSpacing: columnSpacing,
                    rowSpacing: rowSpacing,
                    maximumWidth: 390
                ) {
                    ForEach(tiles) { tile in
                        menuItem(tile)
                    }
                }
                .background {
                    GeometryReader { proxy in
                        Color.clear.preference(
                            key: MenuGridFrameKey.self,
                            value: proxy.frame(in: CoordinateSpace.named(Self.panelSpace))
                        )
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.horizontal, BrowserSpacing.regular)
                .padding(.bottom, BrowserSpacing.compact)
                .onPreferenceChange(MenuCellHeightKey.self) { height in
                    cellContentHeight = height
                }
                .onPreferenceChange(MenuGridFrameKey.self) { frame in
                    gridFrame = frame
                }
            }
        }
        // The carried tile owns the finger; a page scroll underneath it would
        // move every slot the tile is being aimed at.
        .scrollDisabled(draggingTileID != nil)
    }

    /// The tile the finger is carrying, drawn at the finger rather than in its
    /// slot. Nothing clips it: it is a sibling of the grid, not a child of the
    /// scroll view, and it carries a shadow so it reads as lifted.
    @ViewBuilder
    private var floatingTileLayer: some View {
        if let id = draggingTileID, let tile = tiles.first(where: { $0.id == id }) {
            menuTileLabel(tile, enabled: canActOnPage || !tile.requiresPage)
                .frame(width: dragStartSize.width, height: dragStartSize.height)
                .scaleEffect(reduceMotion ? 1 : 1.06)
                .shadow(color: Color.black.opacity(0.3), radius: 14, y: 7)
                .opacity(0.94)
                .allowsHitTesting(false)
                .position(
                    x: dragStartCenter.x + dragTranslation.width,
                    y: dragStartCenter.y + dragTranslation.height
                )
                .transition(.scale(scale: 0.88).combined(with: .opacity))
        }
    }

    private var headerRow: some View {
        HStack(spacing: BrowserSpacing.compact) {
            Text("菜单")
                .font(.headline)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)

            Button {
                withAnimation(reduceMotion ? nil : .snappy(duration: 0.22)) { isEditing = true }
            } label: {
                Text("编辑")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(palette.primaryText)
                    .padding(.horizontal, 14)
                    .frame(height: 44)
                    .background(palette.controlFill, in: Capsule())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("编辑菜单")

            Button {
                onPerform(.settings)
            } label: {
                Image(systemName: "gearshape")
                    .font(.headline)
                    .foregroundStyle(palette.primaryText)
                    .frame(width: 36, height: 36)
                    .background(palette.controlFill, in: Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("设置")
        }
        .padding(.horizontal, BrowserSpacing.regular)
    }

    private func menuItem(_ tile: MenuTile) -> some View {
        let enabled = canActOnPage || !tile.requiresPage
        return Button {
            // A long press already carried this tile; the release that ended
            // it is not a tap.
            if suppressTileTap {
                suppressTileTap = false
                return
            }
            guard enabled, draggingTileID == nil else { return }
            switch tile {
            case let .action(action):
                onPerform(action)
            case let .shortcut(shortcut):
                onOpenShortcut(shortcut)
            }
        } label: {
            menuTileLabel(tile, enabled: enabled)
        }
        .buttonStyle(MenuTileButtonStyle(enabled: enabled))
        // The carried copy is the only tile the finger can see; the slot keeps
        // its space as a gap the other tiles slide around.
        .opacity(draggingTileID == tile.id ? 0 : 1)
        .simultaneousGesture(dragGesture(for: tile))
        .background {
            GeometryReader { proxy in
                Color.clear.preference(
                    key: MenuCellHeightKey.self,
                    value: proxy.size.height
                )
            }
        }
        .contextMenu {
            if tile.action == .privateTab && isPrivateMode {
                Button("退出无痕", systemImage: "eyeglasses.slash", role: .destructive) {
                    onPerform(.leavePrivate)
                }
            }
            if tile.action == .desktopSite, let onResetSiteDisplay {
                Button("自动模式", systemImage: "arrow.uturn.backward") {
                    onResetSiteDisplay()
                }
            }
        }
        .accessibilityLabel(tile.title)
        .accessibilityValue(
            (tile.action == .privateTab || tile.action == .desktopSite)
                ? (modeIsOn(tile) ? "已开启" : "已关闭")
                : ""
        )
        .accessibilityHint(draggingTileID == nil ? "长按并拖动可排序" : "")
    }

    /// The tile itself, without the button or the gesture: the grid draws it
    /// in its slot, and the floating copy draws the same view at the finger,
    /// so what the user carries is exactly what they lifted.
    private func menuTileLabel(_ tile: MenuTile, enabled: Bool) -> some View {
        // The two switches draw their state on the tile: a filled accent
        // square and its inverted glyph, with no badge to read around.
        let isModeOn = modeIsOn(tile)
        return VStack(spacing: 7) {
            Image(systemName: tile.symbolName)
                .font(.system(size: 21, weight: .semibold))
                .symbolRenderingMode(.monochrome)
                .foregroundStyle(palette.primaryText)
                // Capped rather than fixed: a five-column grid on a
                // 320-point phone gives a cell a little under 54 points,
                // and a hard 54 would push neighbouring tiles apart.
                .frame(maxWidth: 54, minHeight: 54, maxHeight: 54)
                .background(
                    palette.primaryText.opacity(isModeOn ? 0.10 : 0.025),
                    in: RoundedRectangle(cornerRadius: 16, style: .continuous)
                )
                .overlay {
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .strokeBorder(
                            palette.primaryText.opacity(isModeOn ? 0.65 : 0.12),
                            lineWidth: isModeOn ? 2.5 : 0.5
                        )
                        .allowsHitTesting(false)
                }

            Text(tile.menuTitle)
                .font(.caption.weight(.medium))
                .lineLimit(1)
                .multilineTextAlignment(.center)
                .foregroundStyle(palette.primaryText)
        }
        .frame(maxWidth: .infinity)
        .contentShape(Rectangle())
        .opacity(enabled ? 1 : 0.32)
    }

    /// Whether a switch tile is drawn as on. The panel does not own either
    /// switch, so the state comes in from the shell.
    private func modeIsOn(_ tile: MenuTile) -> Bool {
        (tile.action == .privateTab && isPrivateMode)
            || (tile.action == .desktopSite && isDesktopSiteOn)
    }

    // MARK: - Dragging a tile

    /// A long press lifts the tile, then a drag carries it. The system's
    /// `draggable` snapshots the label into a clipped rounded rectangle and
    /// reorders only on release; this gesture keeps the carried tile whole
    /// and lets the grid rearrange itself while the tile is still moving.
    private func dragGesture(for tile: MenuTile) -> some Gesture {
        LongPressGesture(minimumDuration: 0.32)
            .sequenced(before: DragGesture(minimumDistance: 0, coordinateSpace: .named(Self.panelSpace)))
            .onChanged { value in
                guard case .second(true, let drag?) = value else { return }
                // A long press that stays where it started is the tile's
                // context menu; picking the tile up waits for real movement.
                let dx = drag.translation.width
                let dy = drag.translation.height
                guard dx * dx + dy * dy > 36 else { return }
                beginDragging(tile)
                moveDraggedTile(tile, translation: drag.translation, at: drag.location)
            }
            .onEnded { _ in
                endDragging()
            }
    }

    private func beginDragging(_ tile: MenuTile) {
        guard draggingTileID == nil else { return }
        let visible = layout.visibleTiles
        guard let index = visible.firstIndex(where: { $0.id == tile.id }),
              let center = slotCenter(at: index),
              let metrics = gridMetrics else { return }
        dragStartCenter = center
        dragStartSize = CGSize(width: metrics.cellWidth, height: metrics.cellHeight)
        suppressTileTap = true
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        draggingTileID = tile.id
    }

    private func moveDraggedTile(_ tile: MenuTile, translation: CGSize, at finger: CGPoint) {
        // Layout may not have measured its slots yet on the very first frame;
        // a tile that never lifted must not rearrange the grid.
        guard draggingTileID == tile.id else { return }
        dragTranslation = translation
        let visible = layout.visibleTiles
        guard let source = visible.firstIndex(where: { $0.id == tile.id }) else { return }
        // The finger itself decides the slot, not the carried tile's centre:
        // a tile grabbed near its edge should change slots where the finger
        // crosses, the way the system's own grids behave.
        guard let slot = slotIndex(at: finger, count: visible.count), slot != source else { return }
        // SwiftUI's move semantics: an item moving forwards lands after the
        // slot it was dragged over, one moving backwards lands on it.
        let destination = source < slot ? slot + 1 : slot
        let moved = layout.movingVisible(from: IndexSet(integer: source), to: destination)
        guard moved != layout else { return }
        withAnimation(BrowserMotion.tileDrag(reduceMotion)) {
            settings.menuLayout = moved
        }
    }

    private func endDragging() {
        guard draggingTileID != nil else { return }
        withAnimation(reduceMotion ? nil : .spring(response: 0.3, dampingFraction: 0.88)) {
            draggingTileID = nil
            dragTranslation = .zero
        }
        // The tile is back in its slot as soon as the animation starts; a tap
        // a moment later should act normally, but the release that ended the
        // drag must not.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
            suppressTileTap = false
        }
    }

    // MARK: - Editor

    private var editingHeader: some View {
        HStack(spacing: BrowserSpacing.compact) {
            Text("编辑菜单")
                .font(.headline)
                .frame(maxWidth: .infinity, alignment: .leading)

            Button {
                withAnimation(reduceMotion ? nil : .snappy(duration: 0.22)) { isEditing = false }
            } label: {
                Text("完成")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(palette.onAccent)
                    .padding(.horizontal, 16)
                    .frame(height: 44)
                    .background(palette.accent, in: Capsule())
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, BrowserSpacing.regular)
    }

    private var editingList: some View {
        List {
            Section {
                ForEach(layout.visibleTiles) { tile in
                    HStack(spacing: 12) {
                        Image(systemName: tile.symbolName)
                            .font(.subheadline.weight(.semibold))
                            .symbolRenderingMode(.monochrome)
                            .foregroundStyle(palette.primaryText)
                            .frame(width: 26)
                        Text(tile.title)
                            .foregroundStyle(palette.primaryText)
                        Spacer(minLength: 8)
                        if tile.shortcut != nil {
                            Image(systemName: "link")
                                .font(.caption2)
                                .foregroundStyle(palette.secondaryText)
                        } else if tile.requiresPage {
                            Text("需要网页")
                                .font(.caption2)
                                .foregroundStyle(palette.secondaryText)
                        }
                    }
                }
                .onMove { source, destination in
                    settings.menuLayout = layout.movingVisible(from: source, to: destination)
                }
                .onDelete { offsets in
                    settings.menuLayout = removing(at: offsets)
                }
            } header: {
                Text("显示的菜单项")
            }

            if !layout.hiddenTiles.isEmpty {
                Section("已隐藏") {
                    ForEach(layout.hiddenTiles) { tile in
                        Button {
                            settings.menuLayout = layout.settingVisible(true, id: tile.id)
                        } label: {
                            HStack(spacing: 12) {
                                Image(systemName: tile.symbolName)
                                    .font(.system(size: 14, weight: .medium))
                                    .symbolRenderingMode(.monochrome)
                                    .foregroundStyle(palette.secondaryText)
                                    .frame(width: 26)
                                Text(tile.title)
                                    .foregroundStyle(palette.primaryText)
                                Spacer()
                                Image(systemName: "plus.circle.fill")
                                    .foregroundStyle(palette.primaryText)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
            }

            Section("快捷方式") {
                ForEach(layout.shortcuts) { shortcut in
                    HStack(spacing: 12) {
                        Image(systemName: shortcut.symbolName)
                            .font(.system(size: 14, weight: .medium))
                            .symbolRenderingMode(.monochrome)
                            .foregroundStyle(palette.primaryText)
                            .frame(width: 26)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(shortcut.title)
                                .foregroundStyle(palette.primaryText)
                            Text(shortcut.url)
                                .font(.caption2)
                                .foregroundStyle(palette.secondaryText)
                                .lineLimit(1)
                        }
                        Spacer(minLength: 8)
                        Button(role: .destructive) {
                            settings.menuLayout = layout.removingShortcut(id: shortcut.id)
                        } label: {
                            Image(systemName: "trash")
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.red)
                        .accessibilityLabel("删除快捷方式")
                    }
                }

                Button {
                    showingShortcutEditor = true
                } label: {
                    Label("添加网址", systemImage: "link.badge.plus")
                        .foregroundStyle(palette.primaryText)
                }
            }

            Section {
                Button("恢复默认", systemImage: "arrow.counterclockwise") {
                    settings.menuLayout = layout.reset()
                }
                .foregroundStyle(palette.primaryText)
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        // The rows are already an editing surface; making the user find an
        // 编辑 button before the drag handles appear was the second step this
        // panel exists to remove.
        .environment(\.editMode, .constant(.active))
    }

    /// Removing a built-in hides it; removing a shortcut deletes it outright,
    /// because a shortcut has no "restore" row to bring it back from.
    private func removing(at offsets: IndexSet) -> MenuLayout {
        let visible = layout.visibleTiles
        var updated = layout.hidingVisible(at: offsets)
        for index in offsets where visible.indices.contains(index) {
            if let shortcut = visible[index].shortcut {
                updated = updated.removingShortcut(id: shortcut.id)
            }
        }
        return updated
    }
}

/// Lays the tiles out as equal cells, one slot per tile, in the order the
/// arrangement gives.
///
/// The alternative is `LazyVGrid`, which only lays out the cells it has built
/// and cannot animate a tile across rows it never built. Every slot here is
/// placed by the same arithmetic, so a reorder is a frame change on each tile
/// and the whole grid reflows in one spring.
private struct MenuTileGridLayout: Layout {
    var minimumCellWidth: CGFloat
    var columnSpacing: CGFloat
    var rowSpacing: CGFloat
    var maximumWidth: CGFloat

    private struct Metrics {
        var columns: Int
        var cellWidth: CGFloat
        var cellHeight: CGFloat
        var contentWidth: CGFloat
    }

    private func metrics(for width: CGFloat, subviews: Subviews) -> Metrics {
        let contentWidth = max(0, min(width, maximumWidth))
        let unit = max(minimumCellWidth + columnSpacing, 1)
        let columns = max(1, Int((contentWidth + columnSpacing) / unit))
        let cellWidth = max(0, (contentWidth - columnSpacing * CGFloat(columns - 1)) / CGFloat(columns))
        var cellHeight: CGFloat = 0
        if cellWidth > 0 {
            for subview in subviews {
                cellHeight = max(
                    cellHeight,
                    subview.sizeThatFits(ProposedViewSize(width: cellWidth, height: nil)).height
                )
            }
        }
        return Metrics(columns: columns, cellWidth: cellWidth, cellHeight: cellHeight, contentWidth: contentWidth)
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout Void) -> CGSize {
        let metrics = metrics(for: proposal.width ?? maximumWidth, subviews: subviews)
        guard !subviews.isEmpty, metrics.cellWidth > 0, metrics.cellHeight > 0 else { return .zero }
        let rows = (subviews.count + metrics.columns - 1) / metrics.columns
        let height = CGFloat(rows) * metrics.cellHeight + CGFloat(rows - 1) * rowSpacing
        return CGSize(width: metrics.contentWidth, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout Void) {
        let metrics = metrics(for: bounds.width, subviews: subviews)
        guard metrics.cellWidth > 0, metrics.cellHeight > 0 else { return }
        // The grid caps its own width; on a wide screen the caller stretches
        // the layout and the slots stay in a centred column.
        let originX = bounds.minX + max(0, (bounds.width - metrics.contentWidth) / 2)
        for index in subviews.indices {
            let row = index / metrics.columns
            let column = index % metrics.columns
            let center = CGPoint(
                x: originX + CGFloat(column) * (metrics.cellWidth + columnSpacing) + metrics.cellWidth / 2,
                y: bounds.minY + CGFloat(row) * (metrics.cellHeight + rowSpacing) + metrics.cellHeight / 2
            )
            subviews[index].place(
                at: center,
                anchor: .center,
                proposal: ProposedViewSize(width: metrics.cellWidth, height: metrics.cellHeight)
            )
        }
    }
}

/// The height one tile asks for. Every cell has the same stack, so the tallest
/// is the row's pitch; height does not change while a drag animates, which is
/// what lets the slot arithmetic ignore the tiles' moving frames.
private struct MenuCellHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

/// Where the grid itself sits in the panel, once the width it was given has
/// settled.
private struct MenuGridFrameKey: PreferenceKey {
    static var defaultValue: CGRect = .zero
    static func reduce(value: inout CGRect, nextValue: () -> CGRect) {
        let next = nextValue()
        if next != .zero {
            value = next
        }
    }
}

/// Press feedback for a menu tile: a quiet scale when it can be pressed, and
/// nothing at all when it cannot.
private struct MenuTileButtonStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var enabled: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed && enabled && !reduceMotion ? 0.92 : 1)
            .opacity(configuration.isPressed && enabled ? 0.7 : 1)
            .animation(BrowserMotion.press(reduceMotion), value: configuration.isPressed)
    }
}
