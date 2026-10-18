//
//  HomeSettingsView.swift
//  Vela
//
//  The home-surface settings: the custom background picture, chosen from the
//  photo library.
//
//  Three parts live here. `HomeBackgroundStore` owns the image file on disk —
//  the preferences document is UserDefaults JSON and no megabyte-sized bitmap
//  belongs in it, so the document carries only the file's timestamp and the
//  image itself lives in Application Support. `PhotoLibraryPicker` bridges
//  `PHPickerViewController`, which runs out of process and needs no photo
//  permission. `HomeSettingsView` is the screen that ties them together.
//

import SwiftUI
import UIKit
import PhotosUI

// MARK: - Store

/// The home background image on disk.
///
/// One file, one timestamp. The timestamp is what the settings document and
/// the home surface both key off: saving writes the file and hands back the
/// stamp, and a view reading `homeBackgroundStamp` reloads the image when the
/// stamp moves. The in-memory cache is keyed by the same stamp, so a screen
/// re-rendering for an unrelated reason re-reads nothing.
enum HomeBackgroundStore {
    /// Where the image lives. The directory follows the same shape as the
    /// filter-list store: Application Support, under the app's own folder.
    static var fileUrl: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let directory = base.appendingPathComponent("Vela", isDirectory: true)
        if !FileManager.default.fileExists(atPath: directory.path) {
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        return directory.appendingPathComponent("HomeBackground.jpg")
    }

    private static var cached: (stamp: Double, image: UIImage)?

    /// The image for a stamp, or nil when the file is gone. A stamp of nil
    /// means no background was ever saved.
    static func load(stamp: Double?) -> UIImage? {
        guard let stamp else { return nil }
        if let cached, cached.stamp == stamp { return cached.image }
        guard let image = UIImage(contentsOfFile: fileUrl.path) else { return nil }
        cached = (stamp, image)
        return image
    }

    /// Downscales, encodes and writes an image, returning the stamp that
    /// refers to it. A photo from the library is routinely 12 megapixels; the
    /// home surface never shows it larger than the screen, so the copy kept
    /// is capped at 2048 on its long edge and encoded as JPEG — a few hundred
    /// kilobytes instead of tens of megabytes.
    static func save(_ image: UIImage) -> Double? {
        let prepared = downscaled(image)
        guard let data = prepared.jpegData(compressionQuality: 0.85) else { return nil }
        do {
            try data.write(to: fileUrl, options: .atomic)
        } catch {
            return nil
        }
        let stamp = Date().timeIntervalSince1970
        cached = (stamp, prepared)
        return stamp
    }

    /// Removes the file and the cache. The stamp in the settings document is
    /// the caller's to clear, since that write belongs to the settings path.
    static func clear() {
        try? FileManager.default.removeItem(at: fileUrl)
        cached = nil
    }

    /// The image scaled so its long edge is at most 2048 points.
    private static func downscaled(_ image: UIImage) -> UIImage {
        let maxEdge: CGFloat = 2048
        let longEdge = max(image.size.width, image.size.height)
        guard longEdge > maxEdge, longEdge > 0 else { return image }

        let scale = maxEdge / longEdge
        let newSize = CGSize(width: image.size.width * scale, height: image.size.height * scale)
        let format = UIGraphicsImageRendererFormat.default()
        format.opaque = true
        return UIGraphicsImageRenderer(size: newSize, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: newSize))
        }
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

// MARK: - Screen

/// The home-surface settings screen.
struct HomeSettingsView: View {
    @Environment(AppEnvironment.self) private var env

    @State private var showPhotoPicker = false

    private var stamp: Double? {
        env.settings.preferences.homeBackgroundStamp
    }

    var body: some View {
        List {
            Section {
                if let image = HomeBackgroundStore.load(stamp: stamp) {
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
                    Label(stamp == nil ? "从相册选择图片" : "更换图片", systemImage: "photo")
                }

                if stamp != nil {
                    Button(role: .destructive) {
                        HomeBackgroundStore.clear()
                        env.settings.update { $0.homeBackgroundStamp = nil }
                    } label: {
                        Label("恢复默认背景", systemImage: "arrow.uturn.backward")
                    }
                }
            } header: {
                Text("主页背景")
            }

            Section {
                HStack {
                    Text("图标大小")
                    Spacer()
                    Text("\(Int(env.settings.preferences.homeTileIconSize ?? 40)) pt")
                        .font(.footnote.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                Slider(
                    value: Binding(
                        get: { env.settings.preferences.homeTileIconSize ?? 40 },
                        set: { newValue in
                            env.settings.update { $0.homeTileIconSize = newValue }
                        }
                    ),
                    in: 28...64,
                    step: 2
                )

                Picker("形状", selection: Binding(
                    get: { env.settings.preferences.homeTileShape ?? "rounded" },
                    set: { newValue in
                        env.settings.update { $0.homeTileShape = newValue }
                    }
                )) {
                    Text("圆角").tag("rounded")
                    Text("圆形").tag("circle")
                    Text("方角").tag("square")
                }
                .pickerStyle(.segmented)

                HStack {
                    Text("间距")
                    Spacer()
                    Text("\(Int(env.settings.preferences.homeTileSpacing ?? 12)) pt")
                        .font(.footnote.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                Slider(
                    value: Binding(
                        get: { env.settings.preferences.homeTileSpacing ?? 12 },
                        set: { newValue in
                            env.settings.update { $0.homeTileSpacing = newValue }
                        }
                    ),
                    in: 8...28,
                    step: 2
                )
            } header: {
                Text("收藏图标")
            } footer: {
                Text("改动即时生效，直接回到主页就能看到。")
            }
        }
        .navigationTitle("主页")
        .navigationBarTitleDisplayMode(.inline)
        .browserListSurface()
        .sheet(isPresented: $showPhotoPicker) {
            PhotoLibraryPicker { image in
                save(image)
            }
        }
    }

    /// Writes the image and records its stamp in one step. The home surface
    /// observes the stamp, so the change is live behind the settings sheet.
    private func save(_ image: UIImage) {
        guard let stamp = HomeBackgroundStore.save(image) else { return }
        env.settings.update { $0.homeBackgroundStamp = stamp }
    }
}
