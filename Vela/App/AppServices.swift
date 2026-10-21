//
//  AppServices.swift
//  Vela
//
//  The services one process shares between windows.
//
//  A browser window is not an app: history, bookmarks, downloads, settings and
//  the database are the same facts whichever Stage Manager window is asking.
//  What is window-scoped is the *session* — its tabs, its web views, its
//  dialogs, its translation panel — and `AppEnvironment` owns that half. This
//  object owns the shared half and boots it exactly once.
//

import Foundation
import WebKit

@MainActor
public final class AppServices {
    public let database: BrowserDatabase
    public let settings: SettingsService
    public let bookmarks: BookmarkService
    public let history: HistoryService
    public let downloads: DownloadService
    public let adBlock: AdBlockEngine
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
        self.commands = BrowserCommandCenter()

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
        let adBlock = AdBlockEngine()

        self.bookmarks = bookmarks
        self.history = history
        self.downloads = downloads
        self.adBlock = adBlock

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

        // The built-in rule sources may not exist yet on a fresh install, so the
        // shipped catalogue is merged in before the first compile.
        seedAdBlockSources()

        Task { await refreshAdBlockRules() }

        // Only the main window's session survives a relaunch. Any other
        // window ids are records of a Stage Manager session that no longer
        // exists, and restoring them later would duplicate another window's
        // tabs into the first one.
        try? tabSessions.removeSessions(except: [TabSessionRepository.defaultWindowId])
    }

    // MARK: - Ad-blocking

    private func seedAdBlockSources() {
        var existing = settings.adBlockSettings.ruleSources
        var changed = false
        for source in AdBlockBuiltInRules.sources where !existing.contains(where: { $0.id == source.id }) {
            existing.append(source)
            changed = true
        }
        if changed {
            settings.update { $0.adBlock.ruleSources = existing }
        }
    }

    /// Compiles the enabled filter lists into a `WKContentRuleList`.
    ///
    /// Remote subscriptions are not fetched here: a launch must not block on the
    /// network, and a list that has never been downloaded simply contributes
    /// nothing until the user refreshes it. The built-in lists are always
    /// available because they ship in the binary.
    public func refreshAdBlockRules() async {
        let adBlockSettings = settings.adBlockSettings
        var filterLists: [String: String] = AdBlockBuiltInRules.filterLists

        // Any list the user has previously downloaded is read from disk.
        for source in adBlockSettings.ruleSources where source.sourceType == .remote {
            if let text = try? String(contentsOf: Self.filterListUrl(sourceId: source.id), encoding: .utf8) {
                filterLists[source.id] = text
            }
        }

        // Hand-written rules become their own source so they compile through the
        // same path as everything else.
        if !adBlockSettings.preferences.localRules.isEmpty {
            filterLists["local-rules"] = adBlockSettings.preferences.localRules.joined(separator: "\n")
        }

        let orderedIds = adBlockSettings.activeSources.map(\.id)
            + (adBlockSettings.preferences.localRules.isEmpty ? [] : ["local-rules"])

        let exceptedHosts = adBlockSettings.preferences.siteExceptions.map(\.host)

        do {
            _ = try await adBlock.compile(
                filterLists: filterLists,
                orderedSourceIds: orderedIds,
                exceptedHosts: exceptedHosts,
                includeCosmetic: adBlockSettings.preferences.cosmeticFilteringEnabled,
                enabled: adBlockSettings.preferences.enabled
            )
        } catch {
            // A compile failure leaves the previous list in place, which is the
            // correct fallback: the user keeps the blocking they had.
        }
    }

    /// Downloads a subscription and stores it.
    public func updateAdBlockSource(id: String) async {
        guard let source = settings.adBlockSettings.ruleSources.first(where: { $0.id == id }),
              let url = URL(string: source.url), !source.url.isEmpty else { return }

        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            guard let text = String(data: data, encoding: .utf8), !text.isEmpty else { return }
            try Self.writeFilterList(text, sourceId: id)

            settings.update { preferences in
                guard let index = preferences.adBlock.ruleSources.firstIndex(where: { $0.id == id }) else { return }
                preferences.adBlock.ruleSources[index].lastUpdatedAt = Date()
                preferences.adBlock.ruleSources[index].lastError = ""
                preferences.adBlock.ruleSources[index].ruleCount = text.split(whereSeparator: \.isNewline).count
            }
            await refreshAdBlockRules()
        } catch {
            settings.update { preferences in
                guard let index = preferences.adBlock.ruleSources.firstIndex(where: { $0.id == id }) else { return }
                preferences.adBlock.ruleSources[index].lastError = error.localizedDescription
            }
        }
    }

    // MARK: - Filter list storage

    /// Directory holding downloaded filter lists.
    ///
    /// rather than in the settings document for the same reason: a filter list
    /// is megabytes of text and has no business inside a preferences value.
    private static var filterListDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let directory = base.appendingPathComponent("Vela/FilterLists", isDirectory: true)
        if !FileManager.default.fileExists(atPath: directory.path) {
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        return directory
    }

    /// The rules a source contributes, as the text the compiler reads.
    ///
    /// System lists ship in the binary; a subscription's text is whatever was
    /// last downloaded. `nil` means there is nothing to show — a subscription
    /// that has never been fetched, or a name that no longer exists.
    public func adBlockRuleText(sourceId: String) -> String? {
        if let text = AdBlockBuiltInRules.filterLists[sourceId] {
            return text
        }
        guard let text = try? String(contentsOf: Self.filterListUrl(sourceId: sourceId), encoding: .utf8),
              !text.isEmpty else { return nil }
        return text
    }

    static func filterListUrl(sourceId: String) -> URL {
        let safe = sourceId.replacingOccurrences(of: "/", with: "_")
        return filterListDirectory.appendingPathComponent("\(safe).txt")
    }

    static func writeFilterList(_ text: String, sourceId: String) throws {
        try text.write(to: filterListUrl(sourceId: sourceId), atomically: true, encoding: .utf8)
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
