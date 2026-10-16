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
        VStack(spacing: 0) {
            Spacer(minLength: 0)
                .frame(maxHeight: topGap)

            fieldRow

            OmniboxSuggestionListView(viewModel: viewModel, maxHeight: cardMaxHeight)
                .padding(.horizontal, BrowserChrome.sideInset)
                .padding(.top, 14)
                .opacity(viewModel.text.isEmpty && viewModel.groups.isEmpty ? 0 : 1)

            Spacer(minLength: 0)
        }
        .padding(.bottom, keyboardHeight)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(palette.surface.ignoresSafeArea())
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

            if viewModel.text.isEmpty && viewModel.groups.isEmpty {
                Button("取消") { viewModel.cancel() }
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(palette.accent)
            }
        }
        .padding(.leading, 14)
        .padding(.trailing, 14)
        .frame(height: 54)
        .background(
            RoundedRectangle(cornerRadius: 27, style: .continuous)
                .fill(palette.controlFill.opacity(0.6))
        )
        .overlay {
            RoundedRectangle(cornerRadius: 27, style: .continuous)
                .strokeBorder(palette.cardStroke, lineWidth: 0.5)
        }
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
