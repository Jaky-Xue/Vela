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
    /// Builds the shelf's SQLite handle and schema off the main actor.
    ///
    /// The service itself is main-actor state, but opening the connection and
    /// running the seven novel DDL statements are not: doing them in a detached
    /// task keeps the first private-shelf open from occupying a main-thread
    /// frame. The session generation is checked by the caller after the await.
    static func makeAsync() async -> NovelLibraryService? {
        let database = await Task.detached(priority: .utility) { () -> SQLiteDatabase? in
            do {
                let database = try SQLiteDatabase(path: ":memory:")
                for statement in BrowserSchema.novelCreationStatements {
                    try database.execute(statement)
                }
                return database
            } catch {
                return nil
            }
        }.value
        guard let database else { return nil }
        let service = NovelLibraryService(repository: NovelRepository(database: database))
        guard service.lastError == nil else {
            database.close()
            return nil
        }
        return service
    }

    /// Synchronous variant used by tests that do not have a running main actor
    /// suspension. The app uses `makeAsync`.
    static func make() -> NovelLibraryService? {
        do {
            let database = try SQLiteDatabase(path: ":memory:")
            // Only the novel tables: the full schema creates bookmarks,
            // history and downloads the private shelf never reads.
            for statement in BrowserSchema.novelCreationStatements {
                try database.execute(statement)
            }
            let service = NovelLibraryService(repository: NovelRepository(database: database))
            // The schema can be created and the first query still fail (a
            // corrupt handle, an unavailable page cache). Returning a service
            // with a published error would make a private shelf look empty
            // rather than broken; the caller's nil path reports it instead.
            guard service.lastError == nil else { return nil }
            return service
        } catch {
            return nil
        }
    }
}
