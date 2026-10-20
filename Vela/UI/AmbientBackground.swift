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
//  The three fields are warm and clearly separated by hue: 暖阳 is peach and
//  pale gold, 晚霞 is coral and rose, 琥珀 is cream and amber. Colours are
//  pale on purpose; the frosted pane over them is thin so the result reads as
//  light seen through glass, not as paint.
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
    /// Peach, apricot and pale gold: the warm morning field.
    case sunrise
    /// Coral, rose and mauve: the soft sunset field.
    case sunset
    /// Cream, butter and amber: the golden field.
    case amber

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .solid: return "纯净"
        case .sunrise: return "暖阳"
        case .sunset: return "晚霞"
        case .amber: return "琥珀"
        }
    }

    public var summary: String {
        switch self {
        case .solid: return "纯白与纯黑，来自配色"
        case .sunrise: return "蜜桃与浅金，温暖通透"
        case .sunset: return "珊瑚与玫瑰，柔和晚霞"
        case .amber: return "奶油与琥珀，干净温暖"
        }
    }

    public var symbolName: String {
        switch self {
        case .solid: return "circle.fill"
        case .sunrise: return "sun.max.fill"
        case .sunset: return "sunset.fill"
        case .amber: return "sun.haze.fill"
        }
    }

    /// Whether the style paints anything beyond the palette surface.
    public var usesAmbient: Bool { self != .solid }

    /// Resolves a stored raw value, falling back to the shipped default.
    ///
    /// The cool styles this build replaced (`aurora`, `glacier`, `violet`,
    /// plus the older `dawn`/`midnight`) map to the warm field that is closest
    /// in role, so an existing choice is kept rather than reset.
    public static func resolve(_ rawValue: String?) -> BrowserBackgroundStyle {
        guard let rawValue else { return .sunrise }
        if let style = BrowserBackgroundStyle(rawValue: rawValue) {
            return style
        }
        switch rawValue {
        case "aurora", "dawn": return .sunrise
        case "glacier", "midnight": return .sunset
        case "violet": return .amber
        default: return .sunrise
        }
    }
}

// MARK: - Environment

