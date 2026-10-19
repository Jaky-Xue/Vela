//
//  NovelModels.swift
//  Vela
//
//  The shelf's vocabulary: a book, one chapter of it, and what an extraction
//  hands back from a live page.
//
//  A chapter is content the browser already fetched and cleaned, stored so a
//  revisit costs nothing and an interrupted session resumes at the same place.
//  The book record holds only where the reader stopped — the chapters table
//  holds everything it would need to show that paragraph again.
//

import Foundation

/// One novel on the shelf.
public struct NovelBook: Identifiable, Equatable, Sendable {
    public var id: String
    public var title: String
    public var author: String
    /// The page the book was added from, used when a chapter has no known
    /// neighbour and the reader has to go back to the source.
    public var sourceUrl: String
    public var currentChapterUrl: String
    public var currentChapterTitle: String
    /// A book-relative position. It is an ordering hint, not a table of
    /// contents: sites differ in how they number chapters, so the value counts
    /// the chapters this install has read rather than claiming an absolute
    /// chapter number.
    public var chapterIndex: Int
    /// Reading position inside the current chapter, 0...1.
    public var progress: Double
    public var addedAt: Date
    public var updatedAt: Date
    public var lastReadAt: Date

    public init(
        id: String = UUID().uuidString,
        title: String,
        author: String = "",
        sourceUrl: String = "",
        currentChapterUrl: String = "",
        currentChapterTitle: String = "",
        chapterIndex: Int = 0,
        progress: Double = 0,
        addedAt: Date = Date(),
        updatedAt: Date = Date(),
        lastReadAt: Date = Date()
    ) {
        self.id = id
        self.title = title
        self.author = author
        self.sourceUrl = sourceUrl
        self.currentChapterUrl = currentChapterUrl
        self.currentChapterTitle = currentChapterTitle
        self.chapterIndex = chapterIndex
        self.progress = progress
        self.addedAt = addedAt
        self.updatedAt = updatedAt
        self.lastReadAt = lastReadAt
    }

    /// A stable identity for matching a page against an existing shelf entry:
    /// the same title on the same host is the same book even when the chapter
    /// URL changed.
    public var matchKey: String {
        let host = URL(string: sourceUrl)?.host?.lowercased() ?? ""
        return "\(host)|\(title.trimmingCharacters(in: .whitespacesAndNewlines))"
    }
}

/// One chapter, extracted and stored.
public struct NovelChapter: Identifiable, Equatable, Sendable {
    public var bookId: String
    public var index: Int
    public var url: String
    public var title: String
    public var contentHtml: String
    public var previousUrl: String
    public var nextUrl: String
    public var fetchedAt: Date

    /// A chapter URL is unique within its book, which is exactly the identity
    /// the reader uses.
    public var id: String { url }

    public init(
        bookId: String,
        index: Int,
        url: String,
        title: String,
        contentHtml: String,
        previousUrl: String = "",
        nextUrl: String = "",
        fetchedAt: Date = Date()
    ) {
        self.bookId = bookId
        self.index = index
        self.url = url
        self.title = title
        self.contentHtml = contentHtml
        self.previousUrl = previousUrl
        self.nextUrl = nextUrl
        self.fetchedAt = fetchedAt
    }

    public var hasPrevious: Bool { !previousUrl.isEmpty }
    public var hasNext: Bool { !nextUrl.isEmpty }
}

/// One entry in a book's table of contents.
public struct NovelTOCEntry: Identifiable, Codable, Equatable, Sendable {
    public var title: String
    public var url: String

    /// A chapter URL is unique within a book's contents.
    public var id: String { url }

    public init(title: String, url: String) {
        self.title = title
        self.url = url
    }
}

/// What the extraction script returns for one chapter page.
public struct NovelExtraction: Equatable, Sendable {
    public var bookTitle: String
    public var author: String
    public var chapterTitle: String
    public var contentHtml: String
    public var chapterUrl: String
    public var previousUrl: String
    public var nextUrl: String
    /// The table-of-contents page when the site links one from the chapter.
    public var tocUrl: String

    public init(
        bookTitle: String,
        author: String,
        chapterTitle: String,
        contentHtml: String,
        chapterUrl: String,
        previousUrl: String = "",
        nextUrl: String = "",
        tocUrl: String = ""
    ) {
        self.bookTitle = bookTitle
        self.author = author
        self.chapterTitle = chapterTitle
        self.contentHtml = contentHtml
        self.chapterUrl = chapterUrl
        self.previousUrl = previousUrl
        self.nextUrl = nextUrl
        self.tocUrl = tocUrl
    }

    public var isEmpty: Bool {
        contentHtml.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }


    /// The same identity a shelf entry matches on: the chapter's host plus the
    /// book title. Used to decide whether a freshly opened page continues an
    /// existing book rather than creating a second one.
    public var matchKey: String {
        let host = URL(string: chapterUrl)?.host?.lowercased() ?? ""
        return "\(host)|\(bookTitle.trimmingCharacters(in: .whitespacesAndNewlines))"
    }
}

// MARK: - Page mode

/// The reading flow the user chose.
public enum NovelPageMode: String, CaseIterable, Identifiable, Sendable {
    case scroll
    case paged

    public var id: String { rawValue }
    public var displayName: String { self == .scroll ? "上下滚动" : "整屏翻页" }
    public var symbolName: String { self == .scroll ? "arrow.up.and.down" : "rectangle.portrait.and.arrow.right" }

    public static func resolve(_ raw: String?) -> NovelPageMode {
        guard let raw, let mode = NovelPageMode(rawValue: raw) else { return .scroll }
        return mode
    }
}
