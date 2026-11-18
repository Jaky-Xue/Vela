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
    /// When the system's reduced-transparency setting is on, a material loses
    /// its body and the card turns into a washed-out version of the page behind
    /// it. The card then paints the palette's card fill, which keeps the same
    /// silhouette and the same contrast without the blur.
    @Environment(\.browserReduceTransparency) private var reduceTransparency

    var material: Material? = nil
    var radius: CGFloat = BrowserRadius.card
    var elevation: BrowserElevation = .card
    /// Drawn behind the material. A material over a white page washes out, so
    /// the tint underneath is what gives the card a body of its own.
    var tint: Color?

    @ViewBuilder
    func body(content: Content) -> some View {
        let style = palette.visualStyle
        let resolvedRadius = radius == BrowserRadius.card ? style.cardRadius : radius
        let resolvedElevation = style.resolvedElevation(elevation)
        let shape = RoundedRectangle(cornerRadius: resolvedRadius, style: .continuous)
        content
            .background {
                if colorScheme == .light || reduceTransparency || style.surface == .paper {
                    shape.fill(palette.card)
                } else {
                    shape.fill(tint ?? palette.card.opacity(style.cardOpacity(reduceTransparency: false)))
                    shape.fill(material ?? style.cardMaterial)
                }
            }
            .overlay(shape.strokeBorder(palette.cardStroke, lineWidth: 1))
            .clipShape(shape)
            .shadow(
                color: resolvedElevation.shadowColor(for: colorScheme),
                radius: resolvedElevation.radius,
                y: resolvedElevation.y
            )
    }
}

extension View {
    /// Wraps the receiver in the shared raised-card treatment.
    func browserCard(
        material: Material? = nil,
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
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.browserPalette) private var palette
    @Environment(\.browserReduceTransparency) private var reduceTransparency

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
                if colorScheme == .light {
                    Color(uiColor: .systemGroupedBackground)
                } else {
                    AmbientSurfaceFill(opacity: 0.92)
                }
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

// MARK: - Settings list

/// The one treatment every settings screen uses.
///
/// The palette surface and the card rows already come from
/// `browserListSurface`; this adds the two things a settings screen needs on
/// top of it — the palette's accent on every switch, checkmark and segmented
/// selection, so the controls stop being system blue against a themed
/// surface, and one section rhythm across pages that each used to pick their
/// own spacing.
struct SettingsListStyle: ViewModifier {
    @Environment(\.browserPalette) private var palette

    func body(content: Content) -> some View {
        content
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
            .background(Color(uiColor: .systemGroupedBackground))
            .toolbarBackground(Color(uiColor: .systemGroupedBackground), for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .listRowBackground(Color(uiColor: .secondarySystemGroupedBackground))
            .foregroundStyle(palette.primaryText)
            .tint(palette.accent)
            .listSectionSpacing(24)
            .listRowInsets(EdgeInsets(top: 12, leading: 18, bottom: 12, trailing: 18))
            .listRowSeparatorTint(palette.separator)
            .environment(\.defaultMinListRowHeight, 54)
            .textFieldStyle(.roundedBorder)
    }
}

/// Search and surrounding controls share one glass recipe.
struct BrowserSearchFieldStyle: ViewModifier {
    func body(content: Content) -> some View {
        content
            .browserFloatingChrome(radius: BrowserRadius.omnibox, elevation: .card, interactive: false)
    }
}

extension View {
    func browserSearchField() -> some View { modifier(BrowserSearchFieldStyle()) }
}

extension View {
    /// Applies the settings screens' shared list treatment.
    func settingsList() -> some View {
        modifier(SettingsListStyle())
    }
}

// MARK: - Floating chrome

/// The treatment for a control that floats above the page rather than being a
/// strip of the screen: the omnibox, the top command bar, the find bar.
///
/// On iOS 26 the fill is the system's own Liquid Glass — `glassEffect` — which
/// refracts the page scrolling underneath it the way the rest of the system
/// does. Earlier SDKs cannot express that call at all, so the same modifier
/// carries a light tint under a blur material. No opaque card sits underneath:
/// the native material must sample the actual page to remain translucent.
struct BrowserFloatingChrome: ViewModifier {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.browserPalette) private var palette
    @Environment(\.browserReduceTransparency) private var reduceTransparency

    var radius: CGFloat
    var material: Material
    /// A light tint under the fallback material. Native glass supplies its own body.
    var tintStrength: Double
    var elevation: BrowserElevation
    /// Whether the glass responds to touch with the system's own highlight.
    var interactive: Bool

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        #if compiler(>=6.2)
        if #available(iOS 26.0, *), !reduceTransparency {
            content
                .glassEffect(
                    interactive ? Glass.regular.tint(palette.chromeBackground.opacity(0.16)).interactive() : Glass.regular.tint(palette.chromeBackground.opacity(0.16)),
                    in: shape
                )
                .overlay {
                    shape.strokeBorder(palette.cardStroke, lineWidth: 0.75)
                        .allowsHitTesting(false)
                }
                .shadow(
                    color: palette.visualStyle.resolvedElevation(elevation).shadowColor(for: colorScheme),
                    radius: palette.visualStyle.resolvedElevation(elevation).radius,
                    y: palette.visualStyle.resolvedElevation(elevation).y
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
                if reduceTransparency {
                    shape.fill(palette.chromeBackground)
                } else {
                    shape.fill(material)
                    shape.fill(palette.chromeBackground.opacity(colorScheme == .light ? 0.45 : 0.25))
                }
            }
            .overlay(shape.strokeBorder(palette.cardStroke, lineWidth: 1))
            .clipShape(shape)
            .shadow(
                color: palette.visualStyle.resolvedElevation(elevation).shadowColor(for: colorScheme),
                radius: palette.visualStyle.resolvedElevation(elevation).radius,
                y: palette.visualStyle.resolvedElevation(elevation).y
            )
    }
}

extension View {
    /// Uses the browser chrome as the presentation background, with the sheet
    /// supplying its own clipping and the presenting page supplying the backdrop.
    func browserGlassSheet() -> some View {
        presentationBackground {
            Color.clear
                .browserFloatingChrome(
                    radius: BrowserRadius.floating,
                    material: .thinMaterial,
                    tintStrength: 0.22,
                    interactive: false
                )
                .luminousSheen(shape: RoundedRectangle(cornerRadius: BrowserRadius.floating))
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
    }

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
