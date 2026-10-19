//
//  NovelLibraryService.swift
//  Vela
//
//  The shelf's observable state: the books, where each was left, and the
//  chapter bodies behind it.
//
//  The service is the only thing that decides whether a page is a new book or
//  the next chapter of one already on the shelf — the identity is a title plus
//  a host, not a URL, because novel sites change chapter URLs constantly while
//  the book stays the same.
//

import Foundation
import Observation

@MainActor
@Observable
public final class NovelLibraryService {
    public private(set) var books: [NovelBook] = []
    public private(set) var lastError: String?

    private let repository: NovelRepository
    /// How many chapter bodies one book keeps.
    private let chapterCacheLimit = 60
    /// TOC lists are read on every reader body evaluation, so they are kept
    /// here rather than queried from SQLite each time.
    private var tocCache: [String: [NovelTOCEntry]] = [:]

    public init(repository: NovelRepository) {
        self.repository = repository
        reload()
    }

    public func reload() {
        do {
            books = try repository.allBooks()
            lastError = nil
        } catch {
            books = []
            lastError = error.localizedDescription
        }
    }

    public func book(id: String) -> NovelBook? {
        books.first { $0.id == id } ?? (try? repository.book(id: id))
    }

    // MARK: - Opening a page

    /// Files an extracted chapter under its book and returns the book and the
    /// stored chapter to read.
    ///
    /// Adding from the middle of a book is expected: 小说模式 is entered from
    /// whichever chapter the user is on. A page whose book is already on the
    /// shelf continues that book rather than creating a second one with the
    /// same title.
    public func open(_ extraction: NovelExtraction) -> (book: NovelBook, chapter: NovelChapter)? {
        guard !extraction.isEmpty else { return nil }

        let existing = books.first { $0.matchKey == extraction.matchKey }
        let bookId = existing?.id ?? UUID().uuidString

        let cached = try? repository.chapter(bookId: bookId, url: extraction.chapterUrl)
        let index: Int
        if let cached {
            index = cached.index
        } else if let existing {
            index = existing.currentChapterUrl == extraction.chapterUrl
                ? existing.chapterIndex
                : existing.chapterIndex + 1
        } else {
            index = 0
        }

        let chapter = NovelChapter(
            bookId: bookId,
            index: index,
            url: extraction.chapterUrl,
            title: extraction.chapterTitle,
            contentHtml: extraction.contentHtml,
            previousUrl: extraction.previousUrl,
            nextUrl: extraction.nextUrl
        )

        let now = Date()
        let book = NovelBook(
            id: bookId,
            title: extraction.bookTitle,
            author: extraction.author,
            sourceUrl: existing?.sourceUrl ?? extraction.chapterUrl,
            currentChapterUrl: extraction.chapterUrl,
            currentChapterTitle: extraction.chapterTitle,
            chapterIndex: index,
            // Re-opening the chapter you left keeps its place; anything else
            // starts at the top.
            progress: existing?.currentChapterUrl == extraction.chapterUrl ? (existing?.progress ?? 0) : 0,
            addedAt: existing?.addedAt ?? now,
            updatedAt: now,
            lastReadAt: now
        )

        do {
            try repository.upsertChapter(chapter)
            try repository.upsert(book)
            try repository.pruneChapters(bookId: bookId, keep: chapterCacheLimit)
            if !extraction.tocUrl.isEmpty {
                try repository.saveTOCSource(bookId: bookId, tocUrl: extraction.tocUrl)
            }
            reload()
            return (book, chapter)
        } catch {
            lastError = error.localizedDescription
            return nil
        }
    }

    /// The chapter a resumed book should open, if it is still cached.
    public func cachedChapter(book: NovelBook) -> NovelChapter? {
        guard !book.currentChapterUrl.isEmpty else { return nil }
        return try? repository.chapter(bookId: book.id, url: book.currentChapterUrl)
    }

