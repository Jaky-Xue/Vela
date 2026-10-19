//
//  BrowserSurfaces.swift
//  Vela
//
//  The card, list and floating-glass treatments shared by the chrome.
//

import SwiftUI
import UIKit

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
            // The field shows through the list's veil; `solid` resolves to the
            // opaque palette surface this screen always had.
            .background {
                AmbientSurfaceFill(opacity: 0.58)
            }
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
