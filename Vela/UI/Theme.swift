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
    static let sideInset: CGFloat = 12
    /// How far the command bar sits below the safe area.
    static let topInset: CGFloat = 4
    /// The gap between the command bar and the page below it.
    static let barGap: CGFloat = 8
    /// The command bar's own height.
    static let barHeight: CGFloat = 40
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

// MARK: - Card surface

/// The raised-card treatment used by the omnibox suggestion list and every
/// other floating group on the chrome.
///
/// Material rather than a flat fill, because a material is the only fill that
/// stays legible when the page behind it is an arbitrary photograph — which,
/// for a browser, is the normal case rather than the exception.
struct BrowserCardStyle: ViewModifier {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.browserPalette) private var palette

    var material: Material = .regularMaterial
    var radius: CGFloat = BrowserRadius.card
    var elevation: BrowserElevation = .card
    /// Drawn behind the material. A material over a white page washes out, so
    /// the tint underneath is what gives the card a body of its own.
    var tint: Color?

    @ViewBuilder
    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        content
            .background {
                if let tint {
                    shape.fill(tint)
                }
                shape.fill(material)
            }
            .overlay(shape.strokeBorder(palette.cardStroke, lineWidth: 0.5))
            .clipShape(shape)
            .shadow(
                color: elevation.shadowColor(for: colorScheme),
                radius: elevation.radius,
                y: elevation.y
            )
    }
}

extension View {
    /// Wraps the receiver in the shared raised-card treatment.
    func browserCard(
        material: Material = .regularMaterial,
        radius: CGFloat = BrowserRadius.card,
        elevation: BrowserElevation = .card,
        tint: Color? = nil
    ) -> some View {
        modifier(BrowserCardStyle(material: material, radius: radius, elevation: elevation, tint: tint))
    }
}

// MARK: - List surface

/// Paints a `List` in the active palette.
///
/// Without this the list screens keep UIKit's grouped background and read as
/// system apps with a Vela-coloured navigation bar, which is what makes a
/// settings screen and the browser chrome look like two different products. The
/// rows keep a card fill so the grouped rhythm survives the change of surface.
struct BrowserListSurface: ViewModifier {
    @Environment(\.browserPalette) private var palette

    /// Whether the rows get a card fill of their own. Off for a plain list,
    /// where cards-in-a-list would be a third level of nesting.
    var rowsAreCards: Bool

    @ViewBuilder
    func body(content: Content) -> some View {
        content
            .scrollContentBackground(.hidden)
            .background(palette.surface)
            .toolbarBackground(palette.chromeBackground, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .listRowBackground(rowsAreCards ? palette.card : Color.clear)
    }
}

extension View {
    /// Applies the shared list surface.
    func browserListSurface(rowsAreCards: Bool = true) -> some View {
        modifier(BrowserListSurface(rowsAreCards: rowsAreCards))
    }
}

// MARK: - Floating chrome

/// The treatment for a control that floats above the page rather than being a
/// strip of the screen: the omnibox, the top command bar, the find bar.
///
/// On iOS 26 the fill is the system's own Liquid Glass — `glassEffect` — which
/// refracts the page scrolling underneath it the way the rest of the system
/// does. Earlier SDKs cannot express that call at all, so the same modifier
/// carries a hand-built fallback: a tint under a blur material. The luminous
/// sheen is layered on top in both paths, because the light-play is what makes
/// the chrome read as one material family whether or not the system supplies
/// the refraction.
struct BrowserFloatingChrome: ViewModifier {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.browserPalette) private var palette

    var radius: CGFloat
    var material: Material
    /// How strongly the palette's control fill sits under the fallback material.
    /// Unused on the iOS 26 path, where the system glass supplies its own body.
    var tintStrength: Double
    var elevation: BrowserElevation
    /// Whether the glass responds to touch with the system's own highlight.
    var interactive: Bool

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        #if compiler(>=6.2)
        if #available(iOS 26.0, *) {
            content
                .glassEffect(
                    interactive ? Glass.regular.interactive() : Glass.regular,
                    in: shape
                )
                .luminousSheen(shape: shape)
                .shadow(
                    color: elevation.shadowColor(for: colorScheme),
                    radius: elevation.radius,
                    y: elevation.y
                )
        } else {
            legacySurface(content, shape: shape)
        }
        #else
        legacySurface(content, shape: shape)
        #endif
    }

    /// The pre-iOS-26 surface: tint under a blur, hairline stroke, shadow.
    @ViewBuilder
    private func legacySurface(_ content: Content, shape: RoundedRectangle) -> some View {
        content
            .background {
                shape.fill(palette.controlFill.opacity(tintStrength))
                shape.fill(material)
            }
            .luminousSheen(shape: shape)
            .overlay(shape.strokeBorder(palette.cardStroke, lineWidth: 0.5))
            .clipShape(shape)
            .shadow(
                color: elevation.shadowColor(for: colorScheme),
                radius: elevation.radius,
                y: elevation.y
            )
    }
}

