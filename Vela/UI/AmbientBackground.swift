//
//  AmbientBackground.swift
//  Vela
//
//  The app-wide background: a palette surface, or a soft field of colour
//  behind it.
//
//  The field is deliberately static. An earlier version drifted the light
//  sources with a repeating animation; every frame re-evaluated five enormous
//  blurred layers, and the cost showed up as dropped frames while a page
//  scrolled. The light here is fixed, with the palette surface mixed in and a
//  fine grain to keep the large gradients from banding.
//
//  The three fields are cool and clearly separated by hue: 极光 is mint and
//  teal, 冰川 is ice-blue and silver, 紫雾 is lavender and periwinkle. No warm
//  tones are used. Colours are pale on purpose; the frosted pane over them is
//  thin so the result reads as light seen through glass, not as paint.
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
    /// Mint, teal and sky: the cool green-blue field.
    case aurora
    /// Ice blue, silver and pale aqua: the clean, almost white field.
    case glacier
    /// Lavender, lilac and periwinkle: the soft violet field.
    case violet

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .solid: return "纯净"
        case .aurora: return "极光"
        case .glacier: return "冰川"
        case .violet: return "紫雾"
        }
    }

    public var summary: String {
        switch self {
        case .solid: return "纯白与纯黑，来自配色"
        case .aurora: return "薄荷与青蓝，通透清冷"
        case .glacier: return "冰蓝与银白，干净明亮"
        case .violet: return "薰衣草与雾紫，柔和清冷"
        }
    }

    public var symbolName: String {
        switch self {
        case .solid: return "circle.fill"
        case .aurora: return "sparkles"
        case .glacier: return "snowflake"
        case .violet: return "cloud.fill"
        }
    }

    /// Whether the style paints anything beyond the palette surface.
    public var usesAmbient: Bool { self != .solid }

    /// Resolves a stored raw value, falling back to the shipped default.
    ///
    /// `dawn` and `midnight` are the raw values of the two styles this build
    /// replaced; they map to their cool successors rather than resetting the
    /// user's choice.
    public static func resolve(_ rawValue: String?) -> BrowserBackgroundStyle {
        guard let rawValue else { return .aurora }
        if let style = BrowserBackgroundStyle(rawValue: rawValue) {
            return style
        }
        switch rawValue {
        case "dawn": return .glacier
        case "midnight": return .violet
        default: return .aurora
        }
    }
}

// MARK: - Environment

private struct BrowserBackgroundStyleKey: EnvironmentKey {
    static let defaultValue: BrowserBackgroundStyle = .aurora
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
                            .init(color: .white.opacity(colorScheme == .dark ? 0.05 : 0.18), location: 0),
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

