//
//  AppServices.swift
//  Vela
//
//  The services one process shares between windows.
//
//  A browser window is not an app: history, bookmarks, downloads, settings and
//  the database are the same facts whichever Stage Manager window is asking.
//  What is window-scoped is the *session* — its tabs, its web views, its
//  dialogs, its permission prompts — and `AppEnvironment` owns that half. This
//  object owns the shared half and boots it exactly once.
//

import Foundation
import WebKit

@MainActor
public final class AppServices {
    public let database: BrowserDatabase
    public let settings: SettingsService
    public let bookmarks: BookmarkService
    /// The home's favourites shelf. Independent of the bookmark store: a
    /// favourite is a copy of a name and address, so bookmark edits and
    /// deletions cannot reach it.
    public let homeFavorites: HomeFavoritesService
    public let history: HistoryService
    public let downloads: DownloadService
    /// The process-wide record of site-permission answers.
    public let permissionAudit: PermissionAuditService
    public let searchHistory: SearchHistoryRepository
    /// The low-level script table, used by the web engine's injection path.
    public let userScriptRepository: UserScriptRepository
    /// Install, edit and update operations, shared with the manager screen.
    public let userScripts: UserScriptService
    public let tabSessions: TabSessionRepository
    /// The novel shelf: books, cached chapters and reading positions.
    public let novels: NovelLibraryService
    /// The password vault. Credentials live in the Keychain, not in the
    /// database; this service owns the lock and the page scripts.
    public let passwords: PasswordVaultService
    /// The offline shelf: saved page archives and their metadata.
    public let offlinePages: OfflinePageService
    /// The keyboard commands' dispatch point, shared by every window because
    /// the app's `Commands` menu is a property of the app.
    public let commands: BrowserCommandCenter
    /// Crashes and hangs reported by MetricKit, plus the last uncaught
    /// exception reason. This is process-wide, like the rest of the services.
    public let crashDiagnostics: CrashDiagnosticsService
    /// 广告拦截: the built-in filter list and the sites it leaves alone.
    public let contentBlocker: ContentBlocker

    /// Set when the database could not be opened. Every window shows the same
    /// error, because there is only one database.
    public private(set) var startupError: String?

    private var didBoot = false
    private var allocatedWindowCount = 0

    public init() {
        let database = BrowserDatabase.shared
        self.database = database

        let settings = SettingsService()
        self.settings = settings
        self.homeFavorites = HomeFavoritesService()
        self.commands = BrowserCommandCenter()
        self.crashDiagnostics = CrashDiagnosticsService()
        self.contentBlocker = ContentBlocker(settings: settings)
        self.permissionAudit = PermissionAuditService()

        // The picture used to belong to the home alone; it is the shell's
        // background now. Carrying it over at launch keeps the picture an
        // existing install already chose instead of asking again.
        if settings.preferences.backgroundImageStamp == nil,
           let stamp = BackgroundImageStore.adoptLegacyHomeImage() {
            settings.update { preferences in
                preferences.backgroundImageStamp = stamp
                preferences.homeBackgroundStamp = nil
            }
        }

        // The database open is the one operation allowed to fail loudly: every
        // other service reads through it, so a failure has to be reported once
        // and surfaced, not swallowed per-call.
        var connection: SQLiteDatabase?
        do {
            connection = try database.open()
        } catch {
            connection = nil
            self.startupError = error.localizedDescription
        }

        // A failure here leaves the repositories unusable, so they are built
        // against a best-effort connection and every call site already treats a
        // thrown error as a no-op write.
        let safeConnection = connection ?? (try! SQLiteDatabase(path: ":memory:"))

        let bookmarkRepository = BookmarkRepository(database: safeConnection)
        let historyRepository = HistoryRepository(database: safeConnection)
        let downloadRepository = DownloadRepository(database: safeConnection)

        self.searchHistory = SearchHistoryRepository(database: safeConnection)
        let userScriptRepository = UserScriptRepository(database: safeConnection)
        self.userScriptRepository = userScriptRepository
        self.userScripts = UserScriptService(
            repository: userScriptRepository,
            settings: settings
        )

        let bookmarks = BookmarkService(repository: bookmarkRepository)
        let history = HistoryService(repository: historyRepository, settings: settings)
        let downloads = DownloadService(repository: downloadRepository, settings: settings)

        self.bookmarks = bookmarks
        self.history = history
        self.downloads = downloads

        let sessionRepository = TabSessionRepository(database: safeConnection)
        self.tabSessions = sessionRepository

        let novelRepository = NovelRepository(database: safeConnection)
        self.novels = NovelLibraryService(repository: novelRepository)
        self.passwords = PasswordVaultService(settings: settings)
        self.offlinePages = OfflinePageService(
            repository: OfflinePageRepository(database: safeConnection)
        )
    }

