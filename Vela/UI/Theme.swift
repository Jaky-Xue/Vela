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
    /// The bottom address panel, which is the primary chrome on a phone.
    static let addressBarHeight: CGFloat = 46
    static let toolbarHeight: CGFloat = 48
    /// The widest a centred dialog grows.
    static let dialogMaxWidth: CGFloat = 420
    /// The tab strip's cell size on a large screen.
    static let tabStripItemWidth: CGFloat = 200
    static let tabStripItemHeight: CGFloat = 34
    /// How far the toolbar slides away when the page scrolls down.
    ///
    /// Generously past the panel's own height plus any bottom safe area rather
    /// than measured exactly. The bar sits against the bottom edge, so
    /// overshooting by a few points moves it further off-screen and changes
    /// nothing, while undershooting leaves a strip of chrome material parked at
    /// the bottom of the page — which is the failure the exact value is most
    /// likely to produce, because the safe-area inset is not known here.
    static let toolbarCollapseDistance: CGFloat = 200

    // Omnibox. These are the suggestion card's own metrics.
    static let omniboxRowHeight: CGFloat = 52
    static let omniboxHeaderHeight: CGFloat = 34
    /// The tallest the suggestion card may grow before it scrolls internally.
    /// Expressed as a fraction of the screen so a short list on a tall screen
    /// does not open a card with a lake of empty material in it.
    static let omniboxCardHeightFraction: CGFloat = 0.55
    /// A hard ceiling for the same card, so an iPad in landscape does not get a
    /// suggestion list taller than the page it is covering.
    static let omniboxCardMaxHeight: CGFloat = 460

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
    /// How far the omnibox and the toolbar panel sit from the side edges.
    static let sideInset: CGFloat = 12
    /// How far the toolbar panel sits above the bottom safe area.
    static let bottomInset: CGFloat = 8
    /// How far the omnibox sits below the top safe area.
    static let topInset: CGFloat = 6
    /// The gap between the toolbar's glyphs and the panel's own edge.
    static let panelPadding: CGFloat = 4
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
/// strip of the screen: the omnibox, the toolbar panel.
///
/// Two things separate this from `browserCard`. The fill is a *tint under a
/// material* selected for chrome rather than for content, so a panel over a
/// photograph keeps its own tone instead of taking on the photograph's; and the
/// stroke is drawn inside the shape, so the panel's silhouette stays crisp
/// against a busy page without the border growing the view by a point.
struct BrowserFloatingChrome: ViewModifier {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.browserPalette) private var palette

    var radius: CGFloat
    var material: Material
    /// How strongly the palette's control fill sits under the material. A higher
    /// value makes the panel more opaque and more clearly a surface of its own;
    /// the omnibox wants more of it than the toolbar, because text has to be
    /// legible on top of it.
    var tintStrength: Double
    var elevation: BrowserElevation

    @ViewBuilder
    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        content
            .background {
                shape.fill(palette.controlFill.opacity(tintStrength))
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
    /// Wraps the receiver in the floating-chrome treatment.
    func browserFloatingChrome(
        radius: CGFloat = BrowserRadius.floating,
        material: Material = .regularMaterial,
        tintStrength: Double = 0.5,
        elevation: BrowserElevation = .floating
    ) -> some View {
        modifier(
            BrowserFloatingChrome(
                radius: radius,
                material: material,
                tintStrength: tintStrength,
                elevation: elevation
            )
        )
    }

    /// Paints the strip of chrome material the floating controls sit on.
    ///
    /// The material reaches past the safe area on `edge` so the status bar and
    /// the home indicator keep their contrast without the controls themselves
    /// moving out of the layout — which is what lets the omnibox be inset from
    /// the top while the blur behind it still starts at the very top of the
    /// screen.
    func browserChromeSubstrate(edge: Edge.Set) -> some View {
        background {
            Rectangle()
                .fill(.bar)
                .ignoresSafeArea(edges: edge)
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

    var body: some View {
        Group {
            if let resolvedFaviconUrl, let url = URL(string: resolvedFaviconUrl) {
                AsyncImage(url: url) { image in
                    image.resizable().scaledToFit()
                } placeholder: {
                    placeholder
                }
            } else {
                placeholder
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: size * 0.22, style: .continuous))
    }

    /// The icon URL to try, given what the caller knows.
    ///
    /// An explicit URL wins. Otherwise the site's own `/favicon.ico` is used,
    /// which is what most sites serve and the rest answer with a 404 — in which
    /// case `AsyncImage` reports a failure and the letter swatch is what stays
    /// on screen. WebKit does not expose a page's declared icon to the host app,
    /// so there is no better source than the well-known path. Rows are built
    /// lazily, so this costs one request per icon actually on screen, and the
    /// shared URL cache answers the repeats.
    private var resolvedFaviconUrl: String? {
        if let faviconUrl, !faviconUrl.isEmpty { return faviconUrl }
        let trimmed = host.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.contains(".") else { return nil }
        return "https://\(trimmed)/favicon.ico"
    }

    private var placeholder: some View {
        ZStack {
            color
            Text(initial)
                .font(.system(size: size * 0.5, weight: .semibold))
                .foregroundStyle(.white)
        }
    }

    private var initial: String {
        let trimmed = host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
        return String(trimmed.first.map(String.init) ?? "?").uppercased()
    }

    /// A stable hue from the host. FNV-1a rather than `hashValue`, which is
    /// seeded per process and would make a site change colour between launches.
    ///
    /// The saturation and brightness are pinned to values that leave white text
    /// legible on top, in both appearances, which is why the swatch is not
    /// derived from the palette.
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
