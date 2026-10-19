//
//  AmbientBackground.swift
//  Vela
//
//  The app-wide background: a palette surface, or a luminous field of colour
//  behind it.
//
//  The old surface was a literal white or black rectangle, which is correct for
//  a document but reads as an empty application wherever the page is not the
//  subject — the home screen, settings, the shelves. The ambient styles put a
//  slow field of light under those surfaces, so the glass the chrome already
//  draws has something to refract and the app reads as one designed place
//  rather than a page with controls bolted to it.
//
//  The field is layered radial gradients on a palette-tinted base. A radial
//  gradient already fades to nothing at its rim, so the blobs can overlap
//  without seams; the blur only softens what is left of the edge. On a dark
//  surface the blobs are drawn with `plusLighter`, which is what turns them
//  into light rather than paint. `Reduce Motion` freezes the drift.
//

import SwiftUI

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
                    ForEach(specs.indices, id: \.self) { index in
                        blob(specs[index], index: index, in: size)
                    }

                    // A soft top sheen and a bottom vignette: the two touches
                    // that make a field of colour read as lit from above
                    // rather than as a printed gradient.
                    LinearGradient(
                        stops: [
                            .init(color: .white.opacity(colorScheme == .dark ? 0.05 : 0.22), location: 0),
                            .init(color: .clear, location: 0.42)
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                    .blendMode(.plusLighter)
                    .allowsHitTesting(false)

                    RadialGradient(
                        colors: [.clear, .black.opacity(colorScheme == .dark ? 0.30 : 0.05)],
                        center: .center,
                        startRadius: max(size.width, size.height) * 0.30,
                        endRadius: max(size.width, size.height) * 0.78
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

    /// The palette surface, tinted toward the style's leading colour so the
    /// field sits on a surface that belongs to it rather than on a white card.
    private var base: some View {
        let tokens = palette.tokens(for: colorScheme)
        let lead = specs.first.map { colorScheme == .dark ? $0.dark : $0.light }
        return ZStack {
            tokens.surface
            if style.usesAmbient, let lead {
                LinearGradient(
                    colors: [
                        lead.opacity(colorScheme == .dark ? 0.16 : 0.10),
                        tokens.surface.opacity(0.0)
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            }
        }
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
                        color.opacity(spec.opacity * 0.45),
                        color.opacity(0)
                    ],
                    center: .center,
                    startRadius: 0,
                    endRadius: diameter * 0.5
                )
            )
            .frame(width: diameter, height: diameter)
            .blur(radius: diameter * 0.10)
            .blendMode(colorScheme == .dark ? .plusLighter : .normal)
            .position(
                x: size.width * spec.x + dx,
                y: size.height * spec.y + dy
            )
            .allowsHitTesting(false)
    }

    private func startDrifting() {
        guard style.usesAmbient, !reduceMotion else { return }
        withAnimation(.easeInOut(duration: 18).repeatForever(autoreverses: true)) {
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
                    light: Color(red: 0.46, green: 0.86, blue: 0.78),
                    dark: Color(red: 0.20, green: 0.78, blue: 0.72),
                    x: 0.18, y: 0.16, diameter: 1.05, opacity: 0.42,
                    drift: CGSize(width: 30, height: 22)
                ),
                AmbientBlobSpec(
                    light: Color(red: 0.56, green: 0.72, blue: 1.00),
                    dark: Color(red: 0.32, green: 0.45, blue: 0.98),
                    x: 0.86, y: 0.28, diameter: 0.95, opacity: 0.40,
                    drift: CGSize(width: 24, height: 30)
                ),
                AmbientBlobSpec(
                    light: Color(red: 0.80, green: 0.62, blue: 1.00),
                    dark: Color(red: 0.62, green: 0.34, blue: 0.98),
                    x: 0.72, y: 0.82, diameter: 1.10, opacity: 0.34,
                    drift: CGSize(width: 34, height: 24)
                ),
                AmbientBlobSpec(
                    light: Color(red: 1.00, green: 0.72, blue: 0.86),
                    dark: Color(red: 0.92, green: 0.36, blue: 0.72),
                    x: 0.12, y: 0.86, diameter: 0.75, opacity: 0.26,
                    drift: CGSize(width: 20, height: 26)
                )
            ]
        case .dawn:
            return [
                AmbientBlobSpec(
                    light: Color(red: 1.00, green: 0.78, blue: 0.62),
                    dark: Color(red: 0.96, green: 0.56, blue: 0.28),
                    x: 0.16, y: 0.14, diameter: 1.05, opacity: 0.40,
                    drift: CGSize(width: 26, height: 20)
                ),
                AmbientBlobSpec(
                    light: Color(red: 1.00, green: 0.68, blue: 0.74),
                    dark: Color(red: 0.88, green: 0.30, blue: 0.44),
                    x: 0.84, y: 0.30, diameter: 0.90, opacity: 0.34,
                    drift: CGSize(width: 30, height: 26)
                ),
                AmbientBlobSpec(
                    light: Color(red: 1.00, green: 0.90, blue: 0.66),
                    dark: Color(red: 0.80, green: 0.52, blue: 0.16),
                    x: 0.70, y: 0.84, diameter: 1.00, opacity: 0.30,
                    drift: CGSize(width: 22, height: 30)
                ),
                AmbientBlobSpec(
                    light: Color(red: 0.82, green: 0.72, blue: 1.00),
                    dark: Color(red: 0.52, green: 0.30, blue: 0.72),
                    x: 0.12, y: 0.80, diameter: 0.70, opacity: 0.22,
                    drift: CGSize(width: 18, height: 22)
                )
            ]
        case .midnight:
            return [
                AmbientBlobSpec(
                    light: Color(red: 0.56, green: 0.78, blue: 1.00),
                    dark: Color(red: 0.18, green: 0.48, blue: 0.98),
                    x: 0.20, y: 0.18, diameter: 1.10, opacity: 0.42,
                    drift: CGSize(width: 28, height: 24)
                ),
                AmbientBlobSpec(
                    light: Color(red: 0.52, green: 0.94, blue: 0.94),
                    dark: Color(red: 0.12, green: 0.78, blue: 0.86),
                    x: 0.84, y: 0.36, diameter: 0.85, opacity: 0.34,
                    drift: CGSize(width: 24, height: 30)
                ),
                AmbientBlobSpec(
                    light: Color(red: 0.74, green: 0.64, blue: 1.00),
                    dark: Color(red: 0.50, green: 0.26, blue: 0.96),
                    x: 0.68, y: 0.86, diameter: 1.05, opacity: 0.38,
                    drift: CGSize(width: 32, height: 22)
                ),
                AmbientBlobSpec(
                    light: Color(red: 1.00, green: 0.66, blue: 0.86),
                    dark: Color(red: 0.78, green: 0.22, blue: 0.64),
                    x: 0.10, y: 0.82, diameter: 0.68, opacity: 0.20,
                    drift: CGSize(width: 18, height: 24)
                )
            ]
        }
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
