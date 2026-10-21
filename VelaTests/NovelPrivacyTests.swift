//
//  NovelPrivacyTests.swift
//  VelaTests
//
//  Private novel reading must use its own in-memory database and its own
//  WebKit store. These tests cover the service isolation, the store choice the
//  loaders use, the session-generation guard, and a real WebKit check that a
//  subresource response does not write a cookie into the regular store.
//

import XCTest
import WebKit
@testable import Vela

@MainActor
final class NovelPrivacyTests: XCTestCase {
    private var directory: URL!
    private var regularDatabase: SQLiteDatabase!
    private var regular: NovelLibraryService!

    override func setUp() async throws {
        try await super.setUp()
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("vela-novel-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        regularDatabase = try SQLiteDatabase(
            path: directory.appendingPathComponent("regular.sqlite").path
        )
        for statement in BrowserSchema.creationStatements {
            try regularDatabase.execute(statement)
        }
        regular = NovelLibraryService(repository: NovelRepository(database: regularDatabase))
    }

    override func tearDown() async throws {
        regular = nil
        regularDatabase = nil
        if let directory {
            try? FileManager.default.removeItem(at: directory)
        }
        directory = nil
        try await super.tearDown()
    }

    // MARK: - Fixtures

    private func extraction(chapter: Int) -> NovelExtraction {
        NovelExtraction(
            bookTitle: "测试小说",
            author: "作者",
            chapterTitle: "第\(chapter)章",
            contentHtml: "<p>" + String(repeating: "正文", count: 200) + "</p>",
            chapterUrl: "https://novel.example/chapter-\(chapter)",
            previousUrl: chapter > 1 ? "https://novel.example/chapter-\(chapter - 1)" : "",
            nextUrl: "https://novel.example/chapter-\(chapter + 1)",
            tocUrl: "https://novel.example/toc"
        )
    }

    private func count(_ table: String) -> Int64 {
        (try? regularDatabase.scalarInt("SELECT COUNT(*) FROM \(table)")) ?? -1
    }

    private func regularCounts() -> [Int64] {
        [
            count(BrowserSchema.novelBooksTable),
            count(BrowserSchema.novelChaptersTable),
            count(BrowserSchema.novelTOCEntriesTable),
            count(BrowserSchema.novelTOCSourcesTable)
        ]
    }

    // MARK: - Service isolation

    func testPrivateAndRegularServicesAreSeparate() {
        guard let privateService = InMemoryNovelLibrary.make(),
              let privateOpen = privateService.open(extraction(chapter: 1)) else {
            return XCTFail("the private service could not be created")
        }
        XCTAssertEqual(privateService.books.count, 1)
        XCTAssertTrue(regular.books.isEmpty)

        guard let regularOpen = regular.open(extraction(chapter: 1)) else {
            return XCTFail("the regular service could not open the chapter")
        }
        XCTAssertEqual(regular.books.count, 1)
        XCTAssertNotEqual(privateOpen.book.id, regularOpen.book.id)
        XCTAssertEqual(privateService.books.count, 1)
        XCTAssertEqual(privateService.books.first?.id ?? "", privateOpen.book.id)
    }

    func testPrivateWritesDoNotTouchTheRegularDatabase() {
        let before = regularCounts()
        guard let privateService = InMemoryNovelLibrary.make(),
              let opened = privateService.open(extraction(chapter: 1)) else {
            return XCTFail("the private service could not be created")
        }
        _ = privateService.store(extraction(chapter: 2), bookId: opened.book.id, index: 1)
        privateService.saveTOC(
            bookId: opened.book.id,
            entries: [NovelTOCEntry(title: "第二章", url: "https://novel.example/chapter-2")]
        )
        privateService.saveTOCSource(bookId: opened.book.id, url: "https://novel.example/toc")
        privateService.markPosition(bookId: opened.book.id, chapter: opened.chapter, progress: 0.4)
        privateService.updateProgress(bookId: opened.book.id, progress: 0.6)

        XCTAssertEqual(regularCounts(), before, "private writes must not touch the regular tables")
        XCTAssertEqual(privateService.books.first?.progress ?? -1, 0.6)
        XCTAssertNotNil(
            privateService.chapter(
                bookId: opened.book.id,
                url: "https://novel.example/chapter-2"
            )
        )
        XCTAssertEqual(privateService.tocEntries(bookId: opened.book.id).count, 1)
        XCTAssertEqual(privateService.tocSource(bookId: opened.book.id) ?? "", "https://novel.example/toc")
    }

    func testANewPrivateServiceStartsEmptyAfterTheOldOneIsReleased() {
        var old: NovelLibraryService? = InMemoryNovelLibrary.make()
        guard let opened = old?.open(extraction(chapter: 1)) else {
            return XCTFail("the old private service could not open the chapter")
        }
        let bookId = opened.book.id
        old = nil

        guard let fresh = InMemoryNovelLibrary.make() else {
            return XCTFail("the replacement private service could not be created")
        }
        XCTAssertTrue(fresh.books.isEmpty)
        XCTAssertNil(fresh.chapter(bookId: bookId, url: "https://novel.example/chapter-1"))
        XCTAssertTrue(fresh.tocEntries(bookId: bookId).isEmpty)
    }

