//
//  Findbar.swift
//  Vela
//
//  The in-page find bar that floats above the command bar.
//

import SwiftUI
import UIKit

// MARK: - Find bar

struct FindBar: View {
    @Binding var query: String
    var result: FindResult
    var onNext: () -> Void
    var onPrevious: () -> Void
    var onClose: () -> Void

    @Environment(\.browserPalette) private var palette
    @FocusState private var isFocused: Bool

    var body: some View {
        HStack(spacing: BrowserSpacing.compact) {
            HStack(spacing: BrowserSpacing.tight) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 13))
                    .foregroundStyle(palette.secondaryText)
                TextField("在页面中查找", text: $query)
                    .textFieldStyle(.plain)
                    .font(.subheadline)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .focused($isFocused)
                    .onSubmit(onNext)
                if !query.isEmpty {
                    Text(result.displayText)
                        .font(.caption)
                        .foregroundStyle(palette.secondaryText)
                        .monospacedDigit()
                }
            }
            .padding(.horizontal, BrowserSpacing.compact)
            .frame(height: 38)
            .background(palette.controlFill.opacity(0.7), in: Capsule())

            findAction("chevron.up", label: "上一个", enabled: result.count > 0, action: onPrevious)
            findAction("chevron.down", label: "下一个", enabled: result.count > 0, action: onNext)
            findAction("xmark", label: "关闭查找", enabled: true) {
                // Let go of the field first: a still-focused text field kept
                // the keyboard up after the bar itself was gone, which read as
                // the close having done nothing.
                isFocused = false
                onClose()
            }
        }
        .foregroundStyle(palette.primaryText)
        .padding(.horizontal, BrowserSpacing.compact + 2)
        .padding(.vertical, BrowserSpacing.tight)
        // The same floating glass as the command bar above it, so opening the
        // find bar reads as one more control arriving in the chrome rather than
        // as a second kind of surface.
        .browserFloatingChrome(
            radius: BrowserRadius.omnibox,
            material: .regularMaterial,
            tintStrength: 0.55,
            elevation: .card
        )
        .onAppear { isFocused = true }
    }

    /// One find-bar control, with the 34 pt touch target the chrome's other
    /// glyphs use. A bare symbol was a ~12 pt target, so the close mark in
    /// particular was easy to miss and looked broken.
    private func findAction(
        _ symbol: String,
        label: String,
        enabled: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 15, weight: .semibold))
                .frame(width: 34, height: 34)
                .contentShape(Rectangle())
        }
        .buttonStyle(ChromeButtonStyle())
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.35)
        .accessibilityLabel(label)
    }
}
