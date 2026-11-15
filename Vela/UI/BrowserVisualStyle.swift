import SwiftUI

/// Visual character is independent of persisted palette/background identifiers.
/// Chrome remains translucent in every theme; content surfaces may be quieter.
struct BrowserVisualStyle: Equatable, Sendable {
    enum Surface: String, Sendable { case glass, soft, paper }
    enum Elevation: String, Sendable { case floating, soft, crisp }
    enum Icons: String, Sendable { case outline, filled }

    var surface: Surface = .glass
    var elevation: Elevation = .floating
    var icons: Icons = .outline
    var recommendedBackground: BrowserBackgroundStyle = .solid

    static let standard = BrowserVisualStyle()

    static func forPalette(_ id: String) -> Self {
        switch id {
        case "morandi", "slate":
            return Self(surface: .paper, elevation: .crisp, recommendedBackground: .pearl)
        case "jade":
            return Self(surface: .soft, elevation: .soft, recommendedBackground: .forest)
        case "amber":
            return Self(surface: .paper, elevation: .soft, icons: .filled, recommendedBackground: .desert)
        case "rose":
            return Self(surface: .soft, elevation: .soft, recommendedBackground: .pearl)
        case "crimson":
            return Self(surface: .paper, elevation: .crisp, icons: .filled, recommendedBackground: .sunset)
        case "iris":
            return Self(recommendedBackground: .violet)
        case "ocean", "cobalt":
            return Self(recommendedBackground: .glacier)
        default:
            return .standard
        }
    }

    var cardRadius: CGFloat { surface == .glass ? 20 : surface == .soft ? 18 : 16 }
    var cardMaterial: Material { surface == .glass ? .thinMaterial : .regularMaterial }
    var chromeTint: Double { surface == .paper ? 0.12 : surface == .soft ? 0.08 : 0.04 }
    var menuVeil: Double { surface == .glass ? 0.78 : surface == .soft ? 0.90 : 1 }

    func cardOpacity(reduceTransparency: Bool) -> Double {
        if reduceTransparency || surface == .paper { return 1 }
        return surface == .glass ? 0.32 : 0.72
    }

    func rowOpacity(reduceTransparency: Bool) -> Double {
        reduceTransparency || surface == .paper ? 1 : surface == .soft ? 0.96 : 0.90
    }

    func resolvedElevation(_ base: BrowserElevation) -> BrowserElevation {
        switch elevation {
        case .floating: return base
        case .soft: return BrowserElevation(radius: base.radius * 0.72, y: base.y * 0.55, opacity: base.opacity * 0.70)
        case .crisp: return BrowserElevation(radius: base.radius * 0.25, y: min(2, base.y * 0.25), opacity: base.opacity * 0.55)
        }
    }
}
