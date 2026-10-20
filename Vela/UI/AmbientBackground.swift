//
//  AmbientBackground.swift
//  Vela
//
//  The app-wide background: a palette surface, or a soft field of colour
//  behind it.
//
//  The field is deliberately static. An earlier version drifted the light
//  sources with a repeating animation; every frame re-evaluated several
//  enormous blurred layers, and the cost showed up as dropped frames while a
//  page scrolled. The light here is fixed, with a neutral veil and a fine
//  grain that keep the large gradients from banding.
//
//  Eight fields, warm, cool and neutral, separated by hue rather than by
//  saturation: 暖阳 (peach/orange), 晚霞 (coral/rose), 青柠 (yellow-green), 极光
//  (mint/teal), 冰川 (azure), 紫雾 (violet), 缤纷 (rose, mint, sky and
//  violet together) and 曜黑 (graphite — the neutral field, where the grain
//  and the specular sheen are the texture rather than colour). The light
//  bases are pale so text stays legible; each mesh carries enough chroma for
//  the choice to be obvious at a glance.
//  纯净, the palette surface, is the shipped default: a new install starts on
//  the plain surface and the fields are a choice, not an imposition.
//

import SwiftUI
import UIKit

// MARK: - Style

/// The global background style the user chose.
///
/// Persisted by raw value in the preferences document, as an optional String,
/// for the decode-compatibility reason every optional preference carries.
public enum BrowserBackgroundStyle: String, CaseIterable, Codable, Sendable, Identifiable {
    /// The palette surface, unchanged: pure white in light, pure black in dark.
    case solid
    /// Graphite and near-black: the neutral field, carried by texture.
    case onyx
    /// Peach and orange: the warm morning field.
    case sunrise
    /// Coral and rose: the warm evening field.
    case sunset
    /// Yellow-green: the fresh, leafy field.
    case lime
    /// Mint and teal: the cool aurora field.
    case aurora
    /// Ice blue and azure: the cool daylight field.
    case glacier
    /// Lavender and violet: the cool dusk field.
    case violet
    /// Rose, mint, sky and violet at once: the field with no single hue.
    case colorful

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .solid: return "纯净"
        case .onyx: return "曜黑"
        case .sunrise: return "暖阳"
        case .sunset: return "晚霞"
        case .lime: return "青柠"
        case .aurora: return "极光"
        case .glacier: return "冰川"
        case .violet: return "紫雾"
        case .colorful: return "缤纷"
        }
    }

    public var summary: String {
        switch self {
        case .solid: return "纯白与纯黑，来自配色"
        case .onyx: return "细纹石墨与曜黑"
        case .sunrise: return "蜜桃与暖橙"
        case .sunset: return "珊瑚与玫红"
        case .lime: return "嫩芽与青柠"
        case .aurora: return "薄荷与青绿"
        case .glacier: return "冰蓝与天青"
        case .violet: return "薰衣草与紫罗兰"
        case .colorful: return "玫红、薄荷、晴空与紫罗兰"
        }
    }

    public var symbolName: String {
        switch self {
        case .solid: return "circle.fill"
        case .onyx: return "moon.fill"
        case .sunrise: return "sun.max.fill"
        case .sunset: return "sunset.fill"
        case .lime: return "leaf.fill"
        case .aurora: return "sparkles"
        case .glacier: return "snowflake"
        case .violet: return "moon.stars.fill"
        case .colorful: return "paintpalette.fill"
        }
    }

    /// Whether the style paints anything beyond the palette surface.
    public var usesAmbient: Bool { self != .solid }

    /// Resolves a stored raw value, falling back to the shipped default.
    ///
    /// Raw values that no longer name a case map to the field closest in
    /// role, so an existing choice is kept rather than reset: the old warm
    /// `amber` becomes 暖阳, and the older `dawn`/`midnight` pair becomes
    /// 暖阳/冰川. No value at all — what a fresh install has — resolves to
    /// 纯净, which is the shipped default.
    public static func resolve(_ rawValue: String?) -> BrowserBackgroundStyle {
        guard let rawValue else { return .solid }
        if let style = BrowserBackgroundStyle(rawValue: rawValue) {
            return style
        }
        switch rawValue {
        case "amber", "dawn": return .sunrise
        case "midnight": return .glacier
        default: return .solid
        }
    }
}

// MARK: - Environment

private struct BrowserBackgroundStyleKey: EnvironmentKey {
    static let defaultValue: BrowserBackgroundStyle = .solid
}

extension EnvironmentValues {
    /// The background style in force, injected once at the app root. Views that
    /// paint a surface read it to decide whether to paint an opaque fill or a
    /// veil that lets the field through.
    var browserBackgroundStyle: BrowserBackgroundStyle {
        get { self[BrowserBackgroundStyleKey.self] }
        set { self[BrowserBackgroundStyleKey.self] = newValue }
    }
}

