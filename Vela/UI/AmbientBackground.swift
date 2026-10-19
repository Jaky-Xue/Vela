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
//  fine grain to keep the large gradients from banding. Surfaces above it are
//  translucent, which is what makes the colour read as light through glass
//  rather than as a saturated wall.
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
    /// Cool aurora: mint, sky and violet, kept pale.
    case aurora
    /// Warm morning light: peach, rose and a little cream.
    case dawn
    /// Night sky: deep blue with muted cyan and violet.
    case midnight

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .solid: return "纯净"
        case .aurora: return "极光"
        case .dawn: return "晨曦"
        case .midnight: return "星夜"
        }
    }

    public var summary: String {
        switch self {
        case .solid: return "纯白与纯黑，来自配色"
        case .aurora: return "冷色微光，通透安静"
        case .dawn: return "暖色晨雾，柔和明朗"
        case .midnight: return "深蓝夜色，冷光流动"
        }
    }

    public var symbolName: String {
        switch self {
        case .solid: return "circle.fill"
        case .aurora: return "sparkles"
        case .dawn: return "sun.horizon.fill"
        case .midnight: return "moon.stars.fill"
        }
    }

    /// Whether the style paints anything beyond the palette surface.
    public var usesAmbient: Bool { self != .solid }

    /// Resolves a stored raw value, falling back to the shipped default.
    public static func resolve(_ rawValue: String?) -> BrowserBackgroundStyle {
        guard let rawValue, let style = BrowserBackgroundStyle(rawValue: rawValue) else {
            return .aurora
        }
        return style
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
/// A `solid` style draws the palette surface alone; the other styles layer the
/// field above it.
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
                        meshField(in: size)
                    } else {
                        ForEach(specs.indices, id: \.self) { index in
                            blob(specs[index], in: size)
                        }
                    }

                    // A light frosted pane over the colour. It is the glass the
                    // light is seen through; kept thin so the mesh stays vivid.
                    Rectangle()
                        .fill(.ultraThinMaterial)
                        .opacity(colorScheme == .dark ? 0.08 : 0.06)
                        .allowsHitTesting(false)

                    specular(in: size)

                    AmbientGrain()
                        .opacity(colorScheme == .dark ? 0.35 : 0.28)
                        .blendMode(.overlay)
                        .allowsHitTesting(false)

                    // A soft top sheen and a bottom vignette: the two touches
                    // that make a field of colour read as lit from above.
                    LinearGradient(
                        stops: [
                            .init(color: .white.opacity(colorScheme == .dark ? 0.05 : 0.20), location: 0),
                            .init(color: .clear, location: 0.48)
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                    .blendMode(.plusLighter)
                    .allowsHitTesting(false)

                    RadialGradient(
                        colors: [.clear, .black.opacity(colorScheme == .dark ? 0.20 : 0.04)],
                        center: .center,
                        startRadius: max(size.width, size.height) * 0.34,
                        endRadius: max(size.width, size.height) * 0.84
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

    /// The Arc-style field: one mesh gradient carrying several saturated
    /// colours through each other. A mesh is far richer than a handful of
    /// radial blobs, and because it is a single static fill it costs nothing
    /// while a page scrolls.
    @available(iOS 18.0, *)
    private func meshField(in size: CGSize) -> some View {
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
        .saturation(colorScheme == .dark ? 1.15 : 1.05)
    }

    /// Nine saturated stops, light and dark. The dark stops are deep enough
    /// for the chrome's white ink but deliberately coloured, not black.
    private var meshColors: [Color] {
        let dark = colorScheme == .dark
        switch style {
        case .solid:
            let surface = palette.tokens(for: colorScheme).surface
            return Array(repeating: surface, count: 9)
        case .aurora:
            return dark
                ? [
                    Color(red: 0.024, green: 0.071, blue: 0.145),
                    Color(red: 0.043, green: 0.227, blue: 0.510),
                    Color(red: 0.039, green: 0.420, blue: 0.478),
                    Color(red: 0.141, green: 0.102, blue: 0.439),
                    Color(red: 0.145, green: 0.388, blue: 0.922),
                    Color(red: 0.024, green: 0.714, blue: 0.831),
                    Color(red: 0.357, green: 0.129, blue: 0.714),
                    Color(red: 0.745, green: 0.094, blue: 0.365),
                    Color(red: 0.067, green: 0.106, blue: 0.227)
                ]
                : [
                    Color(red: 0.918, green: 0.973, blue: 1.000),
                    Color(red: 0.655, green: 0.890, blue: 1.000),
                    Color(red: 0.780, green: 0.722, blue: 1.000),
                    Color(red: 0.788, green: 0.929, blue: 1.000),
                    Color(red: 0.490, green: 0.827, blue: 0.988),
                    Color(red: 0.655, green: 0.545, blue: 0.980),
                    Color(red: 0.984, green: 0.812, blue: 0.910),
                    Color(red: 0.941, green: 0.671, blue: 0.988),
                    Color(red: 0.910, green: 0.894, blue: 1.000)
                ]
        case .dawn:
            return dark
                ? [
                    Color(red: 0.165, green: 0.063, blue: 0.165),
                    Color(red: 0.420, green: 0.114, blue: 0.114),
                    Color(red: 0.725, green: 0.110, blue: 0.294),
                    Color(red: 0.290, green: 0.114, blue: 0.420),
                    Color(red: 0.918, green: 0.345, blue: 0.047),
                    Color(red: 0.859, green: 0.153, blue: 0.467),
                    Color(red: 0.486, green: 0.176, blue: 0.071),
                    Color(red: 0.851, green: 0.467, blue: 0.024),
                    Color(red: 0.231, green: 0.027, blue: 0.392)
                ]
                : [
                    Color(red: 1.000, green: 0.965, blue: 0.918),
                    Color(red: 1.000, green: 0.827, blue: 0.647),
                    Color(red: 1.000, green: 0.694, blue: 0.600),
                    Color(red: 1.000, green: 0.878, blue: 0.902),
                    Color(red: 0.992, green: 0.729, blue: 0.455),
                    Color(red: 0.957, green: 0.447, blue: 0.714),
                    Color(red: 0.992, green: 0.902, blue: 0.541),
                    Color(red: 0.976, green: 0.659, blue: 0.831),
                    Color(red: 0.914, green: 0.835, blue: 1.000)
                ]
        case .midnight:
            return dark
                ? [
                    Color(red: 0.008, green: 0.024, blue: 0.090),
                    Color(red: 0.039, green: 0.165, blue: 0.420),
                    Color(red: 0.055, green: 0.455, blue: 0.565),
                    Color(red: 0.118, green: 0.106, blue: 0.294),
                    Color(red: 0.145, green: 0.388, blue: 0.922),
                    Color(red: 0.031, green: 0.569, blue: 0.698),
                    Color(red: 0.298, green: 0.114, blue: 0.584),
                    Color(red: 0.745, green: 0.094, blue: 0.365),
                    Color(red: 0.043, green: 0.067, blue: 0.125)
                ]
                : [
                    Color(red: 0.937, green: 0.973, blue: 1.000),
                    Color(red: 0.749, green: 0.859, blue: 0.996),
                    Color(red: 0.647, green: 0.953, blue: 0.988),
                    Color(red: 0.878, green: 0.906, blue: 1.000),
                    Color(red: 0.576, green: 0.773, blue: 0.992),
                    Color(red: 0.404, green: 0.910, blue: 0.976),
                    Color(red: 0.867, green: 0.839, blue: 0.996),
                    Color(red: 0.984, green: 0.812, blue: 0.910),
                    Color(red: 0.973, green: 0.980, blue: 0.988)
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
                        colors: [.clear, .white.opacity(colorScheme == .dark ? 0.13 : 0.20), .clear],
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
                        colors: [.clear, .white.opacity(colorScheme == .dark ? 0.07 : 0.12), .clear],
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
                tokens.surface.opacity(colorScheme == .dark ? 0.10 : 0.14)
            }
        }
    }

    /// The base gradient stops for the active style and appearance.
    ///
    /// The dark stops are lifted neutrals rather than saturated inks. A near
    /// black base makes every colour blob read as a dark stain; a lifted
    /// charcoal lets the same colours read as translucent light.
    private var baseColors: [Color] {
        switch style {
        case .solid:
            let surface = palette.tokens(for: colorScheme).surface
            return [surface, surface, surface]
        case .aurora:
            return colorScheme == .dark
                ? [
                    Color(red: 0.082, green: 0.102, blue: 0.153),
                    Color(red: 0.067, green: 0.090, blue: 0.141),
                    Color(red: 0.086, green: 0.075, blue: 0.145)
                ]
                : [
                    Color(red: 0.969, green: 0.984, blue: 1.000),
                    Color(red: 0.933, green: 0.953, blue: 1.000),
                    Color(red: 0.976, green: 0.957, blue: 1.000)
                ]
        case .dawn:
            return colorScheme == .dark
                ? [
                    Color(red: 0.106, green: 0.086, blue: 0.075),
                    Color(red: 0.118, green: 0.094, blue: 0.082),
                    Color(red: 0.102, green: 0.075, blue: 0.098)
                ]
                : [
                    Color(red: 1.000, green: 0.980, blue: 0.957),
                    Color(red: 1.000, green: 0.945, blue: 0.925),
                    Color(red: 0.984, green: 0.961, blue: 0.988)
                ]
        case .midnight:
            return colorScheme == .dark
                ? [
                    Color(red: 0.063, green: 0.090, blue: 0.145),
                    Color(red: 0.055, green: 0.082, blue: 0.141),
                    Color(red: 0.078, green: 0.075, blue: 0.153)
                ]
                : [
                    Color(red: 0.957, green: 0.973, blue: 1.000),
                    Color(red: 0.929, green: 0.949, blue: 0.988),
                    Color(red: 0.973, green: 0.957, blue: 1.000)
                ]
        }
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

    /// Four light sources. Fewer, larger and fainter than a saturated field:
    /// the effect wanted here is light seen through glass, not a colour wash.
    private var specs: [AmbientBlobSpec] {
        switch style {
        case .solid:
            return []
        case .aurora:
            return [
                AmbientBlobSpec(
                    light: Color(red: 0.66, green: 0.93, blue: 0.85),
                    dark: Color(red: 0.20, green: 0.72, blue: 0.66),
                    x: 0.14, y: 0.12, diameter: 1.20, opacity: colorScheme == .dark ? 0.22 : 0.28
                ),
                AmbientBlobSpec(
                    light: Color(red: 0.72, green: 0.83, blue: 1.00),
                    dark: Color(red: 0.34, green: 0.46, blue: 0.90),
                    x: 0.86, y: 0.26, diameter: 1.10, opacity: colorScheme == .dark ? 0.22 : 0.26
                ),
                AmbientBlobSpec(
                    light: Color(red: 0.84, green: 0.73, blue: 1.00),
                    dark: Color(red: 0.55, green: 0.38, blue: 0.88),
                    x: 0.76, y: 0.86, diameter: 1.15, opacity: colorScheme == .dark ? 0.20 : 0.22
                ),
                AmbientBlobSpec(
                    light: Color(red: 1.00, green: 0.83, blue: 0.90),
                    dark: Color(red: 0.75, green: 0.36, blue: 0.58),
                    x: 0.10, y: 0.88, diameter: 0.80, opacity: colorScheme == .dark ? 0.12 : 0.15
                )
            ]
        case .dawn:
            return [
                AmbientBlobSpec(
                    light: Color(red: 1.00, green: 0.87, blue: 0.74),
                    dark: Color(red: 0.80, green: 0.62, blue: 0.42),
                    x: 0.14, y: 0.12, diameter: 1.20, opacity: colorScheme == .dark ? 0.16 : 0.30
                ),
                AmbientBlobSpec(
                    light: Color(red: 1.00, green: 0.82, blue: 0.84),
                    dark: Color(red: 0.80, green: 0.52, blue: 0.54),
                    x: 0.86, y: 0.28, diameter: 1.10, opacity: colorScheme == .dark ? 0.14 : 0.24
                ),
                AmbientBlobSpec(
                    light: Color(red: 1.00, green: 0.95, blue: 0.80),
                    dark: Color(red: 0.76, green: 0.66, blue: 0.44),
                    x: 0.74, y: 0.86, diameter: 1.15, opacity: colorScheme == .dark ? 0.11 : 0.22
                ),
                AmbientBlobSpec(
                    light: Color(red: 0.90, green: 0.84, blue: 1.00),
                    dark: Color(red: 0.58, green: 0.44, blue: 0.58),
                    x: 0.10, y: 0.86, diameter: 0.80, opacity: colorScheme == .dark ? 0.09 : 0.14
                )
            ]
        case .midnight:
            return [
                AmbientBlobSpec(
                    light: Color(red: 0.74, green: 0.82, blue: 1.00),
                    dark: Color(red: 0.26, green: 0.46, blue: 0.84),
                    x: 0.14, y: 0.14, diameter: 1.20, opacity: colorScheme == .dark ? 0.22 : 0.28
                ),
                AmbientBlobSpec(
                    light: Color(red: 0.72, green: 0.92, blue: 0.92),
                    dark: Color(red: 0.20, green: 0.66, blue: 0.72),
                    x: 0.86, y: 0.30, diameter: 1.05, opacity: colorScheme == .dark ? 0.20 : 0.24
                ),
                AmbientBlobSpec(
                    light: Color(red: 0.84, green: 0.77, blue: 1.00),
                    dark: Color(red: 0.50, green: 0.36, blue: 0.80),
                    x: 0.74, y: 0.86, diameter: 1.15, opacity: colorScheme == .dark ? 0.20 : 0.24
                ),
                AmbientBlobSpec(
                    light: Color(red: 1.00, green: 0.82, blue: 0.90),
                    dark: Color(red: 0.68, green: 0.30, blue: 0.52),
                    x: 0.10, y: 0.86, diameter: 0.80, opacity: colorScheme == .dark ? 0.10 : 0.14
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
