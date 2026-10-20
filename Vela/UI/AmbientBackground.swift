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
//  Seven fields, warm and cool, separated by hue rather than by saturation:
//  暖阳 (peach/orange), 晚霞 (coral/rose), 青柠 (yellow-green), 极光
//  (mint/teal), 冰川 (azure), 紫雾 (violet) and 缤纷 (rose, mint, sky and
//  violet together). The light bases are pale so text stays legible; each
//  mesh carries enough chroma for the choice to be obvious at a glance.
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
                        .opacity(colorScheme == .dark ? 0.30 : 0.24)
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
                        colors: [.clear, .black.opacity(colorScheme == .dark ? 0.16 : 0.03)],
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
        case .sunrise:
            return colorScheme == .dark
                ? [
                    Color(red: 0.137, green: 0.102, blue: 0.071),
                    Color(red: 0.169, green: 0.122, blue: 0.082),
                    Color(red: 0.141, green: 0.102, blue: 0.075)
                ]
                : [
                    Color(red: 1.000, green: 0.973, blue: 0.941),
                    Color(red: 1.000, green: 0.914, blue: 0.839),
                    Color(red: 1.000, green: 0.949, blue: 0.902)
                ]
        case .sunset:
            return colorScheme == .dark
                ? [
                    Color(red: 0.149, green: 0.086, blue: 0.098),
                    Color(red: 0.176, green: 0.102, blue: 0.118),
                    Color(red: 0.145, green: 0.082, blue: 0.098)
                ]
                : [
                    Color(red: 1.000, green: 0.969, blue: 0.980),
                    Color(red: 1.000, green: 0.894, blue: 0.933),
                    Color(red: 1.000, green: 0.941, blue: 0.965)
                ]
        case .lime:
            return colorScheme == .dark
                ? [
                    Color(red: 0.106, green: 0.122, blue: 0.071),
                    Color(red: 0.129, green: 0.149, blue: 0.082),
                    Color(red: 0.114, green: 0.133, blue: 0.075)
                ]
                : [
                    Color(red: 0.984, green: 0.992, blue: 0.949),
                    Color(red: 0.937, green: 0.969, blue: 0.863),
                    Color(red: 0.969, green: 0.984, blue: 0.914)
                ]
        case .aurora:
            return colorScheme == .dark
                ? [
                    Color(red: 0.071, green: 0.122, blue: 0.114),
                    Color(red: 0.086, green: 0.145, blue: 0.133),
                    Color(red: 0.075, green: 0.129, blue: 0.118)
                ]
                : [
                    Color(red: 0.949, green: 0.988, blue: 0.980),
                    Color(red: 0.867, green: 0.965, blue: 0.937),
                    Color(red: 0.933, green: 0.984, blue: 0.969)
                ]
        case .glacier:
            return colorScheme == .dark
                ? [
                    Color(red: 0.075, green: 0.098, blue: 0.145),
                    Color(red: 0.090, green: 0.118, blue: 0.169),
                    Color(red: 0.078, green: 0.102, blue: 0.149)
                ]
                : [
                    Color(red: 0.961, green: 0.980, blue: 1.000),
                    Color(red: 0.878, green: 0.933, blue: 0.984),
                    Color(red: 0.929, green: 0.965, blue: 1.000)
                ]
        case .violet:
            return colorScheme == .dark
                ? [
                    Color(red: 0.106, green: 0.086, blue: 0.145),
                    Color(red: 0.125, green: 0.102, blue: 0.169),
                    Color(red: 0.110, green: 0.090, blue: 0.149)
                ]
                : [
                    Color(red: 0.980, green: 0.969, blue: 1.000),
                    Color(red: 0.925, green: 0.890, blue: 0.984),
                    Color(red: 0.961, green: 0.941, blue: 1.000)
                ]
        case .colorful:
            return colorScheme == .dark
                ? [
                    Color(red: 0.129, green: 0.082, blue: 0.133),
                    Color(red: 0.067, green: 0.114, blue: 0.141),
                    Color(red: 0.110, green: 0.090, blue: 0.169)
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
        case .sunrise:
            return dark
                ? [
                    Color(red: 0.165, green: 0.114, blue: 0.078),
                    Color(red: 0.290, green: 0.180, blue: 0.110),
                    Color(red: 0.416, green: 0.259, blue: 0.141),
                    Color(red: 0.227, green: 0.153, blue: 0.098),
                    Color(red: 0.478, green: 0.298, blue: 0.173),
                    Color(red: 0.561, green: 0.353, blue: 0.204),
                    Color(red: 0.337, green: 0.208, blue: 0.122),
                    Color(red: 0.431, green: 0.271, blue: 0.157),
                    Color(red: 0.180, green: 0.125, blue: 0.086)
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
                    Color(red: 0.165, green: 0.090, blue: 0.106),
                    Color(red: 0.290, green: 0.137, blue: 0.161),
                    Color(red: 0.431, green: 0.196, blue: 0.224),
                    Color(red: 0.231, green: 0.118, blue: 0.141),
                    Color(red: 0.549, green: 0.259, blue: 0.286),
                    Color(red: 0.635, green: 0.318, blue: 0.353),
                    Color(red: 0.361, green: 0.169, blue: 0.192),
                    Color(red: 0.478, green: 0.227, blue: 0.259),
                    Color(red: 0.176, green: 0.102, blue: 0.118)
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
                    Color(red: 0.122, green: 0.141, blue: 0.082),
                    Color(red: 0.196, green: 0.227, blue: 0.125),
                    Color(red: 0.275, green: 0.318, blue: 0.173),
                    Color(red: 0.153, green: 0.176, blue: 0.098),
                    Color(red: 0.318, green: 0.380, blue: 0.204),
                    Color(red: 0.392, green: 0.463, blue: 0.247),
                    Color(red: 0.208, green: 0.243, blue: 0.133),
                    Color(red: 0.278, green: 0.322, blue: 0.173),
                    Color(red: 0.129, green: 0.149, blue: 0.086)
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
                    Color(red: 0.082, green: 0.141, blue: 0.133),
                    Color(red: 0.125, green: 0.243, blue: 0.224),
                    Color(red: 0.173, green: 0.345, blue: 0.318),
                    Color(red: 0.098, green: 0.180, blue: 0.165),
                    Color(red: 0.204, green: 0.412, blue: 0.376),
                    Color(red: 0.247, green: 0.502, blue: 0.459),
                    Color(red: 0.133, green: 0.259, blue: 0.239),
                    Color(red: 0.173, green: 0.345, blue: 0.318),
                    Color(red: 0.086, green: 0.153, blue: 0.141)
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
                    Color(red: 0.086, green: 0.110, blue: 0.157),
                    Color(red: 0.129, green: 0.180, blue: 0.263),
                    Color(red: 0.180, green: 0.243, blue: 0.345),
                    Color(red: 0.102, green: 0.141, blue: 0.200),
                    Color(red: 0.216, green: 0.302, blue: 0.431),
                    Color(red: 0.263, green: 0.365, blue: 0.510),
                    Color(red: 0.141, green: 0.188, blue: 0.271),
                    Color(red: 0.180, green: 0.243, blue: 0.345),
                    Color(red: 0.090, green: 0.118, blue: 0.169)
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
                    Color(red: 0.114, green: 0.094, blue: 0.157),
                    Color(red: 0.180, green: 0.145, blue: 0.263),
                    Color(red: 0.247, green: 0.196, blue: 0.345),
                    Color(red: 0.141, green: 0.114, blue: 0.200),
                    Color(red: 0.302, green: 0.239, blue: 0.431),
                    Color(red: 0.365, green: 0.294, blue: 0.510),
                    Color(red: 0.188, green: 0.153, blue: 0.271),
                    Color(red: 0.247, green: 0.196, blue: 0.345),
                    Color(red: 0.118, green: 0.098, blue: 0.169)
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
                    Color(red: 0.145, green: 0.086, blue: 0.129),
                    Color(red: 0.290, green: 0.122, blue: 0.208),
                    Color(red: 0.325, green: 0.180, blue: 0.110),
                    Color(red: 0.086, green: 0.220, blue: 0.200),
                    Color(red: 0.110, green: 0.220, blue: 0.365),
                    Color(red: 0.180, green: 0.165, blue: 0.400),
                    Color(red: 0.267, green: 0.161, blue: 0.365),
                    Color(red: 0.365, green: 0.165, blue: 0.290),
                    Color(red: 0.098, green: 0.110, blue: 0.180)
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
        case .sunrise:
            return [
                spec(
                    Color(red: 1.00, green: 0.87, blue: 0.74),
                    Color(red: 0.82, green: 0.60, blue: 0.38),
                    x: 0.14, y: 0.12, diameter: 1.20,
                    lightOpacity: 0.34, darkOpacity: 0.22
                ),
                spec(
                    Color(red: 1.00, green: 0.93, blue: 0.78),
                    Color(red: 0.72, green: 0.56, blue: 0.30),
                    x: 0.86, y: 0.26, diameter: 1.10,
                    lightOpacity: 0.30, darkOpacity: 0.20
                ),
                spec(
                    Color(red: 1.00, green: 0.80, blue: 0.66),
                    Color(red: 0.76, green: 0.48, blue: 0.27),
                    x: 0.76, y: 0.86, diameter: 1.15,
                    lightOpacity: 0.30, darkOpacity: 0.20
                ),
                spec(
                    Color(red: 1.00, green: 0.90, blue: 0.84),
                    Color(red: 0.58, green: 0.40, blue: 0.26),
                    x: 0.10, y: 0.86, diameter: 0.80,
                    lightOpacity: 0.18, darkOpacity: 0.12
                )
            ]
        case .sunset:
            return [
                spec(
                    Color(red: 1.00, green: 0.78, blue: 0.82),
                    Color(red: 0.86, green: 0.46, blue: 0.58),
                    x: 0.14, y: 0.12, diameter: 1.20,
                    lightOpacity: 0.34, darkOpacity: 0.22
                ),
                spec(
                    Color(red: 1.00, green: 0.70, blue: 0.80),
                    Color(red: 0.74, green: 0.36, blue: 0.50),
                    x: 0.86, y: 0.28, diameter: 1.10,
                    lightOpacity: 0.30, darkOpacity: 0.20
                ),
                spec(
                    Color(red: 0.96, green: 0.76, blue: 0.90),
                    Color(red: 0.60, green: 0.32, blue: 0.48),
                    x: 0.74, y: 0.86, diameter: 1.15,
                    lightOpacity: 0.28, darkOpacity: 0.18
                ),
                spec(
                    Color(red: 1.00, green: 0.86, blue: 0.84),
                    Color(red: 0.52, green: 0.30, blue: 0.38),
                    x: 0.10, y: 0.86, diameter: 0.80,
                    lightOpacity: 0.18, darkOpacity: 0.12
                )
            ]
        case .lime:
            return [
                spec(
                    Color(red: 0.90, green: 0.96, blue: 0.72),
                    Color(red: 0.60, green: 0.72, blue: 0.34),
                    x: 0.14, y: 0.13, diameter: 1.20,
                    lightOpacity: 0.34, darkOpacity: 0.22
                ),
                spec(
                    Color(red: 0.82, green: 0.93, blue: 0.62),
                    Color(red: 0.52, green: 0.64, blue: 0.28),
                    x: 0.86, y: 0.28, diameter: 1.10,
                    lightOpacity: 0.30, darkOpacity: 0.20
                ),
                spec(
                    Color(red: 0.74, green: 0.88, blue: 0.52),
                    Color(red: 0.46, green: 0.58, blue: 0.24),
                    x: 0.75, y: 0.86, diameter: 1.15,
                    lightOpacity: 0.30, darkOpacity: 0.20
                ),
                spec(
                    Color(red: 0.88, green: 0.95, blue: 0.74),
                    Color(red: 0.40, green: 0.50, blue: 0.22),
                    x: 0.10, y: 0.86, diameter: 0.80,
                    lightOpacity: 0.18, darkOpacity: 0.12
                )
            ]
        case .aurora:
            return [
                spec(
                    Color(red: 0.76, green: 0.95, blue: 0.90),
                    Color(red: 0.34, green: 0.72, blue: 0.66),
                    x: 0.14, y: 0.12, diameter: 1.20,
                    lightOpacity: 0.34, darkOpacity: 0.22
                ),
                spec(
                    Color(red: 0.64, green: 0.90, blue: 0.84),
                    Color(red: 0.28, green: 0.64, blue: 0.58),
                    x: 0.86, y: 0.28, diameter: 1.10,
                    lightOpacity: 0.30, darkOpacity: 0.20
                ),
                spec(
                    Color(red: 0.52, green: 0.84, blue: 0.78),
                    Color(red: 0.24, green: 0.56, blue: 0.52),
                    x: 0.74, y: 0.86, diameter: 1.15,
                    lightOpacity: 0.30, darkOpacity: 0.20
                ),
                spec(
                    Color(red: 0.78, green: 0.95, blue: 0.91),
                    Color(red: 0.22, green: 0.48, blue: 0.44),
                    x: 0.10, y: 0.86, diameter: 0.80,
                    lightOpacity: 0.18, darkOpacity: 0.12
                )
            ]
        case .glacier:
            return [
                spec(
                    Color(red: 0.78, green: 0.90, blue: 0.98),
                    Color(red: 0.34, green: 0.58, blue: 0.82),
                    x: 0.14, y: 0.12, diameter: 1.20,
                    lightOpacity: 0.34, darkOpacity: 0.22
                ),
                spec(
                    Color(red: 0.64, green: 0.82, blue: 0.96),
                    Color(red: 0.28, green: 0.50, blue: 0.74),
                    x: 0.86, y: 0.28, diameter: 1.10,
                    lightOpacity: 0.30, darkOpacity: 0.20
                ),
                spec(
                    Color(red: 0.52, green: 0.74, blue: 0.93),
                    Color(red: 0.24, green: 0.44, blue: 0.68),
                    x: 0.74, y: 0.86, diameter: 1.15,
                    lightOpacity: 0.30, darkOpacity: 0.20
                ),
                spec(
                    Color(red: 0.76, green: 0.90, blue: 0.99),
                    Color(red: 0.20, green: 0.38, blue: 0.60),
                    x: 0.10, y: 0.86, diameter: 0.80,
                    lightOpacity: 0.18, darkOpacity: 0.12
                )
            ]
        case .violet:
            return [
                spec(
                    Color(red: 0.86, green: 0.82, blue: 0.98),
                    Color(red: 0.52, green: 0.42, blue: 0.82),
                    x: 0.14, y: 0.12, diameter: 1.20,
                    lightOpacity: 0.34, darkOpacity: 0.22
                ),
                spec(
                    Color(red: 0.78, green: 0.72, blue: 0.96),
                    Color(red: 0.46, green: 0.36, blue: 0.74),
                    x: 0.86, y: 0.28, diameter: 1.10,
                    lightOpacity: 0.30, darkOpacity: 0.20
                ),
                spec(
                    Color(red: 0.70, green: 0.62, blue: 0.93),
                    Color(red: 0.40, green: 0.32, blue: 0.68),
                    x: 0.74, y: 0.86, diameter: 1.15,
                    lightOpacity: 0.30, darkOpacity: 0.20
                ),
                spec(
                    Color(red: 0.84, green: 0.80, blue: 0.98),
                    Color(red: 0.34, green: 0.28, blue: 0.60),
                    x: 0.10, y: 0.86, diameter: 0.80,
                    lightOpacity: 0.18, darkOpacity: 0.12
                )
            ]
        case .colorful:
            return [
                spec(
                    Color(red: 1.00, green: 0.78, blue: 0.85),
                    Color(red: 0.78, green: 0.40, blue: 0.56),
                    x: 0.14, y: 0.12, diameter: 1.20,
                    lightOpacity: 0.34, darkOpacity: 0.22
                ),
                spec(
                    Color(red: 0.64, green: 0.95, blue: 0.89),
                    Color(red: 0.24, green: 0.62, blue: 0.55),
                    x: 0.86, y: 0.28, diameter: 1.10,
                    lightOpacity: 0.30, darkOpacity: 0.20
                ),
                spec(
                    Color(red: 0.60, green: 0.82, blue: 0.98),
                    Color(red: 0.22, green: 0.44, blue: 0.72),
                    x: 0.74, y: 0.86, diameter: 1.15,
                    lightOpacity: 0.30, darkOpacity: 0.20
                ),
                spec(
                    Color(red: 0.82, green: 0.74, blue: 0.98),
                    Color(red: 0.42, green: 0.32, blue: 0.72),
                    x: 0.10, y: 0.86, diameter: 0.80,
                    lightOpacity: 0.18, darkOpacity: 0.12
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
