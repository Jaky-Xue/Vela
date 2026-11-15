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

    private var columns: [GridItem] {
        [GridItem(.adaptive(minimum: dynamicTypeSize.isAccessibilitySize ? 120 : 58), spacing: 10)]
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
                LazyVGrid(columns: columns, spacing: BrowserSpacing.regular + 2) {
                    ForEach(tiles) { tile in
                        menuItem(tile)
                    }
                }
                .frame(maxWidth: 390)
                .frame(maxWidth: .infinity)
                .padding(.horizontal, BrowserSpacing.regular)
                .padding(.bottom, BrowserSpacing.compact)
            }
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
        // The two switches draw their state on the tile: a filled accent
        // square and its inverted glyph, with no badge to read around.
        let isModeOn = (tile.action == .privateTab && isPrivateMode)
            || (tile.action == .desktopSite && isDesktopSiteOn)
        let symbol = tile.symbolName
        return Button {
            guard enabled else { return }
            switch tile {
            case let .action(action):
                onPerform(action)
            case let .shortcut(shortcut):
                onOpenShortcut(shortcut)
            }
        } label: {
            VStack(spacing: 7) {
                Image(systemName: symbol)
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
        .buttonStyle(MenuTileButtonStyle(enabled: enabled))
        .draggable("vela-menu:" + tile.id)
        .dropDestination(for: String.self) { items, _ in
            guard let raw = items.first, raw.hasPrefix("vela-menu:") else { return false }
            let source = String(raw.dropFirst("vela-menu:".count))
            guard layout.visibleTiles.contains(where: { $0.id == source }), source != tile.id else { return false }
            withAnimation(reduceMotion ? nil : BrowserMotion.layout(reduceMotion)) {
                settings.menuLayout = layout.movingTile(source, before: tile.id)
            }
            return true
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
                ? (isModeOn ? "已开启" : "已关闭")
                : ""
        )
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

/// Press feedback for a menu tile: a quiet scale when it can be pressed, and
/// nothing at all when it cannot.
private struct MenuTileButtonStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var enabled: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed && enabled && !reduceMotion ? 0.92 : 1)
            .opacity(configuration.isPressed && enabled ? 0.7 : 1)
            .animation(reduceMotion ? nil : .spring(response: 0.24, dampingFraction: 0.72), value: configuration.isPressed)
    }
}
