import SwiftUI
import UIKit
import WebKit

extension BrowserShellView {
    func presentTabsOverview() {
        homePreview = nil
        homePreviewTabId = nil
        if let tab = activeTab, tab.isHome, let print = captureHomePreview() {
            homePreview = print
            homePreviewTabId = tab.id
        }
        withAnimation(BrowserMotion.overview(reduceMotion)) {
            showTabsOverview = true
        }
    }

    /// The visible home surface, without the status-bar strip or the command
    /// bar. Returns nil unless the active tab is the home.
    ///
    /// A private home is printed too: its card follows the same
    /// 无痕预览模糊 rule as a private page card, which is the protection the
    /// setting already promises. The print is held only while the overview is
    /// open.
    func captureHomePreview() -> UIImage? {
        guard let tab = activeTab, tab.isHome else {
            return nil
        }
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let activeScene = scenes.first { $0.activationState == .foregroundActive }
        let window = activeScene?.windows.first(where: \.isKeyWindow)
            ?? scenes.flatMap(\.windows).first(where: \.isKeyWindow)
            ?? scenes.flatMap(\.windows).first
        guard let window, window.bounds.width > 0, window.bounds.height > 0 else {
            return nil
        }

        let bounds = window.bounds
        // A snapshot view carries the window's visual effects (the glass
        // cards and the ambient background) into the renderer; drawing the
        // window hierarchy directly can drop them. The direct path stays as
        // the fallback for a window that has not rendered yet.
        let snapshot = window.snapshotView(afterScreenUpdates: false)
        let format = UIGraphicsImageRendererFormat(); format.scale = 1
        let renderer = UIGraphicsImageRenderer(bounds: bounds, format: format)
        let image = renderer.image { _ in
            if let snapshot {
                snapshot.frame = bounds
                snapshot.drawHierarchy(in: bounds, afterScreenUpdates: false)
            } else {
                window.drawHierarchy(in: bounds, afterScreenUpdates: false)
            }
        }
        guard let cg = image.cgImage else { return nil }

        let scale = CGFloat(cg.width) / max(bounds.width, 1)
        // The iPad layout puts its navigation at the top, so the bar is part
        // of the crop there; the phone's bar is the bottom clearance.
        let topChrome = usesPadLayout
            ? (chromeHidden ? 0 : padBarsHeight)
            : 0
        let topCrop = min(bounds.height * 0.4, max(0, safeTop + topChrome))
        let bottomCrop = min(bounds.height * 0.5, bottomChromeClearance + 16)
        let remaining = bounds.height - topCrop - bottomCrop
        guard remaining > 60 else { return image }

        let pixelRect = CGRect(
            x: 0,
            y: topCrop * scale,
            width: CGFloat(cg.width),
            height: remaining * scale
        )
        guard let cropped = cg.cropping(to: pixelRect) else { return image }
        return UIImage(cgImage: cropped, scale: scale, orientation: .up)
    }
}
