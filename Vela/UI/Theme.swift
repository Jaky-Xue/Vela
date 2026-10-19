//
//  Theme.swift
//  Vela
//
//  Shared visual tokens.
//
//  A palette is a value, not a set of asset-catalogue colours. That is what lets
//  a palette be swapped at runtime without a relaunch, which is a promise the
//  settings screen makes to the user.
//
//  Every token is a light/dark pair resolved through a dynamic `UIColor`, so a
//  single `palette.chromeBackground` is correct in both appearances and
//  re-resolves without a rebuild. That matters more than the token list
//  suggests: the user can pull Control Centre and switch appearance while the
//  app is on screen, so a palette carrying one set of fixed colours is stuck in
//  whichever mode it was authored for. Nothing in the chrome reads a fixed
//  colour.
//

import SwiftUI
import UIKit

// MARK: - Appearance

/// Which appearance the user asked for.
///
/// iOS offers both a system setting and a per-app override, so the per-app mode
/// is its own setting, and `nil` from `colorScheme` means "follow the system".
public enum AppearanceMode: String, CaseIterable, Codable, Sendable, Identifiable {
    case system
    case light
    case dark

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .system: return "跟随系统"
        case .light: return "浅色"
        case .dark: return "深色"
        }
    }

    public var symbolName: String {
        switch self {
        case .system: return "circle.lefthalf.filled"
        case .light: return "sun.max"
        case .dark: return "moon"
        }
    }

    /// The value handed to `preferredColorScheme`. `nil` follows the system,
    /// which is what makes "跟随系统" a real mode rather than a third fixed one.
    public var colorScheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .light: return .light
        case .dark: return .dark
        }
    }
}

// MARK: - Tokens

/// The colour tokens one palette needs, for one appearance.
///
/// Split out from `BrowserPalette` so a palette can ship two complete sets and
/// so a view that needs a *literal* colour for the current scheme (a UIKit
/// backdrop, say) can ask for one instead of a dynamic colour.
struct BrowserColorTokens: Equatable, Sendable {
    /// Selection, links, the progress line.
    var accent: Color
    /// The chrome fill behind the address bar and toolbar materials.
    var chrome: Color
    /// The page background behind web content.
    var surface: Color
    /// The fill of a raised card: the omnibox suggestion list, grouped rows.
    var card: Color
    /// The hairline around a raised card. Without it a dark card on a dark
    /// surface has no edge at all.
    var cardStroke: Color
    var separator: Color
    var primaryText: Color
    var secondaryText: Color
    /// The fill of a control inside the chrome, e.g. the address field.
    var controlFill: Color
    /// The background of the keyboard-highlighted omnibox row.
    var rowHighlight: Color
    /// The background painted behind the substring a query matched.
    var matchHighlight: Color
    /// Text drawn on top of `accent`.
    var onAccent: Color
}

/// A colour palette.
///
/// appearance model described in the file header.
struct BrowserPalette: Equatable, Identifiable, Sendable {
    var id: String
    var displayName: String
    var light: BrowserColorTokens
    var dark: BrowserColorTokens

    /// The token set for an explicit appearance.
    ///
    /// Used where a literal colour is required — a UIKit view that is configured
    /// once per update pass, or a preview pinned to one mode.
    func tokens(for scheme: ColorScheme) -> BrowserColorTokens {
        scheme == .dark ? dark : light
    }

    /// Builds a colour that resolves against the current appearance.
    ///
    /// This is the trick the whole file rests on: SwiftUI resolves a
    /// `UIColor`'s dynamic provider against the environment's `colorScheme`, so
    /// one stored `Color` covers both modes and nothing has to be threaded
    /// through the view tree.
    private func adaptive(_ key: KeyPath<BrowserColorTokens, Color>) -> Color {
        let light = light[keyPath: key]
        let dark = dark[keyPath: key]
        return Color(uiColor: UIColor(dynamicProvider: { trait in
            UIColor(trait.userInterfaceStyle == .dark ? dark : light)
        }))
    }

    // MARK: Resolved tokens

    var accent: Color { adaptive(\.accent) }
    /// The chrome background, read by the address bar and the toolbar.
    var chromeBackground: Color { adaptive(\.chrome) }
    var surface: Color { adaptive(\.surface) }
    var card: Color { adaptive(\.card) }
    var cardStroke: Color { adaptive(\.cardStroke) }
    var separator: Color { adaptive(\.separator) }
    var primaryText: Color { adaptive(\.primaryText) }
    var secondaryText: Color { adaptive(\.secondaryText) }
    var controlFill: Color { adaptive(\.controlFill) }
    var rowHighlight: Color { adaptive(\.rowHighlight) }
    var matchHighlight: Color { adaptive(\.matchHighlight) }
    var onAccent: Color { adaptive(\.onAccent) }

