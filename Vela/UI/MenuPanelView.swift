//
//  MenuPanelView.swift
//  Vela
//
//  The panel the menu button opens.
//
//  A grid of icon tiles rather than the system's stacked text buttons: a
//  browser's menu holds fifteen-odd destinations, and a sheet that lists them
//  as rows either scrolls or truncates. The grid shows all of them at once,
//  with the actions that need a page greyed out on the surfaces that have
//  none — which is how the user learns what is available without tapping it.
//

import SwiftUI

/// One action the menu panel offers.
enum VelaMenuAction: String, CaseIterable, Identifiable {
    case addBookmark
    case share
    case findInPage
    case reader
    case hideElements
    case desktopSite
    case home
    case bookmarks
    case history
    case downloads
    case privateTab
    case adBlock
    case reload
    case settings
    /// Not a grid tile: offered on the private-tab tile's long-press menu when
    /// the browser is in private mode, which is the one manual way out of it.
    case leavePrivate

    var id: String { rawValue }

    var title: String {
        switch self {
        case .addBookmark: return "添加书签"
        case .share: return "分享"
        case .findInPage: return "查找网页"
        case .reader: return "阅读模式"
        case .hideElements: return "隐藏元素"
        case .desktopSite: return "桌面网站"
        case .home: return "主页"
        case .bookmarks: return "书签"
        case .history: return "历史记录"
        case .downloads: return "下载管理"
        case .privateTab: return "无痕标签页"
        case .adBlock: return "广告过滤"
        case .reload: return "重新载入"
        case .settings: return "设置"
        case .leavePrivate: return "离开无痕模式"
        }
    }

    var symbolName: String {
        switch self {
        case .addBookmark: return "bookmark"
        case .share: return "square.and.arrow.up"
        case .findInPage: return "magnifyingglass"
        case .reader: return "doc.plaintext"
        case .hideElements: return "eye.slash"
        case .desktopSite: return "desktopcomputer"
        case .home: return "house"
        case .bookmarks: return "book"
        case .history: return "clock.arrow.circlepath"
        case .downloads: return "arrow.down.circle"
        case .privateTab: return "eyeglasses"
        case .adBlock: return "shield.lefthalf.filled"
        case .reload: return "arrow.clockwise"
        case .settings: return "gearshape"
        case .leavePrivate: return "eyeglasses.slash"
        }
    }

    /// Actions that need a document to act on. On the home surface — or with no
    /// tab at all — they are drawn dimmed and do nothing, the same way the
    /// reference panels grey out what a page-less context cannot do.
    var requiresPage: Bool {
        switch self {
        case .addBookmark, .share, .findInPage, .reader, .hideElements,
             .desktopSite, .reload:
            return true
        default:
            return false
        }
    }
}

/// The menu panel: a header row and the grid of actions.
struct MenuPanelView: View {
    @Environment(\.browserPalette) private var palette

    /// Whether the panel's target is a loaded page — `false` greys out every
    /// action that needs one.
    var canActOnPage: Bool
    /// Whether the browser is in private mode, which adds the private-session
    /// exit to the private-tab tile's long-press menu.
    var isPrivateMode: Bool
    /// Shown so the ad-block tile can reflect the current state.
    var adBlockEnabled: Bool
    /// What the panel is acting on — the page's title, or "菜单" on a
    /// page-less surface. Drawn in the header row.
    var pageTitle: String
    var onPerform: (VelaMenuAction) -> Void

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
                LazyVGrid(columns: columns, spacing: BrowserSpacing.regular + 2) {
                    ForEach(VelaMenuAction.allCases.filter { $0 != .leavePrivate }) { action in
                        menuItem(action)
                    }
                }
                .padding(.bottom, BrowserSpacing.compact)
            }
            .padding(.horizontal, BrowserSpacing.regular)
        }
        .frame(maxWidth: .infinity)
        .background(palette.surface)
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

    private func menuItem(_ action: VelaMenuAction) -> some View {
        let enabled = canActOnPage || !action.requiresPage
        return Button {
            guard enabled else { return }
            onPerform(action)
        } label: {
            VStack(spacing: BrowserSpacing.tight) {
                Image(systemName: action.symbolName)
                    .font(.system(size: 19, weight: .medium))
                    .frame(width: 52, height: 52)
                    .background(palette.controlFill.opacity(0.75), in:
                        RoundedRectangle(cornerRadius: 15, style: .continuous)
                    )
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

                Text(action.title)
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
            if action == .privateTab && isPrivateMode {
                Button("离开无痕模式", systemImage: "eyeglasses.slash", role: .destructive) {
                    onPerform(.leavePrivate)
                }
            }
        }
        .accessibilityLabel(action.title)
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