    public func chapter(bookId: String, url: String) -> NovelChapter? {
        guard !url.isEmpty else { return nil }
        return try? repository.chapter(bookId: bookId, url: url)
    }

    public func chapter(bookId: String, index: Int) -> NovelChapter? {
        try? repository.chapter(bookId: bookId, index: index)
    }

    // MARK: - Reading

    /// Stores a newly loaded chapter at the given position in its book.
    @discardableResult
    public func store(_ extraction: NovelExtraction, bookId: String, index: Int) -> NovelChapter? {
        guard !extraction.isEmpty else { return nil }
        let chapter = NovelChapter(
            bookId: bookId,
            index: index,
            url: extraction.chapterUrl,
            title: extraction.chapterTitle,
            contentHtml: extraction.contentHtml,
            previousUrl: extraction.previousUrl,
            nextUrl: extraction.nextUrl
        )
        do {
            try repository.upsertChapter(chapter)
            try repository.pruneChapters(bookId: bookId, keep: chapterCacheLimit)
            if !extraction.tocUrl.isEmpty {
                try repository.saveTOCSource(bookId: bookId, tocUrl: extraction.tocUrl)
            }
            return chapter
        } catch {
            lastError = error.localizedDescription
            return chapter
        }
    }

    /// Records where the reader is. Called on a chapter change and on leaving
    /// the reader; scroll updates go through `updateProgress` instead.
    public func markPosition(bookId: String, chapter: NovelChapter, progress: Double) {
        guard var book = book(id: bookId) else { return }
        let now = Date()
        book.currentChapterUrl = chapter.url
        book.currentChapterTitle = chapter.title.isEmpty ? book.currentChapterTitle : chapter.title
        book.chapterIndex = chapter.index
        book.progress = min(max(progress, 0), 1)
        book.updatedAt = now
        book.lastReadAt = now
        persist(book)
    }

    public func updateProgress(bookId: String, progress: Double) {
        guard var book = book(id: bookId) else { return }
        book.progress = min(max(progress, 0), 1)
        book.updatedAt = Date()
        book.lastReadAt = Date()
        persist(book)
    }

    public func delete(bookId: String) {
        do {
            try repository.remove(id: bookId)
            tocCache.removeValue(forKey: bookId)
            reload()
        } catch {
            lastError = error.localizedDescription
        }
    }

    private func persist(_ book: NovelBook) {
        do {
            try repository.upsert(book)
            // Keep the in-memory list in the same order the shelf will be read
            // in, without a full database round-trip on every scroll tick.
            if let index = books.firstIndex(where: { $0.id == book.id }) {
                books[index] = book
            } else {
                books.insert(book, at: 0)
            }
            books.sort { $0.lastReadAt > $1.lastReadAt }
        } catch {
            lastError = error.localizedDescription
        }
    }
}

    // MARK: - Table of contents

    public func tocEntries(bookId: String) -> [NovelTOCEntry] {
        if let cached = tocCache[bookId] {
            return cached
        }
        let entries = repository.toc(bookId: bookId)
        tocCache[bookId] = entries
        return entries
    }

    public func tocSource(bookId: String) -> String? {
        repository.tocSource(bookId: bookId)
    }

    public func saveTOC(bookId: String, entries: [NovelTOCEntry]) {
        guard !entries.isEmpty else { return }
        try? repository.replaceTOC(bookId: bookId, entries: entries)
        tocCache[bookId] = entries
    }

    /// The TOC entry before or after a chapter URL, when a TOC is cached.
    ///
    /// This is what keeps the reader's previous/next controls alive on a
    /// chapter page that does not itself carry those links.
    public func tocNeighbor(
        bookId: String,
        url: String,
        offset: Int
    ) -> (entry: NovelTOCEntry, index: Int)? {
        let entries = tocEntries(bookId: bookId)
        guard let index = entries.firstIndex(where: { $0.url == url }) else { return nil }
        let target = index + offset
        guard entries.indices.contains(target) else { return nil }
        return (entries[target], target)
    }