extension View {
    /// Wraps the receiver in the floating-chrome treatment.
    func browserFloatingChrome(
        radius: CGFloat = BrowserRadius.floating,
        material: Material = .regularMaterial,
        tintStrength: Double = 0.5,
        elevation: BrowserElevation = .floating,
        interactive: Bool = true
    ) -> some View {
        modifier(
            BrowserFloatingChrome(
                radius: radius,
                material: material,
                tintStrength: tintStrength,
                elevation: elevation,
                interactive: interactive
            )
        )
    }

    /// A light-play pass over a glass surface — the 光感 layer.
    ///
    /// A cool highlight sweeps down from the upper edge and a hairline rim
    /// catches the light along the top. Drawn with `plusLighter`, so in dark
    /// mode it reads as a glow and in light mode as a sheen; either way it is
    /// the same overlay on every chrome surface, which is what makes the
    /// omnibox, the command bar and the cards read as one material.
    ///
    /// The hit-testing opt-out is attached to each overlay's *content*, not to
    /// the chain. `allowsHitTesting(false)` covers the whole view it modifies —
    /// descendants included — so placing it on the chain would have silenced
    /// every button the sheen is painted over: the whole command bar went dead
    /// to taps exactly that way once.
    @ViewBuilder
    func luminousSheen(shape: RoundedRectangle) -> some View {
        overlay {
            shape
                .fill(
                    LinearGradient(
                        stops: [
                            .init(color: .white.opacity(0.24), location: 0),
                            .init(color: .white.opacity(0.05), location: 0.4),
                            .init(color: .clear, location: 0.72)
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
                .blendMode(.plusLighter)
                .allowsHitTesting(false)
        }
        .overlay {
            shape
                .strokeBorder(
                    LinearGradient(
                        colors: [.white.opacity(0.42), .white.opacity(0.04)],
                        startPoint: .top,
                        endPoint: .bottom
                    ),
                    lineWidth: 1
                )
                .blendMode(.plusLighter)
                .allowsHitTesting(false)
        }
    }
}

// MARK: - Rows

/// A reusable row used by the settings, bookmark, history and download lists.
///
/// The same visual row is used by every list screen, so it lives here once.
struct BrowserListRow<Leading: View, Trailing: View>: View {
    @Environment(\.browserPalette) private var palette

    var title: String
    var subtitle: String?
    var detail: String?
    @ViewBuilder var leading: () -> Leading
    @ViewBuilder var trailing: () -> Trailing

    init(
        title: String,
        subtitle: String? = nil,
        detail: String? = nil,
        @ViewBuilder leading: @escaping () -> Leading,
        @ViewBuilder trailing: @escaping () -> Trailing
    ) {
        self.title = title
        self.subtitle = subtitle
        self.detail = detail
        self.leading = leading
        self.trailing = trailing
    }

    var body: some View {
        HStack(spacing: 12) {
            leading()
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.body)
                    .foregroundStyle(palette.primaryText)
                    .lineLimit(1)
                if let subtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(palette.secondaryText)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 8)
            if let detail, !detail.isEmpty {
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(palette.secondaryText)
            }
            trailing()
        }
        .contentShape(Rectangle())
    }
}

// MARK: - Icons

/// A favicon or a letter placeholder.
///
/// A favicon is not readable from outside the page, so when the site's own icon
/// cannot be fetched this shows the host's first letter on a deterministic
/// colour. The colour is derived from the host, so the same site always gets the
/// same swatch.
struct SiteIconView: View {
    var host: String
    var size: CGFloat = 28
    var faviconUrl: String?
    /// The tile's corner radius, when the caller owns the shape the tile sits
    /// in — the home's favourites pass their chosen shape through here. `nil`
    /// keeps the component's own proportion of the size.
    var cornerRadius: CGFloat? = nil

