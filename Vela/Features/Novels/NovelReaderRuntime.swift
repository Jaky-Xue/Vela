//
//  NovelReaderRuntime.swift
//  Vela
//
//  The reader's cancellable work, owned by the session rather than by the view.
//
//  Loaders used to live in `NovelReaderView` as `@State`. That made their
//  lifetime depend on SwiftUI removing the view, so an ended private session
//  could still have chapter/TOC work running while its database was retired.
//  The session owns this object instead: the environment's synchronous
//  "will end" hook cancels both loaders and drops the shelf reference before it
//  closes tabs or the WebKit store.
//

import Foundation

@MainActor
final class NovelReaderRuntime {
    let chapterLoader = NovelChapterLoader()
    let tocLoader = NovelTOCLoader()

    /// Weak on purpose. The session and the environment own the shelf; the
    /// reader only borrows it. Once both release it, the in-memory database
    /// can deinitialize even if a stale SwiftUI view is still finishing a
    /// frame.
    private(set) weak var library: NovelLibraryService?

    init(library: NovelLibraryService) {
        self.library = library
    }

    /// Stops in-flight work and releases the reader's claim on the shelf.
    /// Idempotent; safe to call from `onDisappear` and from the session-end
    /// hook in either order.
    func cancel() {
        chapterLoader.cancel()
        tocLoader.cancel()
        library = nil
    }
}