    /// Hands out the identifier a new window's session is stored under.
    ///
    /// The first window of a launch is `window-main`, which is the session that
    /// survives a relaunch. Windows opened beside it in Stage Manager get a
    /// fresh identifier: they own their tabs while they are open, and their
    /// session is cleared at the next launch rather than restored into the
    /// first window. `bootOnce` does that clearing.
    public func allocateWindowId() -> String {
        if allocatedWindowCount == 0 {
            allocatedWindowCount = 1
            return TabSessionRepository.defaultWindowId
        }
        allocatedWindowCount += 1
        return "window-\(UUID().uuidString.lowercased())"
    }

    /// Startup work that must happen once for the process, not once per window.
    public func bootOnce() {
        guard !didBoot else { return }
        didBoot = true

        bookmarks.reload()
        // The home's shelf used to be bookmark ids; carry the grid an existing
        // install already had into the independent store exactly once.
        homeFavorites.reload()
        homeFavorites.migrateFromLegacyHomeStoreIfNeeded(
            bookmarks: bookmarks.bookmarkNodesInTreeOrder()
        )
        history.reload()
        downloads.reload()
        // Background URLSession events can arrive before the first window is
        // built; the registry needs its reconnector in place before that, and
        // the manifests on disk are what a relaunch resumes from.
        downloads.prepareBackgroundSessionReconnection()
        downloads.reconcileInterruptedTasks()
        userScripts.reload()
        if settings.userScriptSettings.autoUpdateEnabled {
            // Off the launch path: the first window must not wait on the
            // network, and a failed check is only a status line.
            let service = userScripts
            Task {
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                await service.autoUpdateIfNeeded()
            }
        }

        // Only the main window's session survives a relaunch. Any other
        // window ids are records of a Stage Manager session that no longer
        // exists, and restoring them later would duplicate another window's
        // tabs into the first one.
        try? tabSessions.removeSessions(except: [TabSessionRepository.defaultWindowId])

        // The rule list is compiled once; the first pages of the session may
        // be built before it is ready, and the environment re-attaches it when
        // `onChange` fires.
        contentBlocker.prepare()
    }

    /// Removes WebKit's browsing data, after the caller has already cleared
    /// whichever database rows it asked about.
    ///
    /// This method owns no database work on purpose: its one caller decides
    /// per-toggle what rows to remove, and an unconditional whole-database
    /// erase here is what wiped bookmarks and the open tab session even when
    /// the user had asked only to clear cookies and cache. History and
    /// bookmarks are reloaded afterwards so the list screens re-read
    /// whatever the caller removed.
    public func clearAllBrowsingData(includeWebKitData: Bool = true) async {
        history.reload()
        bookmarks.reload()

        if includeWebKitData {
            let store = WKWebsiteDataStore.default()
            let types = WKWebsiteDataStore.allWebsiteDataTypes()
            await withCheckedContinuation { continuation in
                store.removeData(ofTypes: types, modifiedSince: Date(timeIntervalSince1970: 0)) {
                    continuation.resume()
                }
            }
        }
    }
}