    @Environment(\.colorScheme) private var colorScheme

    /// The decoded icon, once one of the candidate sources has answered.
    @State private var image: UIImage?

    /// Decoded icons for this process, keyed by URL. `URLSession`'s own cache
    /// answers the bytes; this one answers the decode, so a tile that scrolls
    /// back into view shows instantly.
    private static let iconCache = NSCache<NSString, UIImage>()

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: resolvedCornerRadius, style: .continuous)
                .fill(tileFill)

            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
                    .padding(size * 0.14)
            } else {
                Text(initial)
                    .font(.system(size: size * 0.42, weight: .semibold, design: .rounded))
                    .foregroundStyle(color)
                    .minimumScaleFactor(0.6)
            }
        }
        // The chosen shape is the tile's shape, picture included. An icon
        // that carries its own opaque background covers the fill entirely,
        // so shaping only the fill let 圆角/圆形/方角 change something no
        // one could see; clipping the stack makes the shape the icon's own
        // silhouette too.
        .clipShape(RoundedRectangle(cornerRadius: resolvedCornerRadius, style: .continuous))
        .overlay {
            // A hairline that keeps the tile reading as a tile over any
            // backdrop, the way Via's tiles hold their edge on a picture.
            RoundedRectangle(cornerRadius: resolvedCornerRadius, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5)
        }
        .frame(width: size, height: size)
        .task(id: "\(host)|\(faviconUrl ?? "")") {
            await loadIcon()
        }
    }

    private var resolvedCornerRadius: CGFloat {
        cornerRadius ?? size * 0.22
    }

    /// The tile every icon rides: one quiet neutral, so a grid of them reads
    /// as a shelf of equals — the uniformity the reference home has — instead
    /// of every favicon arriving on whatever backdrop its own alpha implies.
    private var tileFill: Color {
        colorScheme == .dark ? Color(white: 0.17) : Color(white: 0.94)
    }

    /// Walks the candidate sources in order and keeps the first one that
    /// decodes.
    ///
    /// `/apple-touch-icon.png` comes before `/favicon.ico` because it is the
    /// icon the site built for a home screen — usually 152-180 pixels, which
    /// stays sharp at 40 points, where a 16-or-32-pixel `.ico` is mush. An
    /// explicit URL from the page itself outranks both.
    private func loadIcon() async {
        image = nil
        for candidate in candidateUrls {
            guard let url = candidate else { continue }
            if let cached = Self.iconCache.object(forKey: url.absoluteString as NSString) {
                image = cached
                return
            }
            guard let (data, _) = try? await URLSession.shared.data(from: url),
                  let decoded = UIImage(data: data) else { continue }
            let prepared = Self.trimmedToOpaqueBounds(decoded)
            Self.iconCache.setObject(prepared, forKey: url.absoluteString as NSString)
            image = prepared
            return
        }
    }

    /// The icon cropped to the pixels that actually paint.
    ///
    /// A site's icon file is not always its artwork: favicons routinely carry
    /// transparent margins, and a glyph drawn across four fifths of its
    /// canvas lands in the tile visibly smaller than the neighbour that fills
    /// its own — the unevenness the uniform backdrop alone could not fix.
    /// Cropping to the opaque bounds makes every icon answer the tile at the
    /// same size. A fully opaque icon — the usual apple-touch-icon — has
    /// nothing to crop and is handed back untouched.
    private static func trimmedToOpaqueBounds(_ image: UIImage) -> UIImage {
        guard let cgImage = image.cgImage else { return image }
        let width = cgImage.width
        let height = cgImage.height
        guard width > 1, height > 1,
              let context = CGContext(
                  data: nil,
                  width: width,
                  height: height,
                  bitsPerComponent: 8,
                  bytesPerRow: width * 4,
                  space: CGColorSpaceCreateDeviceRGB(),
                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              ) else { return image }

        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let data = context.data else { return image }
        let pixels = data.bindMemory(to: UInt8.self, capacity: width * height * 4)

        let alphaThreshold: UInt8 = 6
        var minX = width
        var minY = height
        var maxX = -1
        var maxY = -1
        for y in 0..<height {
            let row = y * width * 4
            for x in 0..<width where pixels[row + x * 4 + 3] > alphaThreshold {
                if x < minX { minX = x }
                if x > maxX { maxX = x }
                if y < minY { minY = y }
                if y > maxY { maxY = y }
            }
        }

        // Nothing opaque, or nothing to trim: the original stands.
        guard maxX >= minX, maxY >= minY,
              minX > 0 || minY > 0 || maxX < width - 1 || maxY < height - 1 else {
            return image
        }

        let bounds = CGRect(
            x: minX,
            y: minY,
            width: maxX - minX + 1,
            height: maxY - minY + 1
        )
        guard let cropped = cgImage.cropping(to: bounds) else { return image }
        return UIImage(cgImage: cropped, scale: image.scale, orientation: .up)
    }

    /// The URLs to try, strongest first.
    private var candidateUrls: [URL?] {
        var urls: [URL?] = []
        if let faviconUrl, !faviconUrl.isEmpty {
            urls.append(URL(string: faviconUrl))
        }
        let trimmed = host.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty, trimmed.contains(".") {
            urls.append(URL(string: "https://\(trimmed)/apple-touch-icon.png"))
            urls.append(URL(string: "https://\(trimmed)/favicon.ico"))
        }
        return urls
    }

    private var initial: String {
        let trimmed = host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
        return String(trimmed.first.map(String.init) ?? "?").uppercased()
    }

    /// A stable hue from the host. FNV-1a rather than `hashValue`, which is
    /// seeded per process and would make a site change colour between launches.
    ///
    /// The hue colours the letter only — the tile stays neutral — so sites
    /// without an icon stay distinguishable without breaking the grid's
    /// uniform backdrop.
    private var color: Color {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in host.lowercased().utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01b3
        }
        let hue = Double(hash % 360) / 360.0
        return Color(hue: hue, saturation: 0.45, brightness: 0.62)
    }
}

