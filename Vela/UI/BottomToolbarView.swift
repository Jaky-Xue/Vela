//
//  BottomToolbarView.swift
//  Vela
//
//  The bottom action bar.
//
//  The action identities and the default order are fixed. A stored per-device
//  order is honoured, so a reorder screen can be added later without a
//  migration; the order is device-local because it is a property of how someone
//  holds this phone rather than of their account.
//

import SwiftUI

/// One toolbar action.
enum BrowserToolbarAction: String, CaseIterable, Identifiable, Codable {
    case back
    case forward
    case home
    case tabs
    case bookmarks
    case adBlock
    case reader
    case share
    case refresh
    case menu

    var id: String { rawValue }

    var systemImage: String {
        switch self {
        case .back: return "chevron.left"
        case .forward: return "chevron.right"
        case .home: return "house"
        case .tabs: return "square.on.square"
        case .bookmarks: return "book"
        case .adBlock: return "shield.lefthalf.filled"
        case .reader: return "doc.plaintext"
        case .share: return "square.and.arrow.up"
        case .refresh: return "arrow.clockwise"
        case .menu: return "ellipsis"
        }
    }

    var displayName: String {
        switch self {
        case .back: return "后退"
        case .forward: return "前进"
        case .home: return "主页"
        case .tabs: return "标签页"
        case .bookmarks: return "书签"
        case .adBlock: return "广告过滤"
        case .reader: return "阅读模式"
        case .share: return "分享"
        case .refresh: return "刷新"
        case .menu: return "菜单"
        }
    }

    /// The default order.
    ///
    /// Home sits here rather than in the menu because backing out of a page is
    /// not the same gesture as returning to the start surface. A browser that
    /// offers only the first leaves someone scrolling back through a site they
    /// are done with, or opening a tab they did not want.
    static let defaultOrder: [BrowserToolbarAction] = [
        .back, .forward, .home, .tabs, .bookmarks, .adBlock, .reader, .menu
    ]

    /// Actions that cannot be removed, because the shell has no other route to
    /// them.
    var isRequired: Bool {
        switch self {
        case .back, .forward, .home, .tabs, .menu: return true
        default: return false
        }
    }
}

struct BottomToolbarView: View {
    @Environment(\.browserPalette) private var palette

    /// The glyph size and the inactive tint both scale, so the bar grows with
    /// Dynamic Type instead of clipping the tab count drawn inside the tabs
    /// glyph.
    @ScaledMetric(relativeTo: .body) private var glyphSize: CGFloat = 19

    var actions: [BrowserToolbarAction]
    var tabCount: Int
    var canGoBack: Bool
    var canGoForward: Bool
    var adBlockActive: Bool
    var readerAvailable: Bool

    var onAction: (BrowserToolbarAction) -> Void

    var body: some View {
        HStack(spacing: 0) {
            ForEach(actions) { action in
                Button {
                    onAction(action)
                } label: {
                    icon(for: action)
                        .frame(maxWidth: .infinity)
                        .frame(height: BrowserMetrics.toolbarHeight)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(!isEnabled(action))
                .foregroundStyle(
                    isEnabled(action)
                        ? palette.primaryText
                        : palette.secondaryText.opacity(0.45)
                )
                .accessibilityLabel(action.displayName)
            }
        }
        .background {
            // Transparent on purpose: the toolbar shares one chrome panel with
            // the address bar, and the shell paints that panel's material. A
            // second bar behind this one would stack two materials and darken
            // the row every time the page behind it changed.
            Color.clear
        }
    }

    @ViewBuilder
    private func icon(for action: BrowserToolbarAction) -> some View {
        switch action {
        case .tabs:
            // The tab count is drawn inside the glyph, which removes the need for
            // a separate badge overlapping the icon.
            ZStack {
                Image(systemName: action.systemImage)
                    .font(.system(size: glyphSize, weight: .medium))
                if tabCount > 0 {
                    Text("\(min(tabCount, 99))")
                        .font(.system(size: glyphSize * 0.5, weight: .bold))
                        .offset(y: 1)
                }
            }
        case .adBlock:
            ZStack {
                Image(systemName: action.systemImage)
                    .font(.system(size: glyphSize, weight: .medium))
                if !adBlockActive {
                    // A slash over the shield reads as "off" at a glance, which
                    // a colour change alone does not.
                    Image(systemName: "line.diagonal")
                        .font(.system(size: glyphSize + 1, weight: .bold))
                }
            }
        case .reader:
            // The reader glyph is the one action whose availability is not
            // obvious from the icon, so it carries the accent when it can be
            // used.
            Image(systemName: action.systemImage)
                .font(.system(size: glyphSize, weight: .medium))
                .foregroundStyle(readerAvailable ? palette.accent : palette.secondaryText.opacity(0.45))
        default:
            Image(systemName: action.systemImage)
                .font(.system(size: glyphSize, weight: .medium))
        }
    }

    private func isEnabled(_ action: BrowserToolbarAction) -> Bool {
        switch action {
        case .back: return canGoBack
        case .forward: return canGoForward
        case .reader: return readerAvailable
        default: return true
        }
    }
}
