//
//  AmbientBackground.swift
//  Vela
//
//  The app-wide background: a palette surface, or a luminous field of colour
//  behind it.
//
//  The old surface was a literal white or black rectangle, which is correct for
//  a document but reads as an empty application wherever the page is not the
//  subject — the home screen, settings, the shelves, the search page. The
//  ambient styles put a slow field of light under those surfaces, so the glass
//  the chrome already draws has something to refract and the app reads as one
//  designed place rather than a page with controls bolted to it.
//
//  The field is built from four things: a style-tinted base gradient, a blurred
//  colour ribbon that gives the light a direction, a handful of radial blobs
//  that are already soft at their rims, and a fine grain that keeps the large
//  gradients from banding. On a dark surface the blobs are drawn with
//  `plusLighter`, which is what turns them into light rather than paint.
//  `Reduce Motion` freezes the drift.
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
    /// Cool aurora: mint, sky and violet drifting over the surface.
    case aurora
    /// Warm morning light: peach, rose and a little gold.
    case dawn
    /// Night sky: deep blue with cyan and violet light.
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
        case .aurora: return "冷色流光，通透安静"
        case .dawn: return "暖色晨光，柔和明朗"
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
    ///
    /// The shipped default is 极光 rather than 纯净: the ambient field is the
    /// reason the setting exists, and an upgrade that left every existing
    /// install on a flat white surface would look like nothing changed.
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