// MARK: - Sheets

/// The bottom sheet detents Vela uses.
enum BrowserSheetDetent {
    static func forContentHeight(_ height: CGFloat) -> PresentationDetent {
        switch height {
        case ..<160: return .height(180)
        case ..<300: return .medium
        default: return .large
        }
    }
}

// MARK: - Badges

/// A compact pill that shows the current privacy mode.
struct PrivacyModeBadge: View {
    var mode: BrowserSessionPrivacyMode

    var body: some View {
        if mode == .private {
            Label("无痕", systemImage: "eyeglasses")
                .labelStyle(.titleAndIcon)
                .font(.caption2.weight(.semibold))
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Color.purple.opacity(0.20), in: Capsule())
                .foregroundStyle(Color.purple)
        }
    }
}

// MARK: - Empty states
/// The one empty-state component. Every list that can be empty uses this, so
/// "no bookmarks", "no history" and "no downloads" cannot drift apart.
///
/// `ContentUnavailableView` rather than a hand-built stack: it already handles
/// Dynamic Type, the icon weight and the centred alignment inside a scroll view.
struct EmptyState: View {
    var systemImage: String
    var title: String
    var message: String
    /// An optional primary action, e.g. "新建标签页" on an empty tab list.
    var actionTitle: String?
    var action: (() -> Void)?

    init(
        systemImage: String,
        title: String,
        message: String,
        actionTitle: String? = nil,
        action: (() -> Void)? = nil
    ) {
        self.systemImage = systemImage
        self.title = title
        self.message = message
        self.actionTitle = actionTitle
        self.action = action
    }

    var body: some View {
        ContentUnavailableView {
            Label(title, systemImage: systemImage)
        } description: {
            Text(message)
        } actions: {
            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .buttonStyle(.borderedProminent)
            }
        }
    }
}

// MARK: - Collapsible sections

/// A section header that folds its content away, with the count and the chevron
/// on the trailing edge.
///
/// The surfaces here have more to show than fits, so the header is a control
/// rather than a label: everything below the first fold is one tap away.
struct CollapsibleSectionHeader: View {
    var title: String
    var systemImage: String?
    var count: Int?
    var isExpanded: Bool
    var onToggle: () -> Void

    @Environment(\.browserPalette) private var palette

    init(
        title: String,
        systemImage: String? = nil,
        count: Int? = nil,
        isExpanded: Bool,
        onToggle: @escaping () -> Void
    ) {
        self.title = title
        self.systemImage = systemImage
        self.count = count
        self.isExpanded = isExpanded
        self.onToggle = onToggle
    }