    // MARK: Catalogue

    /// The palettes Vela ships, reduced to the four that read well at both
    /// Dynamic Type extremes and in both appearances.
    static let all: [BrowserPalette] = [
        BrowserPalette(
            id: "default",
            displayName: "默认",
            light: BrowserColorTokens(
                accent: Color(red: 0.14, green: 0.45, blue: 0.94),
                chrome: Color(red: 0.949, green: 0.949, blue: 0.969),
                surface: Color(red: 1.0, green: 1.0, blue: 1.0),
                card: Color(red: 1.0, green: 1.0, blue: 1.0),
                cardStroke: Color(red: 0.0, green: 0.0, blue: 0.0).opacity(0.08),
                separator: Color(red: 0.0, green: 0.0, blue: 0.0).opacity(0.10),
                primaryText: Color(red: 0.11, green: 0.11, blue: 0.12),
                secondaryText: Color(red: 0.42, green: 0.42, blue: 0.44),
                controlFill: Color(red: 0.937, green: 0.937, blue: 0.957),
                rowHighlight: Color(red: 0.14, green: 0.45, blue: 0.94).opacity(0.14),
                matchHighlight: Color(red: 0.14, green: 0.45, blue: 0.94).opacity(0.16),
                onAccent: Color(red: 1.0, green: 1.0, blue: 1.0)
            ),
            dark: BrowserColorTokens(
                accent: Color(red: 0.36, green: 0.63, blue: 1.0),
                chrome: Color(red: 0.11, green: 0.11, blue: 0.12),
                surface: Color(red: 0.0, green: 0.0, blue: 0.0),
                card: Color(red: 0.13, green: 0.13, blue: 0.15),
                cardStroke: Color(red: 1.0, green: 1.0, blue: 1.0).opacity(0.12),
                separator: Color(red: 1.0, green: 1.0, blue: 1.0).opacity(0.12),
                primaryText: Color(red: 1.0, green: 1.0, blue: 1.0),
                secondaryText: Color(red: 0.63, green: 0.63, blue: 0.65),
                controlFill: Color(red: 0.17, green: 0.17, blue: 0.19),
                rowHighlight: Color(red: 0.36, green: 0.63, blue: 1.0).opacity(0.24),
                matchHighlight: Color(red: 0.36, green: 0.63, blue: 1.0).opacity(0.28),
                onAccent: Color(red: 1.0, green: 1.0, blue: 1.0)
            )
        ),
        BrowserPalette(
            id: "morandi",
            displayName: "莫兰迪",
            light: BrowserColorTokens(
                accent: Color(red: 0.44, green: 0.38, blue: 0.35),
                chrome: Color(red: 0.941, green: 0.929, blue: 0.910),
                surface: Color(red: 0.969, green: 0.961, blue: 0.949),
                card: Color(red: 1.0, green: 0.996, blue: 0.988),
                cardStroke: Color(red: 0.35, green: 0.30, blue: 0.26).opacity(0.16),
                separator: Color(red: 0.35, green: 0.30, blue: 0.26).opacity(0.14),
                primaryText: Color(red: 0.16, green: 0.15, blue: 0.14),
                secondaryText: Color(red: 0.43, green: 0.40, blue: 0.38),
                controlFill: Color(red: 0.914, green: 0.898, blue: 0.878),
                rowHighlight: Color(red: 0.44, green: 0.38, blue: 0.35).opacity(0.18),
                matchHighlight: Color(red: 0.44, green: 0.38, blue: 0.35).opacity(0.18),
                onAccent: Color(red: 1.0, green: 1.0, blue: 1.0)
            ),
            dark: BrowserColorTokens(
                accent: Color(red: 0.80, green: 0.74, blue: 0.69),
                chrome: Color(red: 0.13, green: 0.12, blue: 0.12),
                surface: Color(red: 0.09, green: 0.086, blue: 0.082),
                card: Color(red: 0.16, green: 0.15, blue: 0.14),
                cardStroke: Color(red: 1.0, green: 0.97, blue: 0.93).opacity(0.14),
                separator: Color(red: 1.0, green: 0.97, blue: 0.93).opacity(0.14),
                primaryText: Color(red: 0.949, green: 0.937, blue: 0.921),
                secondaryText: Color(red: 0.66, green: 0.635, blue: 0.61),
                controlFill: Color(red: 0.19, green: 0.18, blue: 0.17),
                rowHighlight: Color(red: 0.80, green: 0.74, blue: 0.69).opacity(0.22),
                matchHighlight: Color(red: 0.80, green: 0.74, blue: 0.69).opacity(0.24),
                onAccent: Color(red: 0.13, green: 0.12, blue: 0.12)
            )
        ),
        BrowserPalette(
            id: "ocean",
            displayName: "深海",
            light: BrowserColorTokens(
                accent: Color(red: 0.06, green: 0.38, blue: 0.51),
                chrome: Color(red: 0.906, green: 0.941, blue: 0.949),
                surface: Color(red: 0.961, green: 0.980, blue: 0.984),
                card: Color(red: 1.0, green: 1.0, blue: 1.0),
                cardStroke: Color(red: 0.05, green: 0.25, blue: 0.33).opacity(0.16),
                separator: Color(red: 0.05, green: 0.25, blue: 0.33).opacity(0.14),
                primaryText: Color(red: 0.06, green: 0.15, blue: 0.17),
                secondaryText: Color(red: 0.32, green: 0.42, blue: 0.45),
                controlFill: Color(red: 0.878, green: 0.925, blue: 0.937),
                rowHighlight: Color(red: 0.06, green: 0.38, blue: 0.51).opacity(0.16),
                matchHighlight: Color(red: 0.06, green: 0.38, blue: 0.51).opacity(0.16),
                onAccent: Color(red: 1.0, green: 1.0, blue: 1.0)
            ),
            dark: BrowserColorTokens(
                accent: Color(red: 0.42, green: 0.78, blue: 0.88),
                chrome: Color(red: 0.078, green: 0.149, blue: 0.169),
                surface: Color(red: 0.047, green: 0.102, blue: 0.118),
                card: Color(red: 0.09, green: 0.188, blue: 0.204),
                cardStroke: Color(red: 0.60, green: 0.88, blue: 0.94).opacity(0.16),
                separator: Color(red: 0.60, green: 0.88, blue: 0.94).opacity(0.14),
                primaryText: Color(red: 0.910, green: 0.953, blue: 0.961),
                secondaryText: Color(red: 0.60, green: 0.70, blue: 0.73),
                controlFill: Color(red: 0.118, green: 0.220, blue: 0.243),
                rowHighlight: Color(red: 0.42, green: 0.78, blue: 0.88).opacity(0.22),
                matchHighlight: Color(red: 0.42, green: 0.78, blue: 0.88).opacity(0.24),
                onAccent: Color(red: 0.047, green: 0.102, blue: 0.118)
            )
        ),
        BrowserPalette(
            id: "crimson",
            displayName: "朱砂",
            light: BrowserColorTokens(
                accent: Color(red: 0.72, green: 0.24, blue: 0.20),
                chrome: Color(red: 0.961, green: 0.933, blue: 0.925),
                surface: Color(red: 0.988, green: 0.972, blue: 0.969),
                card: Color(red: 1.0, green: 1.0, blue: 1.0),
                cardStroke: Color(red: 0.45, green: 0.15, blue: 0.13).opacity(0.16),
                separator: Color(red: 0.45, green: 0.15, blue: 0.13).opacity(0.14),
                primaryText: Color(red: 0.17, green: 0.10, blue: 0.09),
                secondaryText: Color(red: 0.44, green: 0.35, blue: 0.34),
                controlFill: Color(red: 0.937, green: 0.906, blue: 0.898),
                rowHighlight: Color(red: 0.72, green: 0.24, blue: 0.20).opacity(0.14),
                matchHighlight: Color(red: 0.72, green: 0.24, blue: 0.20).opacity(0.15),
                onAccent: Color(red: 1.0, green: 1.0, blue: 1.0)
            ),
            dark: BrowserColorTokens(
                accent: Color(red: 0.95, green: 0.49, blue: 0.44),
                chrome: Color(red: 0.165, green: 0.106, blue: 0.098),
                surface: Color(red: 0.102, green: 0.063, blue: 0.059),
                card: Color(red: 0.200, green: 0.129, blue: 0.122),
                cardStroke: Color(red: 0.98, green: 0.72, blue: 0.69).opacity(0.16),
                separator: Color(red: 0.98, green: 0.72, blue: 0.69).opacity(0.14),
                primaryText: Color(red: 0.969, green: 0.929, blue: 0.922),
                secondaryText: Color(red: 0.72, green: 0.62, blue: 0.60),
                controlFill: Color(red: 0.235, green: 0.153, blue: 0.145),
                rowHighlight: Color(red: 0.95, green: 0.49, blue: 0.44).opacity(0.22),
                matchHighlight: Color(red: 0.95, green: 0.49, blue: 0.44).opacity(0.24),
                onAccent: Color(red: 0.102, green: 0.063, blue: 0.059)
            )
        )
    ]

