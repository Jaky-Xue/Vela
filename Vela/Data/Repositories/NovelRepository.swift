//
//  NovelRepository.swift
//  Vela
//
//  Persistence for the novel shelf.
//
//  Books and chapters are separate tables because their lifetimes differ: the
//  shelf keeps a book until the user deletes it, while chapter bodies are a
//  cache and are pruned per book. The composite key on (book_id, url) makes a
//  re-fetch of the same chapter an update rather than a duplicate.
//

import Foundation

public final class NovelRepository: @unchecked Sendable {
    private let database: SQLiteDatabase

    public init(database: SQLiteDatabase) {
        self.database = database
    }

    /// Releases the SQLite handle. A retired private shelf uses this once no
    /// reader can still reach it; ordinary shelves live for the process and do
    /// not need to call it.
    public func close() {
        database.close()
    }

    private static let bookColumns = """
    id, title, author, source_url, current_chapter_url, current_chapter_title, \
    chapter_index, progress, added_at, updated_at, last_read_at
    """

    private static let chapterColumns = """
    book_id, url, chapter_index, title, content_html, previous_url, next_url, fetched_at
    """

    private func book(from statement: SQLiteStatement) -> NovelBook {
        NovelBook(
            id: statement.string(at: 0),
            title: statement.string(at: 1),
            author: statement.string(at: 2),
            sourceUrl: statement.string(at: 3),
            currentChapterUrl: statement.string(at: 4),
            currentChapterTitle: statement.string(at: 5),
            chapterIndex: Int(statement.int(at: 6)),
            progress: statement.double(at: 7),
            addedAt: Date(milliseconds: statement.int(at: 8)),
            updatedAt: Date(milliseconds: statement.int(at: 9)),
            lastReadAt: Date(milliseconds: statement.int(at: 10))
        )
    }

    private func chapter(from statement: SQLiteStatement) -> NovelChapter {
        NovelChapter(
            bookId: statement.string(at: 0),
            index: Int(statement.int(at: 2)),
            url: statement.string(at: 1),
            title: statement.string(at: 3),
            contentHtml: statement.string(at: 4),
            previousUrl: statement.string(at: 5),
            nextUrl: statement.string(at: 6),
            fetchedAt: Date(milliseconds: statement.int(at: 7))
        )
    }

    // MARK: - Books

    public func allBooks() throws -> [NovelBook] {
        try database.query(
            """
            SELECT \(Self.bookColumns) FROM \(BrowserSchema.novelBooksTable)
            ORDER BY last_read_at DESC, updated_at DESC
            """,
            row: book(from:)
        )
    }

    public func book(id: String) throws -> NovelBook? {
        try database.query(
            "SELECT \(Self.bookColumns) FROM \(BrowserSchema.novelBooksTable) WHERE id = ?",
            [.text(id)],
            row: book(from:)
        ).first
    }

    public func upsert(_ book: NovelBook) throws {
        try database.execute(
            """
            INSERT OR REPLACE INTO \(BrowserSchema.novelBooksTable) (\(Self.bookColumns))
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """,
            [
                .text(book.id),
                .text(book.title),
                .text(book.author),
                .text(book.sourceUrl),
                .text(book.currentChapterUrl),
                .text(book.currentChapterTitle),
                .integer(Int64(book.chapterIndex)),
                .real(book.progress),
                .integer(book.addedAt.milliseconds),
                .integer(book.updatedAt.milliseconds),
                .integer(book.lastReadAt.milliseconds)
            ]
        )
    }

    /// Removes a book and every chapter cached for it.
    public func remove(id: String) throws {
        try database.transaction {
            try database.execute(
                "DELETE FROM \(BrowserSchema.novelChaptersTable) WHERE book_id = ?",
                [.text(id)]
            )
            try database.execute(
                "DELETE FROM \(BrowserSchema.novelTOCEntriesTable) WHERE book_id = ?",
                [.text(id)]
            )
            try database.execute(
                "DELETE FROM \(BrowserSchema.novelTOCSourcesTable) WHERE book_id = ?",
                [.text(id)]
            )
            try database.execute(
                "DELETE FROM \(BrowserSchema.novelBooksTable) WHERE id = ?",
                [.text(id)]
            )
        }
    }

    // MARK: - Chapters