    var body: some View {
        Button(action: onToggle) {
            HStack(spacing: BrowserSpacing.tight) {
                if let systemImage {
                    Image(systemName: systemImage)
                        .font(.system(size: 11, weight: .semibold))
                        .frame(width: 14)
                }

                Text(title)
                    .font(.system(size: 13, weight: .semibold))

                if let count {
                    Text("\(count)")
                        .font(.system(size: 11, weight: .medium))
                        .monospacedDigit()
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1)
                        .background(palette.controlFill, in: Capsule())
                }

                Spacer(minLength: 0)

                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .bold))
                    .rotationEffect(.degrees(isExpanded ? 90 : 0))
            }
            .foregroundStyle(palette.secondaryText)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(count.map { "\(title)，\($0) 项" } ?? title)
        .accessibilityHint(isExpanded ? "折叠" : "展开")
    }
}

/// A titled block that can be folded away, used by the new-tab surface, the
/// bookmark list and the history list so all three fold the same way.
struct CollapsibleSection<Content: View>: View {
    var title: String
    var systemImage: String?
    var count: Int?
    @Binding var isExpanded: Bool
    var content: () -> Content

    init(
        title: String,
        systemImage: String? = nil,
        count: Int? = nil,
        isExpanded: Binding<Bool>,
        @ViewBuilder content: @escaping () -> Content
    ) {
        self.title = title
        self.systemImage = systemImage
        self.count = count
        self._isExpanded = isExpanded
        self.content = content
    }

    var body: some View {
        VStack(alignment: .leading, spacing: BrowserSpacing.compact) {
            CollapsibleSectionHeader(
                title: title,
                systemImage: systemImage,
                count: count,
                isExpanded: isExpanded,
                onToggle: {
                    withAnimation(.snappy(duration: 0.25)) { isExpanded.toggle() }
                }
            )

            if isExpanded {
                content()
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
    }
}

// MARK: - Chrome contrast

/// Whether the surface the floating chrome sits over reads light or dark.
///
/// The chrome is glass over whatever is behind it — the home surface's own
/// picture, the palette surface, or the live page — and glass does not
/// guarantee legibility: white ink on a bright sky is as unreadable as black
/// ink on a night page. What decides the ink is the luminance of the strip
/// the bar actually covers, so both measurements here look at that strip and
/// not the whole surface.
enum ChromeBackdrop {
    /// The threshold at or above which a mean luminance counts as light.
    static let lightThreshold = 0.6

    /// The mean luminance of an image's bottom strip — the region the command
    /// bar floats over — against `lightThreshold`.
    ///
    /// The picture is squashed into a few dozen pixels first: an average is
    /// the answer wanted here, and a 16×48 read costs nothing next to a full
    /// histogram. `nil` when the picture has no bitmap to read.
    static func bottomStripIsLight(_ image: UIImage) -> Bool? {
        guard let cgImage = image.cgImage else { return nil }
        let width = 16
        let height = 48
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let context = CGContext(
            data: &pixels,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )
        guard let context else { return nil }
        context.interpolationQuality = .low
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))

        // The context's first scanline in memory is the top of the drawn
        // picture, so the strip the bar covers is the last rows read here.
        var total = 0.0
        var samples = 0
        for row in (height - 16)..<height {
            for column in 0..<width {
                let offset = (row * width + column) * 4
                total += 0.2126 * Double(pixels[offset]) / 255
                    + 0.7152 * Double(pixels[offset + 1]) / 255
                    + 0.0722 * Double(pixels[offset + 2]) / 255
                samples += 1
            }
        }
        return total / Double(max(samples, 1)) > lightThreshold
    }

    /// A palette colour's own lightness, resolved for one appearance.
    ///
    /// The palette's colours are dynamic — they re-resolve when the appearance
    /// changes — so the answer is asked of the mode it will be drawn in.
    /// `nil` when the colour carries no readable components.
    static func surfaceIsLight(_ color: Color, scheme: ColorScheme) -> Bool? {
        var red: CGFloat = 0
        var green: CGFloat = 0
        var blue: CGFloat = 0
        var alpha: CGFloat = 0
        let style: UIUserInterfaceStyle = scheme == .dark ? .dark : .light
        let resolved = UIColor(color).resolvedColor(with: UITraitCollection(userInterfaceStyle: style))
        guard resolved.getRed(&red, green: &green, blue: &blue, alpha: &alpha) else { return nil }
        let luminance = 0.2126 * Double(red) + 0.7152 * Double(green) + 0.0722 * Double(blue)
        return luminance > lightThreshold
    }
}