/// One drifting light source.
private struct AmbientBlobSpec {
    var light: Color
    var dark: Color
    /// Centre as a fraction of the container.
    var x: CGFloat
    var y: CGFloat
    /// Diameter as a fraction of the container's longer edge.
    var diameter: CGFloat
    var opacity: Double
    /// How far the blob drifts, in points, at the far end of its animation.
    var drift: CGSize
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
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.browserBackgroundStyle) private var style

    @State private var driftPhase: CGFloat = 0

    var body: some View {
        GeometryReader { geo in
            let size = geo.size
            ZStack {
                base

                if style.usesAmbient, size.width > 1, size.height > 1 {
                    ribbon(in: size)

                    ForEach(specs.indices, id: \.self) { index in
                        blob(specs[index], index: index, in: size)
                    }

                    AmbientGrain()
                        .opacity(colorScheme == .dark ? 0.55 : 0.38)
                        .blendMode(.overlay)
                        .allowsHitTesting(false)

                    // A soft top sheen and a bottom vignette: the two touches
                    // that make a field of colour read as lit from above
                    // rather than as a printed gradient.
                    LinearGradient(
                        stops: [
                            .init(color: .white.opacity(colorScheme == .dark ? 0.07 : 0.30), location: 0),
                            .init(color: .clear, location: 0.46)
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                    .blendMode(.plusLighter)
                    .allowsHitTesting(false)

                    RadialGradient(
                        colors: [.clear, .black.opacity(colorScheme == .dark ? 0.34 : 0.06)],
                        center: .center,
                        startRadius: max(size.width, size.height) * 0.30,
                        endRadius: max(size.width, size.height) * 0.82
                    )
                    .allowsHitTesting(false)
                }
            }
            .frame(width: size.width, height: size.height)
            .clipped()
        }
        .ignoresSafeArea()
        .task { startDrifting() }
        .onChange(of: style) { _, _ in
            driftPhase = 0
            startDrifting()
        }
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
                tokens.surface.opacity(colorScheme == .dark ? 0.12 : 0.18)
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
                    Color(red: 0.016, green: 0.027, blue: 0.059),
                    Color(red: 0.031, green: 0.063, blue: 0.125),
                    Color(red: 0.055, green: 0.035, blue: 0.110)
                ]
                : [
                    Color(red: 0.961, green: 0.984, blue: 1.000),
                    Color(red: 0.933, green: 0.949, blue: 1.000),
                    Color(red: 0.976, green: 0.941, blue: 0.996)
                ]
        case .dawn:
            return colorScheme == .dark
                ? [
                    Color(red: 0.078, green: 0.039, blue: 0.043),
                    Color(red: 0.110, green: 0.055, blue: 0.066),
                    Color(red: 0.086, green: 0.039, blue: 0.078)
                ]
                : [
                    Color(red: 1.000, green: 0.973, blue: 0.941),
                    Color(red: 1.000, green: 0.941, blue: 0.953),
                    Color(red: 0.984, green: 0.949, blue: 1.000)
                ]
        case .midnight:
            return colorScheme == .dark
                ? [
                    Color(red: 0.008, green: 0.020, blue: 0.047),
                    Color(red: 0.020, green: 0.039, blue: 0.090),
                    Color(red: 0.031, green: 0.027, blue: 0.070)
                ]
                : [
                    Color(red: 0.949, green: 0.969, blue: 1.000),
                    Color(red: 0.925, green: 0.945, blue: 1.000),
                    Color(red: 0.969, green: 0.945, blue: 1.000)
                ]
        }
    }

    /// A broad, soft band of colour under the blobs. It gives the field a
    /// direction — the light comes from one side — which is what separates a
    /// designed backdrop from a set of unrelated glows.
    @ViewBuilder
    private func ribbon(in size: CGSize) -> some View {
        let width = max(size.width, size.height) * 1.7
        let height = width * 0.20
        let dx = (driftPhase * 2 - 1) * 26
        let dy = (driftPhase * 2 - 1) * 14

        Capsule()
            .fill(
                LinearGradient(
                    stops: ribbonStops,
                    startPoint: .leading,
                    endPoint: .trailing
                )
            )
            .frame(width: width, height: height)
            .blur(radius: height * 0.62)
            .rotationEffect(.degrees(ribbonAngle))
            .position(x: size.width * 0.50 + dx, y: size.height * 0.40 + dy)
            .opacity(colorScheme == .dark ? 0.48 : 0.32)
            .blendMode(colorScheme == .dark ? .plusLighter : .normal)
            .allowsHitTesting(false)
    }

    private var ribbonAngle: Double {
        switch style {
        case .solid: return 0
        case .aurora: return -24
        case .dawn: return -12
        case .midnight: return 22
        }
    }

    private var ribbonStops: [Gradient.Stop] {
        let colors: [Color]
        switch style {
        case .solid:
            colors = []
        case .aurora:
            colors = colorScheme == .dark
                ? [
                    Color(red: 0.10, green: 0.82, blue: 0.78),
                    Color(red: 0.24, green: 0.34, blue: 0.98),
                    Color(red: 0.62, green: 0.24, blue: 0.96)
                ]
                : [
                    Color(red: 0.62, green: 0.93, blue: 0.87),
                    Color(red: 0.66, green: 0.78, blue: 1.00),
                    Color(red: 0.85, green: 0.72, blue: 1.00)
                ]
        case .dawn:
            colors = colorScheme == .dark
                ? [
                    Color(red: 0.92, green: 0.44, blue: 0.18),
                    Color(red: 0.82, green: 0.20, blue: 0.38),
                    Color(red: 0.58, green: 0.20, blue: 0.62)
                ]
                : [
                    Color(red: 1.00, green: 0.83, blue: 0.64),
                    Color(red: 1.00, green: 0.72, blue: 0.78),
                    Color(red: 0.90, green: 0.76, blue: 1.00)
                ]
        case .midnight:
            colors = colorScheme == .dark
                ? [
                    Color(red: 0.16, green: 0.42, blue: 1.00),
                    Color(red: 0.10, green: 0.82, blue: 0.92),
                    Color(red: 0.54, green: 0.22, blue: 0.98)
                ]
                : [
                    Color(red: 0.74, green: 0.84, blue: 1.00),
                    Color(red: 0.70, green: 0.95, blue: 1.00),
                    Color(red: 0.86, green: 0.76, blue: 1.00)
                ]
        }
        guard colors.count == 3 else { return [] }
        return [
            .init(color: colors[0].opacity(0), location: 0),
            .init(color: colors[0].opacity(0.85), location: 0.18),
            .init(color: colors[1].opacity(0.95), location: 0.5),
            .init(color: colors[2].opacity(0.80), location: 0.82),
            .init(color: colors[2].opacity(0), location: 1)
        ]
    }

    private func blob(_ spec: AmbientBlobSpec, index: Int, in size: CGSize) -> some View {
        let longEdge = max(size.width, size.height)
        let diameter = longEdge * spec.diameter
        let color = colorScheme == .dark ? spec.dark : spec.light
        // Every other blob drifts in the opposite direction, so the field
        // breathes instead of sliding as one sheet.
        let sign: CGFloat = index.isMultiple(of: 2) ? 1 : -1
        let dx = spec.drift.width * (driftPhase * 2 - 1) * sign
        let dy = spec.drift.height * (driftPhase * 2 - 1) * sign

        return Circle()
            .fill(
                RadialGradient(
                    colors: [
                        color.opacity(spec.opacity),
                        color.opacity(spec.opacity * 0.42),
                        color.opacity(0)
                    ],
                    center: .center,
                    startRadius: 0,
                    endRadius: diameter * 0.5
                )
            )
            .frame(width: diameter, height: diameter)
            .blur(radius: diameter * 0.12)
            .blendMode(colorScheme == .dark ? .plusLighter : .normal)
            .position(
                x: size.width * spec.x + dx,
                y: size.height * spec.y + dy
            )
            .allowsHitTesting(false)
    }

    private func startDrifting() {
        guard style.usesAmbient, !reduceMotion else { return }
        withAnimation(.easeInOut(duration: 20).repeatForever(autoreverses: true)) {
            driftPhase = 1
        }
    }

    /// The light sources for each style. The first blob is also the base
    /// tint, so a style with no blobs is exactly the solid surface.
    private var specs: [AmbientBlobSpec] {
        switch style {
        case .solid:
            return []
        case .aurora:
            return [
                AmbientBlobSpec(
                    light: Color(red: 0.38, green: 0.90, blue: 0.78),
                    dark: Color(red: 0.08, green: 0.84, blue: 0.78),
                    x: 0.12, y: 0.10, diameter: 1.15, opacity: 0.50,
                    drift: CGSize(width: 34, height: 24)
                ),
                AmbientBlobSpec(
                    light: Color(red: 0.46, green: 0.70, blue: 1.00),
                    dark: Color(red: 0.18, green: 0.42, blue: 1.00),
                    x: 0.88, y: 0.22, diameter: 1.00, opacity: 0.46,
                    drift: CGSize(width: 26, height: 32)
                ),
                AmbientBlobSpec(
                    light: Color(red: 0.72, green: 0.55, blue: 1.00),
                    dark: Color(red: 0.60, green: 0.20, blue: 1.00),
                    x: 0.78, y: 0.82, diameter: 1.15, opacity: 0.42,
                    drift: CGSize(width: 36, height: 26)
                ),
                AmbientBlobSpec(
                    light: Color(red: 1.00, green: 0.62, blue: 0.82),
                    dark: Color(red: 0.95, green: 0.15, blue: 0.66),
                    x: 0.08, y: 0.88, diameter: 0.80, opacity: 0.30,
                    drift: CGSize(width: 22, height: 28)
                ),
                AmbientBlobSpec(
                    light: Color(red: 0.66, green: 0.94, blue: 1.00),
                    dark: Color(red: 0.16, green: 0.92, blue: 0.96),
                    x: 0.50, y: 0.52, diameter: 0.90, opacity: 0.22,
                    drift: CGSize(width: 18, height: 18)
                )
            ]
        case .dawn:
            return [
                AmbientBlobSpec(
                    light: Color(red: 1.00, green: 0.78, blue: 0.58),
                    dark: Color(red: 0.98, green: 0.54, blue: 0.20),
                    x: 0.14, y: 0.12, diameter: 1.10, opacity: 0.48,
                    drift: CGSize(width: 28, height: 22)
                ),
                AmbientBlobSpec(
                    light: Color(red: 1.00, green: 0.66, blue: 0.72),
                    dark: Color(red: 0.90, green: 0.24, blue: 0.42),
                    x: 0.86, y: 0.28, diameter: 0.95, opacity: 0.42,
                    drift: CGSize(width: 32, height: 28)
                ),
                AmbientBlobSpec(
                    light: Color(red: 1.00, green: 0.88, blue: 0.62),
                    dark: Color(red: 0.84, green: 0.50, blue: 0.12),
                    x: 0.72, y: 0.84, diameter: 1.05, opacity: 0.36,
                    drift: CGSize(width: 24, height: 32)
                ),
                AmbientBlobSpec(
                    light: Color(red: 0.86, green: 0.72, blue: 1.00),
                    dark: Color(red: 0.58, green: 0.24, blue: 0.72),
                    x: 0.10, y: 0.82, diameter: 0.75, opacity: 0.26,
                    drift: CGSize(width: 20, height: 24)
                ),
                AmbientBlobSpec(
                    light: Color(red: 1.00, green: 0.62, blue: 0.55),
                    dark: Color(red: 0.92, green: 0.32, blue: 0.24),
                    x: 0.50, y: 0.50, diameter: 0.85, opacity: 0.20,
                    drift: CGSize(width: 18, height: 18)
                )
            ]
        case .midnight:
            return [
                AmbientBlobSpec(
                    light: Color(red: 0.52, green: 0.74, blue: 1.00),
                    dark: Color(red: 0.12, green: 0.46, blue: 1.00),
                    x: 0.18, y: 0.16, diameter: 1.15, opacity: 0.50,
                    drift: CGSize(width: 30, height: 26)
                ),
                AmbientBlobSpec(
                    light: Color(red: 0.48, green: 0.94, blue: 0.94),
                    dark: Color(red: 0.08, green: 0.82, blue: 0.90),
                    x: 0.86, y: 0.34, diameter: 0.90, opacity: 0.42,
                    drift: CGSize(width: 26, height: 32)
                ),
                AmbientBlobSpec(
                    light: Color(red: 0.72, green: 0.60, blue: 1.00),
                    dark: Color(red: 0.50, green: 0.20, blue: 0.98),
                    x: 0.70, y: 0.86, diameter: 1.10, opacity: 0.46,
                    drift: CGSize(width: 34, height: 24)
                ),
                AmbientBlobSpec(
                    light: Color(red: 1.00, green: 0.62, blue: 0.86),
                    dark: Color(red: 0.82, green: 0.16, blue: 0.70),
                    x: 0.08, y: 0.84, diameter: 0.70, opacity: 0.24,
                    drift: CGSize(width: 20, height: 26)
                ),
                AmbientBlobSpec(
                    light: Color(red: 0.60, green: 0.88, blue: 1.00),
                    dark: Color(red: 0.20, green: 0.94, blue: 0.86),
                    x: 0.48, y: 0.52, diameter: 0.88, opacity: 0.22,
                    drift: CGSize(width: 16, height: 18)
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
/// once into a small image and repeated — a Canvas here would redraw a
/// thousand dots on every frame of the drift animation.
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

            context.cgContext.setFillColor(UIColor.white.withAlphaComponent(0.07).cgColor)
            for _ in 0..<420 {
                let x = next() * side
                let y = next() * side
                let radius = 0.35 + next() * 0.65
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
/// through, which is the whole difference between a designed backdrop and a
/// gradient sitting behind an opaque sheet. `solid` returns the exact surface
/// the app shipped with.
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
