//
//  AppearanceSettingsView.swift
//  Vela
//
//  The palette and background pickers, and the side-by-side appearance preview.
//

import SwiftUI
import UIKit

// MARK: - Appearance

/// The palette picker, plus the per-app appearance override.
struct AppearanceSettingsView: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.browserPalette) private var palette

    var body: some View {
        List {
            Section {
                Picker("外观", selection: Binding(
                    get: { env.settings.appearanceMode },
                    set: { env.settings.setAppearanceMode($0) }
                )) {
                    ForEach(AppearanceMode.allCases) { mode in
                        Label(mode.displayName, systemImage: mode.symbolName)
                            .tag(mode)
                    }
                }
                .pickerStyle(.inline)
                .labelsHidden()

                // A preview strip, so the choice can be judged without leaving
                // the screen and flipping the whole app back and forth.
                AppearancePreviewStrip()
                    .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
            } header: {
                Text("外观模式")
            } footer: {
                Text("「跟随系统」随系统设置实时切换。")
            }

            Section {
                ForEach(BrowserPalette.all) { candidate in
                    Button {
                        env.settings.update { $0.themePaletteId = candidate.id }
                    } label: {
                        HStack(spacing: 12) {
                            Circle()
                                .fill(candidate.accent)
                                .frame(width: 22, height: 22)
                                .overlay {
                                    Circle().strokeBorder(palette.cardStroke, lineWidth: 0.5)
                                }
                            VStack(alignment: .leading, spacing: 2) {
                                Text(candidate.displayName)
                                    .foregroundStyle(palette.primaryText)
                                Text("\(candidate.light.accent.hexDescription) · \(candidate.dark.accent.hexDescription)")
                                    .font(.caption2)
                                    .foregroundStyle(palette.secondaryText)
                            }
                            Spacer()
                            if env.settings.preferences.themePaletteId == candidate.id {
                                Image(systemName: "checkmark")
                                    .foregroundStyle(palette.accent)
                            }
                        }
                    }
                }
            } header: {
                Text("配色")
            }

            Section {
                ForEach(BrowserBackgroundStyle.allCases) { style in
                    Button {
                        env.settings.backgroundStyle = style
                    } label: {
                        HStack(spacing: 12) {
                            BackgroundStyleSwatch(style: style)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(style.displayName)
                                    .foregroundStyle(palette.primaryText)
                                Text(style.summary)
                                    .font(.caption2)
                                    .foregroundStyle(palette.secondaryText)
                            }
                            Spacer()
                            if env.settings.backgroundStyle == style {
                                Image(systemName: "checkmark")
                                    .foregroundStyle(palette.accent)
                            }
                        }
                    }
                }
            } header: {
                Text("全局背景")
            } footer: {
                Text("背景作用于主页、设置、书架与浮层，玻璃工具栏会折射它。网页本身保持网站自己的颜色。")
            }

            Section {
                Toggle("无痕标签页需要验证身份", isOn: Binding(
                    get: { env.settings.preferences.lockPrivateTabs },
                    set: { value in env.settings.update { $0.lockPrivateTabs = value } }
                ))
                Toggle("模糊无痕标签页预览", isOn: Binding(
                    get: { env.settings.preferences.blurPrivateTabPreviews },
                    set: { value in env.settings.update { $0.blurPrivateTabPreviews = value } }
                ))
            } header: {
                Text("无痕模式")
            }
        }
        .navigationTitle("外观")
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// Both appearances, side by side, drawn as the command bar actually looks.
///
/// The point is comparison without leaving the screen — and without the
/// ambiguity the previous preview carried: it rendered only the mode the user
/// was *not* in, so picking 深色 swapped the picture to a light one at the
/// moment the app itself went dark, and its layout was a top address bar the
/// real chrome no longer has. So this strip always shows both modes with the
/// same three-group bottom bar the browser draws — history buttons, the
/// omnibox field, the view controls — and marks the one currently in effect,
/// which is the one the user can compare against by looking up.
private struct AppearancePreviewStrip: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.browserPalette) private var palette
    @Environment(\.colorScheme) private var colorScheme

    /// The mode the app is actually rendering in: the user's choice, or the
    /// system's when the choice is 跟随系统.
    private var effectiveScheme: ColorScheme {
        switch env.settings.appearanceMode {
        case .light: return .light
        case .dark: return .dark
        case .system: return colorScheme
        }
    }

    var body: some View {
        HStack(spacing: 10) {
            AppearancePreviewCard(
                tokens: palette.tokens(for: .light),
                title: "浅色",
                isInEffect: effectiveScheme == .light
            )
            AppearancePreviewCard(
                tokens: palette.tokens(for: .dark),
                title: "深色",
                isInEffect: effectiveScheme == .dark
            )
        }
    }
}