    static let `default` = all[0]
}

// MARK: - Metrics

/// Layout metrics shared by the chrome.
enum BrowserMetrics {
    /// The widest a centred dialog grows.
    static let dialogMaxWidth: CGFloat = 420
    /// The tab strip's cell size on a large screen.
    static let tabStripItemWidth: CGFloat = 200
    static let tabStripItemHeight: CGFloat = 34

    // Omnibox. These are the suggestion card's own metrics.
    static let omniboxRowHeight: CGFloat = 54
    static let omniboxHeaderHeight: CGFloat = 34
    /// The tallest the suggestion card may grow before it scrolls internally,
    /// expressed as a fraction of the space between the chrome and the keyboard
    /// so a short list on a tall screen does not open a card with a lake of
    /// empty material in it.
    static let omniboxCardHeightFraction: CGFloat = 0.62
    /// A hard ceiling for the same card, so an iPad in landscape does not get a
    /// suggestion list taller than the page it is covering.
    static let omniboxCardMaxHeight: CGFloat = 620

    /// The loading line drawn on the address bar's bottom edge.
    static let progressLineHeight: CGFloat = 2
}

/// Corner radii. Named by role rather than by number so a change lands in one
/// place: "the card radius" is a decision, "16" is not.
enum BrowserRadius {
    static let chip: CGFloat = 10
    static let field: CGFloat = 14
    static let card: CGFloat = 16
    static let sheet: CGFloat = 20
    /// The address field. Rounder than a generic field because the omnibox is
    /// the one control the whole chrome is arranged around — at 22 pt on a
    /// 46 pt bar it reads as a capsule without losing the straight edges that
    /// keep a long URL from looking squeezed.
    static let omnibox: CGFloat = 22
    /// The floating bar the toolbar sits in, and every other panel that has to
    /// read as detached from the screen edge rather than as a strip of it.
    static let floating: CGFloat = 26
}

