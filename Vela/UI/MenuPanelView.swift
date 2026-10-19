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
//  it. The tile set, its order, and the custom URL shortcuts all come from
//  `MenuLayout`, edited in 设置 ▸ 菜单面板.
//

import SwiftUI

/// The menu panel: a header row and the grid of tiles.
struct MenuPanelView: View {
    @Environment(\.browserPalette) private var palette

    /// The tiles to draw, already filtered and ordered by `MenuLayout`.
    var tiles: [MenuTile]
    /// Whether the panel's target is a loaded page — `false` greys out every
    /// action that needs one.
    var canActOnPage: Bool
    /// Whether the browser is in private mode, which adds the private-session
    /// exit to the private-tab tile's long-press menu.
    var isPrivateMode: Bool
    /// Whether 无痕模式 is on — the tile is a switch, and this is its state.
    var isPrivateBrowsingOn: Bool
    /// Shown so the ad-block tile can reflect the current state.
    var adBlockEnabled: Bool
    /// What the panel is acting on — the page's title, or "菜单" on a
    /// page-less surface. Drawn in the header row.
    var pageTitle: String
    var onPerform: (VelaMenuAction) -> Void
    var onOpenShortcut: (MenuShortcut) -> Void

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 10), count: 5)

    var body: some View {
        VStack(alignment: .leading, spacing: BrowserSpacing.regular) {
            Capsule()
                .fill(palette.secondaryText.opacity(0.35))
                .frame(width: 36, height: 4)
                .frame(maxWidth: .infinity)
                .padding(.top, 8)

            headerRow

            // The grid scrolls inside the panel: at the compact detent the
            // first rows are on screen and the rest are one drag away, and
            // pulling the panel taller reveals them — the content adapts to
            // the detent instead of leaving a lake under a short grid.
            ScrollView {
                if tiles.isEmpty {
                    Text("菜单项已全部隐藏，可在 设置 ▸ 菜单面板 中恢复。")
                        .font(.footnote)
                        .foregroundStyle(palette.secondaryText)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, BrowserSpacing.loose)
                } else {
                    LazyVGrid(columns: columns, spacing: BrowserSpacing.regular + 2) {
                        ForEach(tiles) { tile in
                            menuItem(tile)
                        }
                    }
                    .padding(.bottom, BrowserSpacing.compact)
                }
            }
            .padding(.horizontal, BrowserSpacing.regular)
        }
        .frame(maxWidth: .infinity)
        .browserSurfaceBackground(opacity: 0.72)
        .presentationDetents([.height(330), .large])
        .presentationDragIndicator(.hidden)
    }

    private var headerRow: some View {
        HStack(spacing: BrowserSpacing.compact) {
            Text(pageTitle.isEmpty ? "菜单" : pageTitle)
                .font(.system(size: 15, weight: .semibold))
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)

            Button {
                onPerform(.settings)
            } label: {
                Image(systemName: "gearshape")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(palette.primaryText)
                    .frame(width: 36, height: 36)
                    .background(palette.controlFill.opacity(0.75), in: Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("设置")
        }
        .padding(.horizontal, BrowserSpacing.regular)
    }

    private func menuItem(_ tile: MenuTile) -> some View {
        let enabled = canActOnPage || !tile.requiresPage
        // The private-mode tile is the one switch in the grid, so its state
        // is drawn on it: the accent wash and the corner badge read as "on"
        // the way a checkmarked row would in a list menu.
        let isModeOn = tile.action == .privateTab && isPrivateBrowsingOn
        return Button {
            guard enabled else { return }
            switch tile {
            case let .action(action):
                onPerform(action)
            case let .shortcut(shortcut):
                onOpenShortcut(shortcut)
            }
        } label: {
            VStack(spacing: BrowserSpacing.tight) {
                Image(systemName: tile.symbolName)
                    .font(.system(size: 19, weight: .medium))
                    .foregroundStyle(isModeOn ? palette.accent : palette.primaryText)
                    .frame(width: 52, height: 52)
                    .background(
                        isModeOn ? palette.accent.opacity(0.18) : palette.controlFill.opacity(0.75),
                        in: RoundedRectangle(cornerRadius: 15, style: .continuous)
                    )
                    .overlay(alignment: .topTrailing) {
                        if isModeOn {
                            Image(systemName: "checkmark.circle.fill")
                                .font(.system(size: 13, weight: .bold))
                                .foregroundStyle(palette.onAccent)
                                .background(palette.accent, in: Circle())
                                .offset(x: 5, y: -5)
                        }
                    }
                    .overlay {
                        RoundedRectangle(cornerRadius: 15, style: .continuous)
                            .strokeBorder(
                                LinearGradient(
                                    colors: [.white.opacity(0.10), .white.opacity(0.02)],
                                    startPoint: .top,
                                    endPoint: .bottom
                                ),
                                lineWidth: 0.5
                            )
                            .allowsHitTesting(false)
                    }

                Text(tile.title)
                    .font(.system(size: 11, weight: .medium))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .foregroundStyle(palette.primaryText)
            .opacity(enabled ? 1 : 0.3)
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(MenuTileButtonStyle(enabled: enabled))
        .disabled(!enabled)
        .contextMenu {
            if tile.action == .privateTab && isPrivateMode {
                Button("离开无痕模式", systemImage: "eyeglasses.slash", role: .destructive) {
                    onPerform(.leavePrivate)
                }
            }
        }
        .accessibilityLabel(tile.title)
        .accessibilityHint(enabled ? "" : "当前不可用")
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
