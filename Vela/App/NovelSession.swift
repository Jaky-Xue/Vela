import SwiftUI
import UIKit
import WebKit

// MARK: - Novel session

/// What the shell's novel layer is showing.
///
/// The chapter is optional because a book opened from the shelf may have had
/// its cached chapter pruned; the reader then loads `book.currentChapterUrl`
/// itself. The identity is the session's, not the book's, so opening the same
/// book again after a position change still rebuilds the layer.
struct NovelSession: Identifiable, Equatable {
    let id = UUID()
    var book: NovelBook
    var chapter: NovelChapter?
    /// The tab the reader was opened from. A private reader's "open in
    /// browser" uses it as the only allowed existing target.
    let sourceTabId: String
    /// Whether this reader was opened from a private tab. The shelf and the
    /// chapter/TOC loaders are chosen from this at presentation time.
    let isPrivateSession: Bool
    /// The environment's private-session generation when the reader opened.
    /// A later end bumps the environment; this reader is then stale.
    let sessionGeneration: Int
    /// The shelf this session owns. It stays here so a reader opened from this
    /// session keeps using this database, never the one a newer session makes;
    /// the reader itself only gets a weak reference through `runtime`.
    let library: NovelLibraryService
    /// The reader's cancellable work, owned by the session so the synchronous
    /// session-end hook can stop it before tabs and the store are torn down.
    let runtime: NovelReaderRuntime

    @MainActor
    init(
        book: NovelBook,
        chapter: NovelChapter?,
        sourceTabId: String,
        isPrivateSession: Bool,
        sessionGeneration: Int,
        library: NovelLibraryService
    ) {
        self.book = book
        self.chapter = chapter
        self.sourceTabId = sourceTabId
        self.isPrivateSession = isPrivateSession
        self.sessionGeneration = sessionGeneration
        self.library = library
        self.runtime = NovelReaderRuntime(library: library)
    }

    static func == (lhs: NovelSession, rhs: NovelSession) -> Bool {
        lhs.id == rhs.id
    }

    /// Whether a close request from this session still refers to the session
    /// on screen. A late close from an old reader must not dismiss a new one.
    func isCurrent(in current: NovelSession?) -> Bool {
        current?.id == id
    }

    /// Whether this session must close because its private generation changed.
    /// A regular reader always answers false.
    func shouldClose(for generation: Int) -> Bool {
        isPrivateSession && sessionGeneration != generation
    }
}