/// The spacing scale, on a 4-point grid.
enum BrowserSpacing {
    static let hairline: CGFloat = 2
    static let tight: CGFloat = 6
    static let compact: CGFloat = 10
    static let regular: CGFloat = 16
    static let loose: CGFloat = 24
}

/// The insets the floating chrome uses.
///
/// Deliberately not part of the spacing scale: these are the gap between the
/// chrome and the screen edge, and they answer to the hardware's corner radius
/// rather than to the spacing rhythm inside the panels.
enum BrowserChrome {
    /// How far the chrome sits from the side edges.
    ///
    /// Six points, not twelve: the bottom bar is the search surface, and the
    /// wider it reads the more of the address the field shows. Safari's own
    /// iPad bar holds roughly this margin.
    static let sideInset: CGFloat = 6
    /// How far the command bar sits below the safe area.
    static let topInset: CGFloat = 4
    /// The gap between the command bar and the page below it.
    ///
    /// Two points: the bar is the thumb's business and the home indicator
    /// already owns the space beneath it, so a wide strip under the bar only
    /// raised the field away from the hand.
    static let barGap: CGFloat = 2
    /// The command bar's own height.
    ///
    /// Forty-six rather than forty: at forty the field inside the glass read
    /// thinner than the capsule around it and the address sat on a sliver.
    /// The omnibox radius was drawn for this height.
    static let barHeight: CGFloat = 46
    /// The chrome's total height measured below the status bar, from the top of
    /// the safe area to where the page begins. This is the number the web
    /// view's top content inset is set to, and the number every surface that
    /// sits under the chrome is padded by.
    static let topChromeHeight: CGFloat = topInset + barHeight + barGap
}

/// Elevation. On iOS this is a shadow plus a hairline stroke; the stroke is
/// what keeps a card visible in dark mode, where a black shadow does nothing.
struct BrowserElevation {
    var radius: CGFloat
    var y: CGFloat
    var opacity: Double

    static let card = BrowserElevation(radius: 18, y: 8, opacity: 0.10)
    static let floating = BrowserElevation(radius: 24, y: 12, opacity: 0.16)

    func shadowColor(for scheme: ColorScheme) -> Color {
        // A dark surface needs a heavier shadow to separate at all, not a
        // lighter one.
        .black.opacity(scheme == .dark ? opacity * 4 : opacity)
    }
}

// MARK: - Environment

/// Environment value carrying the active palette, so a view deep in the tree
/// does not have to thread it through every initialiser.
private struct BrowserPaletteKey: EnvironmentKey {
    static let defaultValue = BrowserPalette.default
}

extension EnvironmentValues {
    var browserPalette: BrowserPalette {
        get { self[BrowserPaletteKey.self] }
        set { self[BrowserPaletteKey.self] = newValue }
    }
}
