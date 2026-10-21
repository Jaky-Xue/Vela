//
//  InMemoryNovelLibrary.swift
//  Vela
//
//  A novel shelf whose database lives only in memory.
//
//  Private reading must not reach the durable novel tables. The cheapest way
//  to guarantee that is not a second implementation of the service but a
//  second SQLite connection to `:memory:` carrying the same schema: the
//  existing NovelLibraryService, NovelRepository and every query run
//  unchanged, and the database is released with the service. `SQLiteDatabase`
//  already supports `:memory:` (the test harness and the database-open
//  fallback both use it) and closes its handle in `deinit`.
//
//  The factory returns nil rather than falling back to the persistent
//  database: a private session that cannot create its own store must not
//  silently write into the regular profile.
//

import Foundation

@MainActor
enum InMemoryNovelLibrary {
    static func make() -> NovelLibraryService? {
        do {
            let database = try SQLiteDatabase(path: ":memory:")
            // Only the novel tables: the full schema creates bookmarks,
            // history and downloads the private shelf never reads.
            for statement in BrowserSchema.novelCreationStatements {
                try database.execute(statement)
            }
            return NovelLibraryService(repository: NovelRepository(database: database))
        } catch {
            return nil
        }
    }
}
