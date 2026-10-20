//
//  AppearanceSettingsView.swift
//  Vela
//
//  The palette and background pickers, and the side-by-side appearance preview.
//

import SwiftUI
import UIKit
import PhotosUI

// MARK: - Appearance

/// The palette picker, plus the per-app appearance override.
struct AppearanceSettingsView: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.browserPalette) private var palette

    @State private var showPhotoPicker = false

    private var backgroundImageStamp: Double? {
        env.settings.preferences.backgroundImageStamp
    }

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
                Text("「跟随系统」随系统设置实时切换；也可以直接轻点上面的浅色或深色预览立即切换。")
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
                if let image = BackgroundImageStore.load(stamp: backgroundImageStamp) {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                        .frame(height: 140)
                        .frame(maxWidth: .infinity)
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                        .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
                }

                Button {
                    showPhotoPicker = true
                } label: {
                    Label(
                        backgroundImageStamp == nil ? "从相册选择图片" : "更换图片",
                        systemImage: "photo"
                    )
                }

                if backgroundImageStamp != nil {
                    Button(role: .destructive) {
                        BackgroundImageStore.clear()
                        env.settings.update { $0.backgroundImageStamp = nil }
                    } label: {
                        Label("移除图片", systemImage: "trash")
                    }
                }
            } header: {
                Text("自定义背景图片")
            } footer: {
                Text(
                    backgroundImageStamp == nil
                        ? "选择一张图片作为全局背景，主页、顶部栏与设置界面都会使用它。"
                        : "当前使用自定义图片；移除后会回到下方选择的背景样式。"
                )
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
                Text("背景作用于主页、设置、书架与浮层，玻璃工具栏会折射它。网页本身保持网站自己的颜色。选择了自定义图片时，这里的样式暂不显示。")
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
        .sheet(isPresented: $showPhotoPicker) {
            PhotoLibraryPicker { image in
                saveBackgroundImage(image)
            }
        }
    }

    /// Writes the picture and records its stamp in one step. The shell reads
    /// the stamp, so the change is live behind the settings sheet.
    private func saveBackgroundImage(_ image: UIImage) {
        guard let stamp = BackgroundImageStore.save(image) else { return }
        env.settings.update { $0.backgroundImageStamp = stamp }
    }
}

// MARK: - Photo picker

/// The system photo picker, bridged.
///
/// `PHPicker` rather than the `Photos` framework: the picker runs out of
/// process, hands over exactly the one image the user chose, and asks for no
/// photo-library permission at all — which is the whole reason the feature
/// can ship as a single button.
struct PhotoLibraryPicker: UIViewControllerRepresentable {
    /// Called on the main actor with the chosen image.
    var onImage: (UIImage) -> Void

    @Environment(\.dismiss) private var dismiss

    func makeUIViewController(context: Context) -> PHPickerViewController {
        var configuration = PHPickerConfiguration(photoLibrary: .shared())
        configuration.filter = .images
        configuration.selectionLimit = 1
        let controller = PHPickerViewController(configuration: configuration)
        controller.delegate = context.coordinator
        return controller
    }

    func updateUIViewController(_ controller: PHPickerViewController, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    final class Coordinator: NSObject, PHPickerViewControllerDelegate {
        private var parent: PhotoLibraryPicker

        init(parent: PhotoLibraryPicker) {
            self.parent = parent
        }

        func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
            parent.dismiss()
            guard let provider = results.first?.itemProvider,
                  provider.canLoadObject(ofClass: UIImage.self) else { return }
            // The load lands off the main actor; the caller is a UIKit view
            // and a settings write, so the hop is made before it is handed on.
            provider.loadObject(ofClass: UIImage.self) { object, _ in
                guard let image = object as? UIImage else { return }
                Task { @MainActor in
                    self.parent.onImage(image)
                }
            }
        }
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
                isInEffect: effectiveScheme == .light,
                onSelect: { env.settings.setAppearanceMode(.light) }
            )
            AppearancePreviewCard(
                tokens: palette.tokens(for: .dark),
                title: "深色",
                isInEffect: effectiveScheme == .dark,
                onSelect: { env.settings.setAppearanceMode(.dark) }
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
    let onSelect: () -> Void

    var body: some View {
        Button(action: onSelect) {
            card
        }
        .buttonStyle(.plain)
        .accessibilityHint("轻点切换到\(title)外观")
    }

    private var card: some View {
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
        case .onyx:
            return [
                Color(red: 0.46, green: 0.48, blue: 0.51),
                Color(red: 0.24, green: 0.25, blue: 0.28),
                Color(red: 0.10, green: 0.11, blue: 0.12)
            ]
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
