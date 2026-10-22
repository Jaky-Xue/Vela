//
//  OmniboxSearchPageView.swift
//  Vela
//
//  The full-screen search surface the omnibox session opens.
//
//  A dedicated page rather than a card over the current one: the page the user
//  was reading has nothing to do with the query they are about to type, and
//  covering it completely — the way the reference browsers do — is what makes
//  the session feel like a place rather than an interruption. The field sits
//  about a third of the way down the space the keyboard leaves, the suggestion
//  list grows beneath it, and the engine badge on the field's leading edge is
//  the switcher: one tap, one menu, every engine.
//

import SwiftUI

struct OmniboxSearchPageView: View {
    var viewModel: OmniboxViewModel
    /// The keyboard's current occlusion, so the page's content ends at the
    /// keyboard's top edge instead of under it.
    var keyboardHeight: CGFloat
    /// The tallest the suggestion list may grow.
    var cardMaxHeight: CGFloat
    /// The gap between the top of the screen and the field, computed by the
    /// shell from the real screen geometry.
    var topGap: CGFloat

    @Environment(\.browserPalette) private var palette
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        // The field is an overlay pinned to the top gap, and the list begins
        // below a spacer of exactly its height. The previous top-aligned stack
        // could still let a tall list displace the field when the keyboard
        // changed the proposed height; an overlay cannot be displaced by its
        // sibling. This is the layout that must hold on every keyboard shape,
        // including the floating iPad keyboard in the report.
        ZStack(alignment: .top) {
            VStack(spacing: 0) {
                Color.clear
                    .frame(height: topGap + BrowserChrome.barHeight + 14)

                OmniboxSuggestionListView(
                    viewModel: viewModel,
                    maxHeight: cardMaxHeight,
                    allowsThirdPartyLookup: viewModel.activePrivacyMode != .private
                )
                    .padding(.horizontal, BrowserChrome.sideInset)
                    .opacity(viewModel.text.isEmpty && viewModel.groups.isEmpty ? 0 : 1)

                Spacer(minLength: 0)
            }

            fieldRowInGlassContainer
                .padding(.top, topGap)
                .zIndex(1)
        }
        .padding(.bottom, max(0, keyboardHeight))
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        // The field is painted over whatever page happens to be behind the
        // shell, so a veil over that page would just be the page's colour at
        // 90% opacity. The search page draws the ambient field itself instead,
        // which is what makes it match the rest of the app on every site.
        .background { AmbientBackgroundView() }
    }

    /// The field is one glass control, not a coordinated group. Keeping it out
    /// of a `GlassEffectContainer` avoids the container's size negotiation on
    /// the search page; the field's own floating chrome already supplies the
    /// glass, and the field is pinned as an overlay above the list.
    private var fieldRowInGlassContainer: some View {
        fieldRow
    }

    /// The field, with the engine switcher on its leading edge and the way out
    /// on its trailing edge.
    private var fieldRow: some View {
        HStack(spacing: 10) {
            engineSwitcher

            OmniboxTextField(
                text: Binding(
                    get: { viewModel.text },
                    set: { viewModel.setText($0) }
                ),
                isEditing: viewModel.isEditing,
                placeholder: "搜索或输入网址",
                onSubmit: { viewModel.submit() },
                onMoveHighlight: { viewModel.moveHighlight(by: $0) },
                onEscape: { viewModel.cancel() },
                onBeginEditing: { viewModel.beginEditing() },
                grabsFocus: true,
                palette: palette,
                colorScheme: colorScheme
            )

            // Always present: the search page covers the page the user came
            // from, and the command bar with it — this button is the way back.
            Button("取消") { viewModel.cancel() }
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(palette.accent)
        }
        .padding(.leading, 14)
        .padding(.trailing, 14)
        .frame(height: BrowserChrome.barHeight)
        // The same floating glass as the command bar, so the search field is
        // the bar lifted off the page rather than a second kind of control.
        // The radius and height match the bottom bar's field exactly, so the
        // address field reads as the same control in both places.
        .browserFloatingChrome(
            radius: BrowserRadius.omnibox,
            material: .regularMaterial,
            tintStrength: 0.35,
            elevation: .floating,
            interactive: false
        )
        .padding(.horizontal, BrowserChrome.sideInset)
        .animation(.easeOut(duration: 0.15), value: viewModel.text.isEmpty)
    }

    /// The active engine's initial on a disc; tapping it opens the engine menu.
    /// Switching here re-aims the query the user is about to type, which is the
    /// moment the choice actually matters.
    private var engineSwitcher: some View {
        Menu {
            ForEach(viewModel.availableEngines) { engine in
                Button {
                    viewModel.switchEngine(to: engine)
                } label: {
                    if engine.name == viewModel.activeEngineName {
                        Label(engine.name, systemImage: "checkmark")
                    } else {
                        Text(engine.name)
                    }
                }
            }
        } label: {
            ZStack {
                Circle()
                    .fill(palette.accent.opacity(0.14))
                Text(String(viewModel.activeEngineName.prefix(1)))
                    .font(.system(size: 15, weight: .bold, design: .rounded))
                    .foregroundStyle(palette.accent)
            }
            .frame(width: 30, height: 30)
            .contentShape(Circle())
        }
        .accessibilityLabel("搜索引擎，当前 \(viewModel.activeEngineName)")
    }
}