private struct BrowserBackgroundStyleKey: EnvironmentKey {
    static let defaultValue: BrowserBackgroundStyle = .sunrise
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
                    Color(red: 1.000, green: 0.988, blue: 0.965),
                    Color(red: 1.000, green: 0.957, blue: 0.902),
                    Color(red: 1.000, green: 0.976, blue: 0.937)
                ]
        case .sunset:
            return colorScheme == .dark
                ? [
                    Color(red: 0.149, green: 0.086, blue: 0.098),
                    Color(red: 0.176, green: 0.102, blue: 0.118),
                    Color(red: 0.145, green: 0.082, blue: 0.098)
                ]
                : [
                    Color(red: 1.000, green: 0.980, blue: 0.973),
                    Color(red: 1.000, green: 0.937, blue: 0.929),
                    Color(red: 1.000, green: 0.965, blue: 0.953)
                ]
        case .amber:
            return colorScheme == .dark
                ? [
                    Color(red: 0.141, green: 0.122, blue: 0.071),
                    Color(red: 0.169, green: 0.145, blue: 0.090),
                    Color(red: 0.149, green: 0.129, blue: 0.071)
                ]
                : [
                    Color(red: 1.000, green: 0.992, blue: 0.969),
                    Color(red: 1.000, green: 0.969, blue: 0.890),
                    Color(red: 1.000, green: 0.984, blue: 0.941)
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
                    Color(red: 1.000, green: 0.992, blue: 0.973),
                    Color(red: 1.000, green: 0.914, blue: 0.812),
                    Color(red: 1.000, green: 0.851, blue: 0.706),
                    Color(red: 1.000, green: 0.965, blue: 0.910),
                    Color(red: 1.000, green: 0.816, blue: 0.643),
                    Color(red: 1.000, green: 0.761, blue: 0.557),
                    Color(red: 1.000, green: 0.918, blue: 0.784),
                    Color(red: 1.000, green: 0.847, blue: 0.682),
                    Color(red: 1.000, green: 0.980, blue: 0.949)
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
                    Color(red: 1.000, green: 0.980, blue: 0.973),
                    Color(red: 1.000, green: 0.878, blue: 0.863),
                    Color(red: 1.000, green: 0.788, blue: 0.784),
                    Color(red: 1.000, green: 0.941, blue: 0.925),
                    Color(red: 1.000, green: 0.714, blue: 0.714),
                    Color(red: 1.000, green: 0.639, blue: 0.663),
                    Color(red: 1.000, green: 0.867, blue: 0.843),
                    Color(red: 1.000, green: 0.776, blue: 0.784),
                    Color(red: 1.000, green: 0.969, blue: 0.957)
                ]
        case .amber:
            return dark
                ? [
                    Color(red: 0.157, green: 0.137, blue: 0.078),
                    Color(red: 0.275, green: 0.227, blue: 0.114),
                    Color(red: 0.416, green: 0.341, blue: 0.149),
                    Color(red: 0.208, green: 0.176, blue: 0.094),
                    Color(red: 0.502, green: 0.404, blue: 0.184),
                    Color(red: 0.580, green: 0.482, blue: 0.239),
                    Color(red: 0.310, green: 0.259, blue: 0.122),
                    Color(red: 0.427, green: 0.345, blue: 0.161),
                    Color(red: 0.169, green: 0.145, blue: 0.086)
                ]
                : [
                    Color(red: 1.000, green: 0.992, blue: 0.969),
                    Color(red: 1.000, green: 0.945, blue: 0.827),
                    Color(red: 1.000, green: 0.890, blue: 0.675),
                    Color(red: 1.000, green: 0.976, blue: 0.918),
                    Color(red: 1.000, green: 0.843, blue: 0.561),
                    Color(red: 1.000, green: 0.796, blue: 0.447),
                    Color(red: 1.000, green: 0.949, blue: 0.827),
                    Color(red: 1.000, green: 0.882, blue: 0.659),
                    Color(red: 1.000, green: 0.988, blue: 0.953)
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
        switch style {
        case .solid:
            return []
        case .sunrise:
            return [
                AmbientBlobSpec(
                    light: Color(red: 1.00, green: 0.87, blue: 0.74),
                    dark: Color(red: 0.82, green: 0.60, blue: 0.38),
                    x: 0.14, y: 0.12, diameter: 1.20,
                    opacity: colorScheme == .dark ? 0.22 : 0.34
                ),
                AmbientBlobSpec(
                    light: Color(red: 1.00, green: 0.93, blue: 0.78),
                    dark: Color(red: 0.72, green: 0.56, blue: 0.30),
                    x: 0.86, y: 0.26, diameter: 1.10,
                    opacity: colorScheme == .dark ? 0.20 : 0.30
                ),
                AmbientBlobSpec(
                    light: Color(red: 1.00, green: 0.80, blue: 0.66),
                    dark: Color(red: 0.76, green: 0.48, blue: 0.27),
                    x: 0.76, y: 0.86, diameter: 1.15,
                    opacity: colorScheme == .dark ? 0.20 : 0.30
                ),
                AmbientBlobSpec(
                    light: Color(red: 1.00, green: 0.90, blue: 0.84),
                    dark: Color(red: 0.58, green: 0.40, blue: 0.26),
                    x: 0.10, y: 0.86, diameter: 0.80,
                    opacity: colorScheme == .dark ? 0.12 : 0.18
                )
            ]
        case .sunset:
            return [
                AmbientBlobSpec(
                    light: Color(red: 1.00, green: 0.78, blue: 0.76),
                    dark: Color(red: 0.86, green: 0.46, blue: 0.50),
                    x: 0.14, y: 0.12, diameter: 1.20,
                    opacity: colorScheme == .dark ? 0.22 : 0.34
                ),
                AmbientBlobSpec(
                    light: Color(red: 1.00, green: 0.70, blue: 0.73),
                    dark: Color(red: 0.74, green: 0.36, blue: 0.42),
                    x: 0.86, y: 0.28, diameter: 1.10,
                    opacity: colorScheme == .dark ? 0.20 : 0.30
                ),
                AmbientBlobSpec(
                    light: Color(red: 0.96, green: 0.76, blue: 0.86),
                    dark: Color(red: 0.60, green: 0.32, blue: 0.44),
                    x: 0.74, y: 0.86, diameter: 1.15,
                    opacity: colorScheme == .dark ? 0.18 : 0.28
                ),
                AmbientBlobSpec(
                    light: Color(red: 1.00, green: 0.86, blue: 0.80),
                    dark: Color(red: 0.52, green: 0.30, blue: 0.30),
                    x: 0.10, y: 0.86, diameter: 0.80,
                    opacity: colorScheme == .dark ? 0.12 : 0.18
                )
            ]
        case .amber:
            return [
                AmbientBlobSpec(
                    light: Color(red: 1.00, green: 0.93, blue: 0.74),
                    dark: Color(red: 0.82, green: 0.66, blue: 0.36),
                    x: 0.14, y: 0.14, diameter: 1.20,
                    opacity: colorScheme == .dark ? 0.22 : 0.34
                ),
                AmbientBlobSpec(
                    light: Color(red: 1.00, green: 0.97, blue: 0.84),
                    dark: Color(red: 0.70, green: 0.60, blue: 0.32),
                    x: 0.86, y: 0.30, diameter: 1.05,
                    opacity: colorScheme == .dark ? 0.20 : 0.30
                ),
                AmbientBlobSpec(
                    light: Color(red: 1.00, green: 0.88, blue: 0.62),
                    dark: Color(red: 0.72, green: 0.58, blue: 0.26),
                    x: 0.74, y: 0.86, diameter: 1.15,
                    opacity: colorScheme == .dark ? 0.20 : 0.30
                ),
                AmbientBlobSpec(
                    light: Color(red: 1.00, green: 0.95, blue: 0.86),
                    dark: Color(red: 0.55, green: 0.44, blue: 0.22),
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