    /// The style's own base, with the palette surface mixed back in lightly so
    /// a chosen 配色 still influences the scene.
    private var base: some View {
        let tokens = palette.tokens(for: colorScheme)
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
                tokens.surface.opacity(colorScheme == .dark ? 0.10 : 0.16)
            }
        }
    }

    /// The base gradient stops for the active style and appearance.
    private var baseColors: [Color] {
        switch style {
        case .solid:
            let surface = palette.tokens(for: colorScheme).surface
            return [surface, surface, surface]
        case .aurora:
            return colorScheme == .dark
                ? [
                    Color(red: 0.122, green: 0.169, blue: 0.200),
                    Color(red: 0.133, green: 0.227, blue: 0.259),
                    Color(red: 0.114, green: 0.180, blue: 0.212)
                ]
                : [
                    Color(red: 0.961, green: 0.992, blue: 0.988),
                    Color(red: 0.929, green: 0.973, blue: 0.988),
                    Color(red: 0.949, green: 0.988, blue: 0.980)
                ]
        case .glacier:
            return colorScheme == .dark
                ? [
                    Color(red: 0.165, green: 0.208, blue: 0.259),
                    Color(red: 0.200, green: 0.278, blue: 0.353),
                    Color(red: 0.169, green: 0.224, blue: 0.282)
                ]
                : [
                    Color(red: 0.980, green: 0.992, blue: 1.000),
                    Color(red: 0.933, green: 0.969, blue: 0.996),
                    Color(red: 0.957, green: 0.980, blue: 1.000)
                ]
        case .violet:
            return colorScheme == .dark
                ? [
                    Color(red: 0.180, green: 0.161, blue: 0.239),
                    Color(red: 0.231, green: 0.200, blue: 0.314),
                    Color(red: 0.169, green: 0.149, blue: 0.224)
                ]
                : [
                    Color(red: 0.980, green: 0.969, blue: 1.000),
                    Color(red: 0.949, green: 0.925, blue: 1.000),
                    Color(red: 0.969, green: 0.949, blue: 1.000)
                ]
        }
    }

    /// The Arc-style field: one mesh gradient carrying several pale, cool
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

    /// Nine cool stops per style. No orange, gold, peach or red appears here;
    /// the three fields are separated by hue family rather than by intensity.
    private var meshColors: [Color] {
        let dark = colorScheme == .dark
        switch style {
        case .solid:
            let surface = palette.tokens(for: colorScheme).surface
            return Array(repeating: surface, count: 9)
        case .aurora:
            return dark
                ? [
                    Color(red: 0.133, green: 0.200, blue: 0.227),
                    Color(red: 0.184, green: 0.373, blue: 0.388),
                    Color(red: 0.169, green: 0.435, blue: 0.471),
                    Color(red: 0.157, green: 0.290, blue: 0.325),
                    Color(red: 0.306, green: 0.600, blue: 0.584),
                    Color(red: 0.302, green: 0.620, blue: 0.682),
                    Color(red: 0.200, green: 0.424, blue: 0.471),
                    Color(red: 0.353, green: 0.655, blue: 0.627),
                    Color(red: 0.145, green: 0.208, blue: 0.239)
                ]
                : [
                    Color(red: 0.929, green: 0.988, blue: 0.973),
                    Color(red: 0.812, green: 0.957, blue: 0.914),
                    Color(red: 0.749, green: 0.918, blue: 0.957),
                    Color(red: 0.867, green: 0.973, blue: 0.945),
                    Color(red: 0.655, green: 0.886, blue: 0.847),
                    Color(red: 0.624, green: 0.847, blue: 0.933),
                    Color(red: 0.776, green: 0.941, blue: 0.957),
                    Color(red: 0.714, green: 0.894, blue: 0.945),
                    Color(red: 0.910, green: 0.984, blue: 0.969)
                ]
        case .glacier:
            return dark
                ? [
                    Color(red: 0.169, green: 0.227, blue: 0.290),
                    Color(red: 0.239, green: 0.353, blue: 0.439),
                    Color(red: 0.294, green: 0.447, blue: 0.522),
                    Color(red: 0.208, green: 0.314, blue: 0.416),
                    Color(red: 0.420, green: 0.576, blue: 0.667),
                    Color(red: 0.478, green: 0.659, blue: 0.722),
                    Color(red: 0.290, green: 0.416, blue: 0.502),
                    Color(red: 0.435, green: 0.604, blue: 0.690),
                    Color(red: 0.180, green: 0.239, blue: 0.298)
                ]
                : [
                    Color(red: 0.984, green: 0.992, blue: 1.000),
                    Color(red: 0.902, green: 0.957, blue: 1.000),
                    Color(red: 0.843, green: 0.933, blue: 0.984),
                    Color(red: 0.937, green: 0.976, blue: 1.000),
                    Color(red: 0.796, green: 0.902, blue: 0.969),
                    Color(red: 0.741, green: 0.875, blue: 0.945),
                    Color(red: 0.886, green: 0.949, blue: 0.988),
                    Color(red: 0.820, green: 0.922, blue: 0.976),
                    Color(red: 0.961, green: 0.988, blue: 1.000)
                ]
        case .violet:
            return dark
                ? [
                    Color(red: 0.200, green: 0.173, blue: 0.271),
                    Color(red: 0.290, green: 0.247, blue: 0.420),
                    Color(red: 0.353, green: 0.298, blue: 0.486),
                    Color(red: 0.251, green: 0.212, blue: 0.353),
                    Color(red: 0.478, green: 0.408, blue: 0.659),
                    Color(red: 0.541, green: 0.471, blue: 0.722),
                    Color(red: 0.345, green: 0.290, blue: 0.471),
                    Color(red: 0.498, green: 0.435, blue: 0.659),
                    Color(red: 0.208, green: 0.176, blue: 0.286)
                ]
                : [
                    Color(red: 0.973, green: 0.957, blue: 1.000),
                    Color(red: 0.914, green: 0.882, blue: 1.000),
                    Color(red: 0.859, green: 0.835, blue: 1.000),
                    Color(red: 0.945, green: 0.922, blue: 1.000),
                    Color(red: 0.812, green: 0.773, blue: 0.980),
                    Color(red: 0.780, green: 0.757, blue: 0.957),
                    Color(red: 0.906, green: 0.871, blue: 1.000),
                    Color(red: 0.851, green: 0.820, blue: 0.984),
                    Color(red: 0.961, green: 0.945, blue: 1.000)
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
    /// mesh families: mint/teal, ice/silver, lavender/periwinkle.
    private var specs: [AmbientBlobSpec] {
        switch style {
        case .solid:
            return []
        case .aurora:
            return [
                AmbientBlobSpec(
                    light: Color(red: 0.65, green: 0.93, blue: 0.85),
                    dark: Color(red: 0.25, green: 0.75, blue: 0.70),
                    x: 0.14, y: 0.12, diameter: 1.20,
                    opacity: colorScheme == .dark ? 0.22 : 0.34
                ),
                AmbientBlobSpec(
                    light: Color(red: 0.68, green: 0.84, blue: 0.98),
                    dark: Color(red: 0.32, green: 0.55, blue: 0.85),
                    x: 0.86, y: 0.26, diameter: 1.10,
                    opacity: colorScheme == .dark ? 0.22 : 0.32
                ),
                AmbientBlobSpec(
                    light: Color(red: 0.72, green: 0.93, blue: 0.96),
                    dark: Color(red: 0.25, green: 0.75, blue: 0.82),
                    x: 0.76, y: 0.86, diameter: 1.15,
                    opacity: colorScheme == .dark ? 0.20 : 0.30
                ),
                AmbientBlobSpec(
                    light: Color(red: 0.76, green: 0.80, blue: 1.00),
                    dark: Color(red: 0.35, green: 0.45, blue: 0.65),
                    x: 0.10, y: 0.86, diameter: 0.80,
                    opacity: colorScheme == .dark ? 0.12 : 0.20
                )
            ]
        case .glacier:
            return [
                AmbientBlobSpec(
                    light: Color(red: 0.85, green: 0.95, blue: 1.00),
                    dark: Color(red: 0.40, green: 0.60, blue: 0.74),
                    x: 0.14, y: 0.12, diameter: 1.20,
                    opacity: colorScheme == .dark ? 0.22 : 0.36
                ),
                AmbientBlobSpec(
                    light: Color(red: 0.78, green: 0.88, blue: 0.98),
                    dark: Color(red: 0.50, green: 0.72, blue: 0.85),
                    x: 0.86, y: 0.28, diameter: 1.10,
                    opacity: colorScheme == .dark ? 0.20 : 0.30
                ),
                AmbientBlobSpec(
                    light: Color(red: 0.80, green: 0.96, blue: 1.00),
                    dark: Color(red: 0.34, green: 0.48, blue: 0.62),
                    x: 0.74, y: 0.86, diameter: 1.15,
                    opacity: colorScheme == .dark ? 0.18 : 0.28
                ),
                AmbientBlobSpec(
                    light: Color(red: 0.90, green: 0.97, blue: 1.00),
                    dark: Color(red: 0.58, green: 0.78, blue: 0.88),
                    x: 0.10, y: 0.86, diameter: 0.80,
                    opacity: colorScheme == .dark ? 0.14 : 0.22
                )
            ]
        case .violet:
            return [
                AmbientBlobSpec(
                    light: Color(red: 0.82, green: 0.75, blue: 1.00),
                    dark: Color(red: 0.48, green: 0.38, blue: 0.78),
                    x: 0.14, y: 0.14, diameter: 1.20,
                    opacity: colorScheme == .dark ? 0.22 : 0.34
                ),
                AmbientBlobSpec(
                    light: Color(red: 0.88, green: 0.82, blue: 1.00),
                    dark: Color(red: 0.35, green: 0.30, blue: 0.60),
                    x: 0.86, y: 0.30, diameter: 1.05,
                    opacity: colorScheme == .dark ? 0.20 : 0.30
                ),
                AmbientBlobSpec(
                    light: Color(red: 0.72, green: 0.72, blue: 0.98),
                    dark: Color(red: 0.60, green: 0.50, blue: 0.82),
                    x: 0.74, y: 0.86, diameter: 1.15,
                    opacity: colorScheme == .dark ? 0.20 : 0.30
                ),
                AmbientBlobSpec(
                    light: Color(red: 0.78, green: 0.80, blue: 1.00),
                    dark: Color(red: 0.45, green: 0.40, blue: 0.68),
                    x: 0.10, y: 0.86, diameter: 0.80,
                    opacity: colorScheme == .dark ? 0.12 : 0.18
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
