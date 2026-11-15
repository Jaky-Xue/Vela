import SwiftUI
import UIKit
import WebKit

// MARK: - Background picture

/// The custom global background picture, drawn behind the whole shell.
///
/// The picture is the shell's backdrop rather than a layer inside any one
/// surface: the home, the top bar and the surfaces around a page all sit on
/// it. Chrome keeps a separate palette surface for stable text contrast.
///
/// Its frame is set explicitly from the container's size, and the overflow is
/// clipped. A `scaledToFill` image on its own answers a layout query with the
/// aspect-fill size, which can be wider or taller than the window — and inside
/// the shell's ZStack that answer inflated the whole layout: the top bar was
/// proposed a width larger than the screen, its controls were centred on that
/// wider canvas, and the leading cluster and the menu fell outside the window.
/// That is why the bar broke only once a picture was set. The GeometryReader
/// gives the picture the container's exact size, so it can never grow the
/// shell to fit itself.
struct BackgroundPictureBackdrop: View {
    var stamp: Double
    @State private var image: UIImage?

    var body: some View {
        GeometryReader { geo in
            ZStack {
                Color(uiColor: .systemBackground)
                if let image {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                        .frame(width: geo.size.width, height: geo.size.height)
                        .clipped()
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
        .ignoresSafeArea()
        .task(id: stamp) {
            image = BackgroundImageStore.load(stamp: stamp)
        }
        .accessibilityHidden(true)
    }
}