/// One mode's miniature: the chrome's three groups over the page surface, at
/// the proportions of the real bar.
private struct AppearancePreviewCard: View {
    let tokens: BrowserColorTokens
    let title: String
    let isInEffect: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 5) {
                previewGroup {
                    Image(systemName: "chevron.left")
                    Image(systemName: "chevron.right")
                }

                HStack(spacing: 4) {
                    Image(systemName: "lock.fill")
                        .font(.system(size: 7, weight: .bold))
                        .foregroundStyle(.green)
                    Text("vela.example.com")
                        .font(.system(size: 9))
                        .foregroundStyle(tokens.secondaryText)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 7)
                .frame(height: 22)
                .frame(maxWidth: .infinity)
                .background(tokens.controlFill, in: RoundedRectangle(cornerRadius: 8, style: .continuous))

                previewGroup {
                    Image(systemName: "square.on.square")
                    Image(systemName: "ellipsis")
                }
            }
            .padding(6)
            .background(tokens.chrome, in: RoundedRectangle(cornerRadius: 14, style: .continuous))

            HStack(spacing: 4) {
                Text(title)
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(tokens.primaryText)
                if isInEffect {
                    Image(systemName: "checkmark")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(tokens.accent)
                }
            }
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(tokens.surface, in: RoundedRectangle(cornerRadius: BrowserRadius.card, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: BrowserRadius.card, style: .continuous)
                .strokeBorder(
                    isInEffect ? tokens.accent : tokens.cardStroke,
                    lineWidth: isInEffect ? 1.5 : 0.5
                )
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(isInEffect ? "\(title)预览，当前生效" : "\(title)预览")
    }

    /// One flanking group of glyphs, as the bar's chevron pair and view pair
    /// are drawn.
    private func previewGroup(@ViewBuilder glyphs: () -> some View) -> some View {
        HStack(spacing: 5) {
            glyphs()
        }
        .font(.system(size: 9, weight: .medium))
        .foregroundStyle(tokens.primaryText)
        .padding(.horizontal, 6)
        .frame(height: 22)
        .background(tokens.controlFill, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

// MARK: - Background swatch

/// A tiny print of a background style, so the list shows the difference
/// rather than naming it.
private struct BackgroundStyleSwatch: View {
    var style: BrowserBackgroundStyle
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        ZStack {
            if style == .solid {
                colorScheme == .dark ? Color.black : Color.white
            } else {
                LinearGradient(
                    colors: colors,
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            }

            if style != .solid {
                Circle()
                    .fill(.white.opacity(0.28))
                    .frame(width: 22, height: 22)
                    .blur(radius: 6)
                    .offset(x: -7, y: -8)
            }
        }
        .frame(width: 36, height: 36)
        .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .strokeBorder(.white.opacity(0.18), lineWidth: 0.5)
        }
        .accessibilityHidden(true)
    }

    private var colors: [Color] {
        switch style {
        case .solid:
            return [colorScheme == .dark ? .black : .white]
        case .sunrise:
            return [
                Color(red: 1.00, green: 0.91, blue: 0.81),
                Color(red: 1.00, green: 0.82, blue: 0.65),
                Color(red: 1.00, green: 0.76, blue: 0.56)
            ]
        case .sunset:
            return [
                Color(red: 1.00, green: 0.88, blue: 0.86),
                Color(red: 1.00, green: 0.71, blue: 0.71),
                Color(red: 1.00, green: 0.64, blue: 0.66)
            ]
        case .lime:
            return [
                Color(red: 0.90, green: 0.96, blue: 0.79),
                Color(red: 0.73, green: 0.87, blue: 0.53),
                Color(red: 0.66, green: 0.83, blue: 0.43)
            ]
        case .aurora:
            return [
                Color(red: 0.79, green: 0.95, blue: 0.91),
                Color(red: 0.52, green: 0.84, blue: 0.75),
                Color(red: 0.40, green: 0.78, blue: 0.69)
            ]
        case .glacier:
            return [
                Color(red: 0.78, green: 0.89, blue: 0.97),
                Color(red: 0.50, green: 0.71, blue: 0.91),
                Color(red: 0.37, green: 0.62, blue: 0.87)
            ]
        case .violet:
            return [
                Color(red: 0.85, green: 0.80, blue: 0.97),
                Color(red: 0.67, green: 0.57, blue: 0.92),
                Color(red: 0.58, green: 0.48, blue: 0.88)
            ]
        case .colorful:
            return [
                Color(red: 1.00, green: 0.78, blue: 0.85),
                Color(red: 0.64, green: 0.95, blue: 0.89),
                Color(red: 0.60, green: 0.82, blue: 0.98),
                Color(red: 0.82, green: 0.74, blue: 0.98)
            ]
        }
    }
}