    public func chapters(bookId: String) throws -> [NovelChapter] {
        try database.query(
            """
            SELECT \(Self.chapterColumns) FROM \(BrowserSchema.novelChaptersTable)
            WHERE book_id = ? ORDER BY chapter_index ASC, fetched_at ASC
            """,
            [.text(bookId)],
            row: chapter(from:)
        )
    }

    public func chapter(bookId: String, url: String) throws -> NovelChapter? {
        try database.query(
            """
            SELECT \(Self.chapterColumns) FROM \(BrowserSchema.novelChaptersTable)
            WHERE book_id = ? AND url = ?
            """,
            [.text(bookId), .text(url)],
            row: chapter(from:)
        ).first
    }

    public func chapter(bookId: String, index: Int) throws -> NovelChapter? {
        try database.query(
            """
            SELECT \(Self.chapterColumns) FROM \(BrowserSchema.novelChaptersTable)
            WHERE book_id = ? AND chapter_index = ?
            ORDER BY fetched_at DESC LIMIT 1
            """,
            [.text(bookId), .integer(Int64(index))],
            row: chapter(from:)
        ).first
    }

    public func upsertChapter(_ chapter: NovelChapter) throws {
        try database.execute(
            """
            INSERT OR REPLACE INTO \(BrowserSchema.novelChaptersTable) (\(Self.chapterColumns))
            VALUES (?, ?, ?, ?, ?, ?, ?, ?)
            """,
            [
                .text(chapter.bookId),
                .text(chapter.url),
                .integer(Int64(chapter.index)),
                .text(chapter.title),
                .text(chapter.contentHtml),
                .text(chapter.previousUrl),
                .text(chapter.nextUrl),
                .integer(chapter.fetchedAt.milliseconds)
            ]
        )
    }

    /// Keeps the most recently fetched `keep` chapters of one book.
    ///
    /// Chapters are stored because the reader needs them again; a whole book is
    /// still hundreds of chapters, and nothing is lost by forgetting the ones
    /// the user has not touched since. The current chapter is always recent
    /// enough to survive.
    public func pruneChapters(bookId: String, keep: Int = 60) throws {
        try database.execute(
            """
            DELETE FROM \(BrowserSchema.novelChaptersTable)
            WHERE book_id = ?
              AND url NOT IN (
                SELECT url FROM \(BrowserSchema.novelChaptersTable)
                WHERE book_id = ? ORDER BY fetched_at DESC LIMIT ?
              )
            """,
            [.text(bookId), .text(bookId), .integer(Int64(keep))]
        )
    }
}

// MARK: - Table of contents

extension NovelRepository {
    /// Remembers where this book's TOC page lives.
    public func saveTOCSource(bookId: String, tocUrl: String) throws {
        guard !tocUrl.isEmpty else { return }
        try database.execute(
            """
            INSERT OR REPLACE INTO \(BrowserSchema.novelTOCSourcesTable)
            (book_id, toc_url, fetched_at) VALUES (?, ?, ?)
            """,
            [.text(bookId), .text(tocUrl), .integer(Date().milliseconds)]
        )
    }

    public func tocSource(bookId: String) -> String? {
        try? database.query(
            "SELECT toc_url FROM \(BrowserSchema.novelTOCSourcesTable) WHERE book_id = ?",
            [.text(bookId)]
        ) { $0.string(at: 0) }.first
    }

    /// Replaces a book's TOC in one transaction; a re-read must not leave a
    /// mix of old and new positions.
    public func replaceTOC(bookId: String, entries: [NovelTOCEntry]) throws {
        try database.transaction {
            try database.execute(
                "DELETE FROM \(BrowserSchema.novelTOCEntriesTable) WHERE book_id = ?",
                [.text(bookId)]
            )
            for (position, entry) in entries.enumerated() {
                try database.execute(
                    """
                    INSERT OR REPLACE INTO \(BrowserSchema.novelTOCEntriesTable)
                    (book_id, url, title, position) VALUES (?, ?, ?, ?)
                    """,
                    [.text(bookId), .text(entry.url), .text(entry.title), .integer(Int64(position))]
                )
            }
        }
    }

    public func toc(bookId: String) -> [NovelTOCEntry] {
        (try? database.query(
            """
            SELECT title, url FROM \(BrowserSchema.novelTOCEntriesTable)
            WHERE book_id = ? ORDER BY position ASC
            """,
            [.text(bookId)]
        ) { NovelTOCEntry(title: $0.string(at: 0), url: $0.string(at: 1)) }) ?? []
    }
}