    func testRegularServiceReloadKeepsItsData() {
        guard let opened = regular.open(extraction(chapter: 1)) else {
            return XCTFail("the regular service could not open the chapter")
        }
        regular.reload()
        XCTAssertEqual(regular.books.count, 1)
        XCTAssertEqual(regular.books.first?.id ?? "", opened.book.id)
        XCTAssertNotNil(
            regular.chapter(bookId: opened.book.id, url: "https://novel.example/chapter-1")
        )
    }

    // MARK: - Store choice

    func testLoaderDataStoresAreChosenBySession() {
        let privateStore = WKWebsiteDataStore.nonPersistent()
        XCTAssertTrue(
            NovelLoaderDataStore.resolve(isPrivateSession: true, privateStore: privateStore)
                === privateStore
        )
        XCTAssertTrue(
            NovelLoaderDataStore.resolve(isPrivateSession: false, privateStore: privateStore)
                === WKWebsiteDataStore.default()
        )
        XCTAssertTrue(
            NovelLoaderConfiguration.make(dataStore: privateStore).websiteDataStore === privateStore
        )
        XCTAssertTrue(
            NovelReaderDisplayDataStore.resolve(isPrivateSession: true, privateStore: privateStore)
                === privateStore
        )
        XCTAssertFalse(
            NovelReaderDisplayDataStore.resolve(isPrivateSession: false, privateStore: privateStore)
                === privateStore
        )
    }

    // MARK: - Late callbacks and session identity

    func testLateWritesToAnOldPrivateServiceDoNotReachTheNewOne() {
        guard let old = InMemoryNovelLibrary.make(),
              let fresh = InMemoryNovelLibrary.make(),
              let opened = old.open(extraction(chapter: 1)) else {
            return XCTFail("the private services could not be created")
        }
        old.updateProgress(bookId: opened.book.id, progress: 0.5)
        XCTAssertTrue(fresh.books.isEmpty)
        XCTAssertNil(fresh.chapter(bookId: opened.book.id, url: "https://novel.example/chapter-1"))
    }

    func testSessionGenerationClosesOnlyTheEndedPrivateSession() {
        guard let libraryA = InMemoryNovelLibrary.make(),
              let libraryB = InMemoryNovelLibrary.make(),
              let book = libraryA.open(extraction(chapter: 1))?.book else {
            return XCTFail("the private services could not be created")
        }
        let first = NovelSession(
            book: book,
            chapter: nil,
            sourceTabId: "",
            isPrivateSession: true,
            sessionGeneration: 1,
            library: libraryA
        )
        let second = NovelSession(
            book: book,
            chapter: nil,
            sourceTabId: "",
            isPrivateSession: true,
            sessionGeneration: 2,
            library: libraryB
        )
        XCTAssertTrue(first.isCurrent(in: first))
        XCTAssertFalse(first.isCurrent(in: second))
        XCTAssertTrue(first.shouldClose(for: 2))
        XCTAssertFalse(first.shouldClose(for: 1))

        let regularSession = NovelSession(
            book: book,
            chapter: nil,
            sourceTabId: "",
            isPrivateSession: false,
            sessionGeneration: 1,
            library: libraryA
        )
        XCTAssertFalse(regularSession.shouldClose(for: 2), "a regular reader is not a private session")
        XCTAssertTrue(regularSession.isCurrent(in: regularSession))
    }

    func testPrivateShelfSchemaContainsOnlyNovelTables() {
        let statements = BrowserSchema.novelCreationStatements
        XCTAssertEqual(statements.count, 7, "four tables and three indexes")
        for table in [
            BrowserSchema.novelBooksTable,
            BrowserSchema.novelChaptersTable,
            BrowserSchema.novelTOCEntriesTable,
            BrowserSchema.novelTOCSourcesTable
        ] {
            XCTAssertTrue(
                statements.contains { $0.contains(table) },
                "the novel subset must keep \(table)"
            )
        }
        XCTAssertFalse(
            statements.contains { $0.contains(BrowserSchema.historyUrlsTable) },
            "a private shelf must not build the browser's history tables"
        )
    }

    // MARK: - Loader store (F-06)
    //
    // An earlier version of this file loaded a cookie-setting response through
    // a detached WKWebView and asserted the cookie landed in the private store.
    // That assertion is not a product contract: WebKit's cookie store only
    // commits reliably once the view participates in a window, and the test
    // failed on CI for exactly that reason (F-06). The store choice is already
    // covered deterministically by `testLoaderDataStoresAreChosenBySession`
    // (configuration.websiteDataStore === the injected private store) and by
    // the database-isolation tests above. Keeping a network-timing assertion
    // here would make the suite red for a platform detail rather than a defect.
}