// MARK: - The field

/// One light source.
private struct AmbientBlobSpec {
    var light: Color
    var dark: Color
    /// Centre as a fraction of the container.
    var x: CGFloat
    var y: CGFloat
    /// Diameter as a fraction of the container's longer edge.
    var diameter: CGFloat
    var opacity: Double
}

/// The global background surface.
///
/// It fills whatever it is given and ignores safe areas, so the same view can
/// sit behind the shell, behind a sheet's content, or behind a preview card.
struct AmbientBackgroundView: View {
    @Environment(\.browserPalette) private var palette
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.browserBackgroundStyle) private var style

    var body: some View {
        GeometryReader { geo in
            let size = geo.size
            ZStack {
                base

                if style.usesAmbient, size.width > 1, size.height > 1 {
                    if #available(iOS 18.0, *) {
                        meshField
                    } else {
                        ForEach(specs.indices, id: \.self) { index in
                            blob(specs[index], in: size)
                        }
                    }

                    // A thin frosted pane. It adds the glass surface without
                    // washing out the pale colours underneath.
                    Rectangle()
                        .fill(.ultraThinMaterial)
                        .opacity(colorScheme == .dark ? 0.06 : 0.10)
                        .allowsHitTesting(false)

                    specular(in: size)

                    AmbientGrain()
                        .opacity(colorScheme == .dark ? 0.18 : 0.24)
                        .blendMode(.overlay)
                        .allowsHitTesting(false)

                    LinearGradient(
                        stops: [
                            .init(color: .white.opacity(colorScheme == .dark ? 0.06 : 0.20), location: 0),
                            .init(color: .clear, location: 0.48)
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                    .blendMode(.plusLighter)
                    .allowsHitTesting(false)

                    RadialGradient(
                        colors: [.clear, .black.opacity(colorScheme == .dark ? 0.10 : 0.03)],
                        center: .center,
                        startRadius: max(size.width, size.height) * 0.36,
                        endRadius: max(size.width, size.height) * 0.86
                    )
                    .allowsHitTesting(false)
                }
            }
            .frame(width: size.width, height: size.height)
            .clipped()
        }
        .ignoresSafeArea()
        .accessibilityHidden(true)
    }

    /// The style's own base, with a neutral veil rather than the palette
    /// surface: a green or blue palette must not cool a warm field.
    private var base: some View {
        let stops = baseColors
        return ZStack {
            LinearGradient(
                stops: [
                    .init(color: stops[0], location: 0),
                    .init(color: stops[1], location: 0.55),
                    .init(color: stops[2], location: 1)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            if style.usesAmbient {
                (colorScheme == .dark ? Color.black : Color.white)
                    .opacity(colorScheme == .dark ? 0.08 : 0.10)
            }
        }
    }

    /// The base gradient stops for the active style and appearance.
    private var baseColors: [Color] {
        switch style {
        case .solid:
            let surface = palette.tokens(for: colorScheme).surface
            return [surface, surface, surface]
        case .onyx:
            return colorScheme == .dark
                ? [
                    Color(red: 0.043, green: 0.045, blue: 0.049),
                    Color(red: 0.055, green: 0.058, blue: 0.063),
                    Color(red: 0.046, green: 0.048, blue: 0.052)
                ]
                : [
                    Color(red: 0.933, green: 0.936, blue: 0.941),
                    Color(red: 0.886, green: 0.890, blue: 0.898),
                    Color(red: 0.914, green: 0.918, blue: 0.925)
                ]
        case .sunrise:
            return colorScheme == .dark
                ? [
                    Color(red: 0.067, green: 0.053, blue: 0.040),
                    Color(red: 0.080, green: 0.063, blue: 0.047),
                    Color(red: 0.069, green: 0.055, blue: 0.042),
                ]
                : [
                    Color(red: 1.000, green: 0.973, blue: 0.941),
                    Color(red: 1.000, green: 0.914, blue: 0.839),
                    Color(red: 1.000, green: 0.949, blue: 0.902)
                ]
        case .sunset:
            return colorScheme == .dark
                ? [
                    Color(red: 0.070, green: 0.045, blue: 0.055),
                    Color(red: 0.085, green: 0.052, blue: 0.064),
                    Color(red: 0.072, green: 0.047, blue: 0.057),
                ]
                : [
                    Color(red: 1.000, green: 0.969, blue: 0.980),
                    Color(red: 1.000, green: 0.894, blue: 0.933),
                    Color(red: 1.000, green: 0.941, blue: 0.965)
                ]
        case .lime:
            return colorScheme == .dark
                ? [
                    Color(red: 0.050, green: 0.058, blue: 0.034),
                    Color(red: 0.060, green: 0.070, blue: 0.040),
                    Color(red: 0.052, green: 0.061, blue: 0.036),
                ]
                : [
                    Color(red: 0.984, green: 0.992, blue: 0.949),
                    Color(red: 0.937, green: 0.969, blue: 0.863),
                    Color(red: 0.969, green: 0.984, blue: 0.914)
                ]
        case .aurora:
            return colorScheme == .dark
                ? [
                    Color(red: 0.036, green: 0.060, blue: 0.056),
                    Color(red: 0.043, green: 0.072, blue: 0.067),
                    Color(red: 0.037, green: 0.062, blue: 0.058),
                ]
                : [
                    Color(red: 0.949, green: 0.988, blue: 0.980),
                    Color(red: 0.867, green: 0.965, blue: 0.937),
                    Color(red: 0.933, green: 0.984, blue: 0.969)
                ]
        case .glacier:
            return colorScheme == .dark
                ? [
                    Color(red: 0.038, green: 0.048, blue: 0.070),
                    Color(red: 0.045, green: 0.057, blue: 0.082),
                    Color(red: 0.039, green: 0.050, blue: 0.072),
                ]
                : [
                    Color(red: 0.961, green: 0.980, blue: 1.000),
                    Color(red: 0.878, green: 0.933, blue: 0.984),
                    Color(red: 0.929, green: 0.965, blue: 1.000)
                ]
        case .violet:
            return colorScheme == .dark
                ? [
                    Color(red: 0.052, green: 0.043, blue: 0.070),
                    Color(red: 0.061, green: 0.050, blue: 0.082),
                    Color(red: 0.054, green: 0.045, blue: 0.074),
                ]
                : [
                    Color(red: 0.980, green: 0.969, blue: 1.000),
                    Color(red: 0.925, green: 0.890, blue: 0.984),
                    Color(red: 0.961, green: 0.941, blue: 1.000)
                ]
        case .colorful:
            return colorScheme == .dark
                ? [
                    Color(red: 0.048, green: 0.038, blue: 0.058),
                    Color(red: 0.034, green: 0.050, blue: 0.060),
                    Color(red: 0.043, green: 0.037, blue: 0.068),
                ]
                : [
                    Color(red: 1.000, green: 0.965, blue: 0.973),
                    Color(red: 0.941, green: 0.988, blue: 0.996),
                    Color(red: 0.969, green: 0.957, blue: 1.000)
                ]
        }
    }

    /// The Arc-style field: one mesh gradient carrying several pale, warm
    /// colours through each other.
    @available(iOS 18.0, *)
    private var meshField: some View {
        MeshGradient(
            width: 3,
            height: 3,
            points: [
                SIMD2<Float>(0, 0), SIMD2<Float>(0.5, 0), SIMD2<Float>(1, 0),
                SIMD2<Float>(0, 0.5), SIMD2<Float>(0.5, 0.5), SIMD2<Float>(1, 0.5),
                SIMD2<Float>(0, 1), SIMD2<Float>(0.5, 1), SIMD2<Float>(1, 1)
            ],
            colors: meshColors
        )
    }

    /// Nine warm stops per style. The hue families are peach/gold, coral/rose
    /// and cream/amber, so the three are recognisable at a glance.
    private var meshColors: [Color] {
        let dark = colorScheme == .dark
        switch style {
        case .solid:
            let surface = palette.tokens(for: colorScheme).surface
            return Array(repeating: surface, count: 9)
        case .onyx:
            return dark
                ? [
                    Color(red: 0.070, green: 0.073, blue: 0.079),
                    Color(red: 0.105, green: 0.110, blue: 0.118),
                    Color(red: 0.135, green: 0.142, blue: 0.152),
                    Color(red: 0.090, green: 0.094, blue: 0.101),
                    Color(red: 0.150, green: 0.158, blue: 0.170),
                    Color(red: 0.175, green: 0.184, blue: 0.198),
                    Color(red: 0.104, green: 0.109, blue: 0.117),
                    Color(red: 0.132, green: 0.139, blue: 0.149),
                    Color(red: 0.076, green: 0.079, blue: 0.086)
                ]
                : [
                    Color(red: 0.960, green: 0.963, blue: 0.968),
                    Color(red: 0.905, green: 0.910, blue: 0.918),
                    Color(red: 0.860, green: 0.866, blue: 0.876),
                    Color(red: 0.930, green: 0.933, blue: 0.940),
                    Color(red: 0.845, green: 0.852, blue: 0.864),
                    Color(red: 0.800, green: 0.808, blue: 0.822),
                    Color(red: 0.912, green: 0.917, blue: 0.926),
                    Color(red: 0.858, green: 0.865, blue: 0.877),
                    Color(red: 0.945, green: 0.949, blue: 0.955)
                ]
        case .sunrise:
            return dark
                ? [
                    Color(red: 0.098, green: 0.076, blue: 0.056),
                    Color(red: 0.150, green: 0.108, blue: 0.072),
                    Color(red: 0.186, green: 0.130, blue: 0.082),
                    Color(red: 0.118, green: 0.088, blue: 0.063),
                    Color(red: 0.212, green: 0.148, blue: 0.092),
                    Color(red: 0.244, green: 0.170, blue: 0.104),
                    Color(red: 0.136, green: 0.102, blue: 0.072),
                    Color(red: 0.184, green: 0.134, blue: 0.088),
                    Color(red: 0.104, green: 0.080, blue: 0.058),
                ]
                : [
                    Color(red: 1.000, green: 0.984, blue: 0.965),
                    Color(red: 1.000, green: 0.878, blue: 0.749),
                    Color(red: 1.000, green: 0.784, blue: 0.573),
                    Color(red: 1.000, green: 0.937, blue: 0.855),
                    Color(red: 1.000, green: 0.741, blue: 0.459),
                    Color(red: 1.000, green: 0.663, blue: 0.341),
                    Color(red: 1.000, green: 0.902, blue: 0.765),
                    Color(red: 1.000, green: 0.788, blue: 0.529),
                    Color(red: 1.000, green: 0.965, blue: 0.929)
                ]
        case .sunset:
            return dark
                ? [
                    Color(red: 0.100, green: 0.060, blue: 0.074),
                    Color(red: 0.156, green: 0.084, blue: 0.104),
                    Color(red: 0.192, green: 0.100, blue: 0.124),
                    Color(red: 0.120, green: 0.070, blue: 0.086),
                    Color(red: 0.222, green: 0.112, blue: 0.140),
                    Color(red: 0.254, green: 0.130, blue: 0.160),
                    Color(red: 0.142, green: 0.080, blue: 0.098),
                    Color(red: 0.192, green: 0.104, blue: 0.126),
                    Color(red: 0.106, green: 0.064, blue: 0.078),
                ]
                : [
                    Color(red: 1.000, green: 0.976, blue: 0.984),
                    Color(red: 1.000, green: 0.839, blue: 0.890),
                    Color(red: 1.000, green: 0.722, blue: 0.816),
                    Color(red: 1.000, green: 0.929, blue: 0.949),
                    Color(red: 1.000, green: 0.647, blue: 0.769),
                    Color(red: 1.000, green: 0.545, blue: 0.706),
                    Color(red: 1.000, green: 0.855, blue: 0.902),
                    Color(red: 1.000, green: 0.722, blue: 0.824),
                    Color(red: 1.000, green: 0.965, blue: 0.976)
                ]
        case .lime:
            return dark
                ? [
                    Color(red: 0.074, green: 0.086, blue: 0.050),
                    Color(red: 0.108, green: 0.126, blue: 0.070),
                    Color(red: 0.136, green: 0.158, blue: 0.086),
                    Color(red: 0.090, green: 0.104, blue: 0.060),
                    Color(red: 0.158, green: 0.184, blue: 0.098),
                    Color(red: 0.182, green: 0.212, blue: 0.114),
                    Color(red: 0.104, green: 0.120, blue: 0.068),
                    Color(red: 0.136, green: 0.158, blue: 0.088),
                    Color(red: 0.078, green: 0.090, blue: 0.054),
                ]
                : [
                    Color(red: 0.988, green: 0.996, blue: 0.953),
                    Color(red: 0.898, green: 0.957, blue: 0.788),
                    Color(red: 0.808, green: 0.914, blue: 0.667),
                    Color(red: 0.945, green: 0.976, blue: 0.867),
                    Color(red: 0.733, green: 0.871, blue: 0.529),
                    Color(red: 0.663, green: 0.831, blue: 0.427),
                    Color(red: 0.898, green: 0.953, blue: 0.784),
                    Color(red: 0.804, green: 0.902, blue: 0.620),
                    Color(red: 0.973, green: 0.988, blue: 0.925)
                ]
        case .aurora:
            return dark
                ? [
                    Color(red: 0.054, green: 0.086, blue: 0.080),
                    Color(red: 0.078, green: 0.126, blue: 0.116),
                    Color(red: 0.098, green: 0.158, blue: 0.145),
                    Color(red: 0.064, green: 0.098, blue: 0.090),
                    Color(red: 0.114, green: 0.184, blue: 0.168),
                    Color(red: 0.132, green: 0.212, blue: 0.194),
                    Color(red: 0.074, green: 0.116, blue: 0.106),
                    Color(red: 0.098, green: 0.154, blue: 0.142),
                    Color(red: 0.058, green: 0.092, blue: 0.084),
                ]
                : [
                    Color(red: 0.957, green: 0.996, blue: 0.988),
                    Color(red: 0.788, green: 0.953, blue: 0.914),
                    Color(red: 0.647, green: 0.898, blue: 0.835),
                    Color(red: 0.902, green: 0.976, blue: 0.957),
                    Color(red: 0.522, green: 0.835, blue: 0.753),
                    Color(red: 0.404, green: 0.776, blue: 0.690),
                    Color(red: 0.769, green: 0.953, blue: 0.918),
                    Color(red: 0.600, green: 0.898, blue: 0.835),
                    Color(red: 0.925, green: 0.988, blue: 0.973)
                ]
        case .glacier:
            return dark
                ? [
                    Color(red: 0.056, green: 0.070, blue: 0.100),
                    Color(red: 0.082, green: 0.104, blue: 0.146),
                    Color(red: 0.106, green: 0.132, blue: 0.186),
                    Color(red: 0.068, green: 0.084, blue: 0.118),
                    Color(red: 0.122, green: 0.150, blue: 0.210),
                    Color(red: 0.142, green: 0.176, blue: 0.240),
                    Color(red: 0.080, green: 0.098, blue: 0.138),
                    Color(red: 0.106, green: 0.130, blue: 0.184),
                    Color(red: 0.060, green: 0.074, blue: 0.104),
                ]
                : [
                    Color(red: 0.965, green: 0.984, blue: 1.000),
                    Color(red: 0.780, green: 0.886, blue: 0.973),
                    Color(red: 0.647, green: 0.804, blue: 0.949),
                    Color(red: 0.886, green: 0.941, blue: 0.992),
                    Color(red: 0.498, green: 0.710, blue: 0.914),
                    Color(red: 0.365, green: 0.616, blue: 0.871),
                    Color(red: 0.773, green: 0.878, blue: 0.965),
                    Color(red: 0.612, green: 0.776, blue: 0.937),
                    Color(red: 0.929, green: 0.969, blue: 1.000)
                ]
        case .violet:
            return dark
                ? [
                    Color(red: 0.074, green: 0.060, blue: 0.098),
                    Color(red: 0.108, green: 0.086, blue: 0.146),
                    Color(red: 0.136, green: 0.108, blue: 0.184),
                    Color(red: 0.090, green: 0.072, blue: 0.120),
                    Color(red: 0.156, green: 0.128, blue: 0.212),
                    Color(red: 0.180, green: 0.148, blue: 0.240),
                    Color(red: 0.104, green: 0.084, blue: 0.144),
                    Color(red: 0.136, green: 0.108, blue: 0.184),
                    Color(red: 0.080, green: 0.064, blue: 0.104),
                ]
                : [
                    Color(red: 0.980, green: 0.973, blue: 1.000),
                    Color(red: 0.851, green: 0.800, blue: 0.973),
                    Color(red: 0.749, green: 0.678, blue: 0.945),
                    Color(red: 0.933, green: 0.906, blue: 0.992),
                    Color(red: 0.667, green: 0.573, blue: 0.918),
                    Color(red: 0.584, green: 0.478, blue: 0.882),
                    Color(red: 0.847, green: 0.796, blue: 0.969),
                    Color(red: 0.733, green: 0.659, blue: 0.933),
                    Color(red: 0.961, green: 0.945, blue: 1.000)
                ]
        case .colorful:
            return dark
                ? [
                    Color(red: 0.082, green: 0.050, blue: 0.074),
                    Color(red: 0.148, green: 0.076, blue: 0.112),
                    Color(red: 0.160, green: 0.110, blue: 0.068),
                    Color(red: 0.054, green: 0.116, blue: 0.106),
                    Color(red: 0.060, green: 0.102, blue: 0.164),
                    Color(red: 0.090, green: 0.080, blue: 0.198),
                    Color(red: 0.126, green: 0.078, blue: 0.178),
                    Color(red: 0.180, green: 0.080, blue: 0.142),
                    Color(red: 0.058, green: 0.060, blue: 0.098),
                ]
                : [
                    Color(red: 1.000, green: 0.949, blue: 0.961),
                    Color(red: 1.000, green: 0.831, blue: 0.878),
                    Color(red: 1.000, green: 0.890, blue: 0.769),
                    Color(red: 0.839, green: 0.973, blue: 0.957),
                    Color(red: 0.733, green: 0.898, blue: 0.996),
                    Color(red: 0.769, green: 0.741, blue: 0.988),
                    Color(red: 0.910, green: 0.831, blue: 0.996),
                    Color(red: 0.996, green: 0.800, blue: 0.898),
                    Color(red: 0.953, green: 0.973, blue: 1.000)
                ]
        }
    }

    /// Two faint diagonal highlights: the reflection a pane of glass gives
    /// when it sits in front of a lit field. Static, like everything else here.
    private func specular(in size: CGSize) -> some View {
        let longEdge = max(size.width, size.height)
        return ZStack {
            Rectangle()
                .fill(
                    LinearGradient(
                        colors: [.clear, .white.opacity(colorScheme == .dark ? 0.10 : 0.22), .clear],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                )
                .frame(width: longEdge * 1.5, height: 3)
                .blur(radius: 6)
                .rotationEffect(.degrees(-24))
                .position(x: size.width * 0.32, y: size.height * 0.20)

            Rectangle()
                .fill(
                    LinearGradient(
                        colors: [.clear, .white.opacity(colorScheme == .dark ? 0.06 : 0.14), .clear],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                )
                .frame(width: longEdge * 1.2, height: 2)
                .blur(radius: 4)
                .rotationEffect(.degrees(-24))
                .position(x: size.width * 0.58, y: size.height * 0.64)
        }
        .blendMode(.plusLighter)
        .allowsHitTesting(false)
    }

    private func blob(_ spec: AmbientBlobSpec, in size: CGSize) -> some View {
        let longEdge = max(size.width, size.height)
        let diameter = longEdge * spec.diameter
        let color = colorScheme == .dark ? spec.dark : spec.light

        return Circle()
            .fill(
                RadialGradient(
                    colors: [
                        color.opacity(spec.opacity),
                        color.opacity(spec.opacity * 0.35),
                        color.opacity(0)
                    ],
                    center: .center,
                    startRadius: 0,
                    endRadius: diameter * 0.5
                )
            )
            .frame(width: diameter, height: diameter)
            .blur(radius: diameter * 0.13)
            .blendMode(colorScheme == .dark ? .plusLighter : .normal)
            .position(x: size.width * spec.x, y: size.height * spec.y)
            .allowsHitTesting(false)
    }

    /// Four light sources for the pre-iOS-18 fallback. Their hues match the
    /// mesh families: peach/gold, coral/rose, cream/amber.
    private var specs: [AmbientBlobSpec] {
        let isDark = colorScheme == .dark

        func spec(
            _ light: Color,
            _ darkColor: Color,
            x: CGFloat,
            y: CGFloat,
            diameter: CGFloat,
            lightOpacity: Double,
            darkOpacity: Double
        ) -> AmbientBlobSpec {
            AmbientBlobSpec(
                light: light,
                dark: darkColor,
                x: x,
                y: y,
                diameter: diameter,
                opacity: isDark ? darkOpacity : lightOpacity
            )
        }

        switch style {
        case .solid:
            return []
        case .onyx:
            return [
                spec(
                    Color(red: 0.93, green: 0.93, blue: 0.94),
                    Color(red: 0.42, green: 0.43, blue: 0.46),
                    x: 0.14, y: 0.12, diameter: 1.20,
                    lightOpacity: 0.30, darkOpacity: 0.12
                ),
                spec(
                    Color(red: 0.88, green: 0.89, blue: 0.91),
                    Color(red: 0.36, green: 0.38, blue: 0.41),
                    x: 0.86, y: 0.28, diameter: 1.10,
                    lightOpacity: 0.26, darkOpacity: 0.10
                ),
                spec(
                    Color(red: 0.90, green: 0.91, blue: 0.93),
                    Color(red: 0.33, green: 0.35, blue: 0.38),
                    x: 0.74, y: 0.86, diameter: 1.15,
                    lightOpacity: 0.26, darkOpacity: 0.10
                ),
                spec(
                    Color(red: 0.95, green: 0.95, blue: 0.96),
                    Color(red: 0.45, green: 0.46, blue: 0.49),
                    x: 0.10, y: 0.86, diameter: 0.80,
                    lightOpacity: 0.16, darkOpacity: 0.07
                )
            ]
        case .sunrise:
            return [
                spec(
                    Color(red: 1.00, green: 0.87, blue: 0.74),
                    Color(red: 0.82, green: 0.60, blue: 0.38),
                    x: 0.14, y: 0.12, diameter: 1.20,
                    lightOpacity: 0.34, darkOpacity: 0.13
                ),
                spec(
                    Color(red: 1.00, green: 0.93, blue: 0.78),
                    Color(red: 0.72, green: 0.56, blue: 0.30),
                    x: 0.86, y: 0.26, diameter: 1.10,
                    lightOpacity: 0.30, darkOpacity: 0.07
                ),
                spec(
                    Color(red: 1.00, green: 0.80, blue: 0.66),
                    Color(red: 0.76, green: 0.48, blue: 0.27),
                    x: 0.76, y: 0.86, diameter: 1.15,
                    lightOpacity: 0.30, darkOpacity: 0.07
                ),
                spec(
                    Color(red: 1.00, green: 0.90, blue: 0.84),
                    Color(red: 0.58, green: 0.40, blue: 0.26),
                    x: 0.10, y: 0.86, diameter: 0.80,
                    lightOpacity: 0.18, darkOpacity: 0.07
                )
            ]
        case .sunset:
            return [
                spec(
                    Color(red: 1.00, green: 0.78, blue: 0.82),
                    Color(red: 0.86, green: 0.46, blue: 0.58),
                    x: 0.14, y: 0.12, diameter: 1.20,
                    lightOpacity: 0.34, darkOpacity: 0.13
                ),
                spec(
                    Color(red: 1.00, green: 0.70, blue: 0.80),
                    Color(red: 0.74, green: 0.36, blue: 0.50),
                    x: 0.86, y: 0.28, diameter: 1.10,
                    lightOpacity: 0.30, darkOpacity: 0.07
                ),
                spec(
                    Color(red: 0.96, green: 0.76, blue: 0.90),
                    Color(red: 0.60, green: 0.32, blue: 0.48),
                    x: 0.74, y: 0.86, diameter: 1.15,
                    lightOpacity: 0.28, darkOpacity: 0.10
                ),
                spec(
                    Color(red: 1.00, green: 0.86, blue: 0.84),
                    Color(red: 0.52, green: 0.30, blue: 0.38),
                    x: 0.10, y: 0.86, diameter: 0.80,
                    lightOpacity: 0.18, darkOpacity: 0.07
                )
            ]
        case .lime:
            return [
                spec(
                    Color(red: 0.90, green: 0.96, blue: 0.72),
                    Color(red: 0.60, green: 0.72, blue: 0.34),
                    x: 0.14, y: 0.13, diameter: 1.20,
                    lightOpacity: 0.34, darkOpacity: 0.13
                ),
                spec(
                    Color(red: 0.82, green: 0.93, blue: 0.62),
                    Color(red: 0.52, green: 0.64, blue: 0.28),
                    x: 0.86, y: 0.28, diameter: 1.10,
                    lightOpacity: 0.30, darkOpacity: 0.07
                ),
                spec(
                    Color(red: 0.74, green: 0.88, blue: 0.52),
                    Color(red: 0.46, green: 0.58, blue: 0.24),
                    x: 0.75, y: 0.86, diameter: 1.15,
                    lightOpacity: 0.30, darkOpacity: 0.07
                ),
                spec(
                    Color(red: 0.88, green: 0.95, blue: 0.74),
                    Color(red: 0.40, green: 0.50, blue: 0.22),
                    x: 0.10, y: 0.86, diameter: 0.80,
                    lightOpacity: 0.18, darkOpacity: 0.07
                )
            ]
        case .aurora:
            return [
                spec(
                    Color(red: 0.76, green: 0.95, blue: 0.90),
                    Color(red: 0.34, green: 0.72, blue: 0.66),
                    x: 0.14, y: 0.12, diameter: 1.20,
                    lightOpacity: 0.34, darkOpacity: 0.13
                ),
                spec(
                    Color(red: 0.64, green: 0.90, blue: 0.84),
                    Color(red: 0.28, green: 0.64, blue: 0.58),
                    x: 0.86, y: 0.28, diameter: 1.10,
                    lightOpacity: 0.30, darkOpacity: 0.07
                ),
                spec(
                    Color(red: 0.52, green: 0.84, blue: 0.78),
                    Color(red: 0.24, green: 0.56, blue: 0.52),
                    x: 0.74, y: 0.86, diameter: 1.15,
                    lightOpacity: 0.30, darkOpacity: 0.07
                ),
                spec(
                    Color(red: 0.78, green: 0.95, blue: 0.91),
                    Color(red: 0.22, green: 0.48, blue: 0.44),
                    x: 0.10, y: 0.86, diameter: 0.80,
                    lightOpacity: 0.18, darkOpacity: 0.07
                )
            ]
        case .glacier:
            return [
                spec(
                    Color(red: 0.78, green: 0.90, blue: 0.98),
                    Color(red: 0.34, green: 0.58, blue: 0.82),
                    x: 0.14, y: 0.12, diameter: 1.20,
                    lightOpacity: 0.34, darkOpacity: 0.13
                ),
                spec(
                    Color(red: 0.64, green: 0.82, blue: 0.96),
                    Color(red: 0.28, green: 0.50, blue: 0.74),
                    x: 0.86, y: 0.28, diameter: 1.10,
                    lightOpacity: 0.30, darkOpacity: 0.07
                ),
                spec(
                    Color(red: 0.52, green: 0.74, blue: 0.93),
                    Color(red: 0.24, green: 0.44, blue: 0.68),
                    x: 0.74, y: 0.86, diameter: 1.15,
                    lightOpacity: 0.30, darkOpacity: 0.07
                ),
                spec(
                    Color(red: 0.76, green: 0.90, blue: 0.99),
                    Color(red: 0.20, green: 0.38, blue: 0.60),
                    x: 0.10, y: 0.86, diameter: 0.80,
                    lightOpacity: 0.18, darkOpacity: 0.07
                )
            ]
        case .violet:
            return [
                spec(
                    Color(red: 0.86, green: 0.82, blue: 0.98),
                    Color(red: 0.52, green: 0.42, blue: 0.82),
                    x: 0.14, y: 0.12, diameter: 1.20,
                    lightOpacity: 0.34, darkOpacity: 0.13
                ),
                spec(
                    Color(red: 0.78, green: 0.72, blue: 0.96),
                    Color(red: 0.46, green: 0.36, blue: 0.74),
                    x: 0.86, y: 0.28, diameter: 1.10,
                    lightOpacity: 0.30, darkOpacity: 0.07
                ),
                spec(
                    Color(red: 0.70, green: 0.62, blue: 0.93),
                    Color(red: 0.40, green: 0.32, blue: 0.68),
                    x: 0.74, y: 0.86, diameter: 1.15,
                    lightOpacity: 0.30, darkOpacity: 0.07
                ),
                spec(
                    Color(red: 0.84, green: 0.80, blue: 0.98),
                    Color(red: 0.34, green: 0.28, blue: 0.60),
                    x: 0.10, y: 0.86, diameter: 0.80,
                    lightOpacity: 0.18, darkOpacity: 0.07
                )
            ]
        case .colorful:
            return [
                spec(
                    Color(red: 1.00, green: 0.78, blue: 0.85),
                    Color(red: 0.78, green: 0.40, blue: 0.56),
                    x: 0.14, y: 0.12, diameter: 1.20,
                    lightOpacity: 0.34, darkOpacity: 0.13
                ),
                spec(
                    Color(red: 0.64, green: 0.95, blue: 0.89),
                    Color(red: 0.24, green: 0.62, blue: 0.55),
                    x: 0.86, y: 0.28, diameter: 1.10,
                    lightOpacity: 0.30, darkOpacity: 0.07
                ),
                spec(
                    Color(red: 0.60, green: 0.82, blue: 0.98),
                    Color(red: 0.22, green: 0.44, blue: 0.72),
                    x: 0.74, y: 0.86, diameter: 1.15,
                    lightOpacity: 0.30, darkOpacity: 0.07
                ),
                spec(
                    Color(red: 0.82, green: 0.74, blue: 0.98),
                    Color(red: 0.42, green: 0.32, blue: 0.72),
                    x: 0.10, y: 0.86, diameter: 0.80,
                    lightOpacity: 0.18, darkOpacity: 0.07
                )
            ]
        }
    }
}

// MARK: - Grain

/// A static, deterministic grain overlay.
///
/// Large soft gradients band on an OLED panel; a fine grain at very low
/// opacity breaks the bands up without reading as noise. The tile is rendered
/// once into a small image and repeated.
private struct AmbientGrain: View {
    private static let tile: UIImage = {
        let side: CGFloat = 160
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: side, height: side))
        return renderer.image { context in
            var seed: UInt64 = 0x9E37_79B9_7F4A_7C15
            func next() -> CGFloat {
                seed = seed &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
                return CGFloat((seed >> 11) & 0xFFFF) / 65_535.0
            }

            context.cgContext.setFillColor(UIColor.white.withAlphaComponent(0.06).cgColor)
            for _ in 0..<320 {
                let x = next() * side
                let y = next() * side
                let radius = 0.35 + next() * 0.6
                context.cgContext.fillEllipse(
                    in: CGRect(x: x, y: y, width: radius, height: radius)
                )
            }
        }
    }()

    var body: some View {
        Image(uiImage: Self.tile)
            .resizable(resizingMode: .tile)
            .allowsHitTesting(false)
    }
}

// MARK: - Surface fill

/// The fill a surface that used to be `palette.surface` paints now.
///
/// With an ambient style running, the fill is the palette surface at reduced
/// opacity: it keeps the text on it legible while letting the field's light
/// through. `solid` returns the exact surface the app shipped with.
struct AmbientSurfaceFill: View {
    @Environment(\.browserPalette) private var palette
    @Environment(\.browserBackgroundStyle) private var style

    var opacity: Double = 0.62

    var body: some View {
        if style.usesAmbient {
            palette.surface.opacity(opacity)
        } else {
            palette.surface
        }
    }
}

extension View {
    /// Paints a surface that respects the chosen background style.
    func browserSurfaceBackground(opacity: Double = 0.62) -> some View {
        background { AmbientSurfaceFill(opacity: opacity) }
    }

    /// Gives a presented sheet the app's background instead of the system's.
    ///
    /// The sheet's own content still has to leave its background clear for the
    /// field to show; `browserSurfaceBackground` / `browserListSurface` do that.
    func browserAmbientSheet() -> some View {
        presentationBackground { AmbientBackgroundView() }
    }
}
