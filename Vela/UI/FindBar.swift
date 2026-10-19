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

            Button(action: onPrevious) {
                Image(systemName: "chevron.up")
            }
            .buttonStyle(ChromeButtonStyle())
            .disabled(result.count == 0)

            Button(action: onNext) {
                Image(systemName: "chevron.down")
            }
            .buttonStyle(ChromeButtonStyle())
            .disabled(result.count == 0)

            Button(action: onClose) {
                Image(systemName: "xmark")
            }
            .buttonStyle(ChromeButtonStyle())
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
}
