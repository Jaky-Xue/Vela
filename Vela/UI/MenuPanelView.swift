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
//  Page scripts can register menu commands (`GM_registerMenuCommand`), but
//  they are not drawn here: a handful of script-specific entries between the
//  tiles and the bottom edge made the panel read as a settings list with a
//  grid stuck on top.
//

import SwiftUI

/// The menu panel: a header row, the grid of tiles, and the editor behind the
/// pencil.
struct MenuPanelView: View {
    @Environment(AppEnvironment.self) private var env
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

    /// Whether the panel is showing its editor instead of its grid.
    @State private var isEditing = false
    @State private var showingShortcutEditor = false

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 10), count: 5)

    /// The live arrangement. Reading the settings service rather than a value
    /// passed in is what makes an edit repaint the grid behind it.
    private var layout: MenuLayout { env.settings.menuLayout }
    private var tiles: [MenuTile] { layout.visibleTiles }

    /// The editor is a list with drag handles and its own sections; the compact
    /// detent is too short to drag in without hunting for the row.
    private var panelDetents: Set<PresentationDetent> {
        isEditing ? [.medium, .large] : [.height(330), .large]
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
        .browserSurfaceBackground(opacity: 0.72)
        .presentationDetents(panelDetents)
        .presentationDragIndicator(.hidden)
        .sheet(isPresented: $showingShortcutEditor) {
            MenuShortcutEditorView { shortcut in
                showingShortcutEditor = false
                guard let shortcut else { return }
                env.settings.menuLayout = layout.adding(shortcut)
            }
            .environment(env)
            .browserAmbientSheet()
        }
    }

    // MARK: - Grid

    private var tileGrid: some View {
        ScrollView {
            if tiles.isEmpty {
                Text("菜单项已全部隐藏，点右上角的编辑按钮恢复。")
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
                .padding(.horizontal, BrowserSpacing.regular)
                .padding(.bottom, BrowserSpacing.compact)
            }
        }
    }

    private var headerRow: some View {
        HStack(spacing: BrowserSpacing.compact) {
            Text(pageTitle.isEmpty ? "菜单" : pageTitle)
                .font(.system(size: 15, weight: .semibold))
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)

            Button {
                withAnimation(.snappy(duration: 0.22)) { isEditing = true }
            } label: {
                Text("编辑")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(palette.primaryText)
                    .padding(.horizontal, 14)
                    .frame(height: 34)
                    .background(palette.controlFill, in: Capsule())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("编辑菜单")

            Button {
                onPerform(.settings)
            } label: {
                Image(systemName: "gearshape")
                    .font(.system(size: 15, weight: .semibold))
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
        let isModeOn = (tile.action == .privateTab && isPrivateBrowsingOn)
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
                    .foregroundStyle(isModeOn ? palette.onAccent : palette.primaryText)
                    // Capped rather than fixed: a five-column grid on a
                    // 320-point phone gives a cell a little under 54 points,
                    // and a hard 54 would push neighbouring tiles apart.
                    .frame(maxWidth: 54, minHeight: 54, maxHeight: 54)
                    .background(
                        isModeOn ? palette.accent : palette.controlFill,
                        in: RoundedRectangle(cornerRadius: 16, style: .continuous)
                    )
                    .overlay {
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .strokeBorder(
                                isModeOn ? Color.clear : palette.cardStroke,
                                lineWidth: 0.5
                            )
                            .allowsHitTesting(false)
                    }

                Text(tile.title)
                    .font(.system(size: 11, weight: .medium))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                    .foregroundStyle(isModeOn ? palette.accent : palette.primaryText)
            }
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
            .opacity(enabled ? 1 : 0.32)
        }
        .buttonStyle(MenuTileButtonStyle(enabled: enabled))
        .disabled(!enabled)
        .contextMenu {
            if tile.action == .privateTab && isPrivateMode {
                Button("离开无痕模式", systemImage: "eyeglasses.slash", role: .destructive) {
                    onPerform(.leavePrivate)
                }
            }
            if tile.action == .desktopSite, let onResetSiteDisplay {
                Button("恢复此站点的自动设置", systemImage: "arrow.uturn.backward") {
                    onResetSiteDisplay()
                }
            }
        }
        .accessibilityLabel(tile.title)
        .accessibilityHint(enabled ? "" : "当前不可用")
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
                .font(.system(size: 15, weight: .semibold))
                .frame(maxWidth: .infinity, alignment: .leading)

            Button {
                withAnimation(.snappy(duration: 0.22)) { isEditing = false }
            } label: {
                Text("完成")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(palette.onAccent)
                    .padding(.horizontal, 16)
                    .frame(height: 34)
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
                            .font(.system(size: 14, weight: .semibold))
                            .symbolRenderingMode(.monochrome)
                            .foregroundStyle(palette.accent)
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
                    env.settings.menuLayout = layout.movingVisible(from: source, to: destination)
                }
                .onDelete { offsets in
                    env.settings.menuLayout = removing(at: offsets)
                }
            } header: {
                Text("显示的菜单项")
            }

            if !layout.hiddenTiles.isEmpty {
                Section("已隐藏") {
                    ForEach(layout.hiddenTiles) { tile in
                        Button {
                            env.settings.menuLayout = layout.settingVisible(true, id: tile.id)
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
                                    .foregroundStyle(palette.accent)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
            }

            Section("自定义快捷方式") {
                ForEach(layout.shortcuts) { shortcut in
                    HStack(spacing: 12) {
                        Image(systemName: shortcut.symbolName)
                            .font(.system(size: 14, weight: .medium))
                            .symbolRenderingMode(.monochrome)
                            .foregroundStyle(palette.accent)
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
                            env.settings.menuLayout = layout.removingShortcut(id: shortcut.id)
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
                    Label("新建网址快捷方式", systemImage: "link.badge.plus")
                        .foregroundStyle(palette.accent)
                }
            }

            Section {
                Button("恢复默认菜单", systemImage: "arrow.counterclockwise") {
                    env.settings.menuLayout = layout.reset()
                }
                .foregroundStyle(palette.accent)
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
    var enabled: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed && enabled ? 0.92 : 1)
            .opacity(configuration.isPressed && enabled ? 0.7 : 1)
            .animation(.spring(response: 0.24, dampingFraction: 0.72), value: configuration.isPressed)
    }
}
