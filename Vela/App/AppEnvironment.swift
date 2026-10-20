//
//  AppEnvironment.swift
//  Vela
//
//  The composition root. Every service is constructed once here and injected
//  through the SwiftUI environment, so the dependency graph stays visible at
//  each call site instead of hiding behind a module-level singleton.
//
//  The environment is `@Observable` like every other service, but owns no state
//  beyond `startupError`. A view that reads `env.settings` tracks the settings
//  service itself: the Observation framework records the property each view
//  actually reads, however many hops down it sits, so nothing here forwards
//  change notifications.
//

import Foundation
import WebKit
import Observation

@MainActor
@Observable
public final class AppEnvironment {
    public let database: BrowserDatabase
    public let settings: SettingsService
    public let bookmarks: BookmarkService
    public let history: HistoryService
    public let downloads: DownloadService
    public let adBlock: AdBlockEngine
    public let tabManager: TabManager
    public let searchHistory: SearchHistoryRepository
    public let userScripts: UserScriptRepository
    public let tabSessions: TabSessionRepository
    /// The novel shelf: books, cached chapters and reading positions.
    public let novels: NovelLibraryService
    /// The password vault. Credentials live in the Keychain, not in the
    /// database; this service owns the lock and the page scripts.
    public let passwords: PasswordVaultService
    /// The page overlays the shell renders: dialogs, prompts, the file picker,
    /// the find bar. Exposed here rather than through the web engine so a view
    /// showing a dialog depends on the dialog's state alone.
    public let overlays: WebPageOverlays
    public let webCoordinator: BrowserWebCoordinator
    /// The structured record of recent navigations.
    ///
    /// Owned here rather than by the coordinator because the settings screen
    /// reads it and the coordinator writes it, and neither should have to reach
    /// through the other to get at it. It holds nothing on disk.
    public let navigationLog: NavigationLog
    /// The keyboard commands' dispatch point. The shell registers a handler on
    /// appear; the app's `Commands` menu calls `perform`.
    public let commands: BrowserCommandCenter

    /// Set when the database could not be opened. The shell shows a read-only
    /// error surface rather than crashing, because a browser that cannot start
    /// is worse than one that starts without persistence.
    public private(set) var startupError: String?

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
        self.userScripts = UserScriptRepository(database: safeConnection)

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

        let overlays = WebPageOverlays()
        self.overlays = overlays

        let navigationLog = NavigationLog(settings: settings.navigationDiagnostics)
        self.navigationLog = navigationLog

        let coordinator = BrowserWebCoordinator(
            overlays: overlays,
            settings: settings,
            adBlock: adBlock,
            history: history,
            downloads: downloads,
            bookmarks: bookmarks,
            userScripts: userScripts,
            searchHistory: searchHistory,
            sessionRepository: sessionRepository,
            navigationLog: navigationLog
        )
        self.webCoordinator = coordinator

        self.tabManager = TabManager(
            configurationProvider: coordinator,
            sessionRepository: sessionRepository
        )

        coordinator.attach(tabManager: tabManager)
        boot()
    }

    /// Pushes the diagnostics switches into the log.
    ///
    /// The log holds its own copy of the settings so a record does not have to
    /// consult the settings service on every navigation event; this is the one
    /// place that keeps the copy in step.
    public func applyNavigationDiagnosticsSettings() {
        navigationLog.settings = settings.navigationDiagnostics
    }

    /// Performs the startup work every service needs.
    ///
    /// bookmark roots, the tab session is restored or a first tab created, the
    /// ad-block list is loaded from WebKit's store, and interrupted downloads
    /// are reconciled.
    private func boot() {
        bookmarks.reload()
        history.reload()
        downloads.reload()
        downloads.reconcileInterruptedTasks()

        // The built-in rule sources may not exist yet on a fresh install, so the
        // shipped catalogue is merged in before the first compile.
        seedAdBlockSources()

        Task { await refreshAdBlockRules() }

        // Before the first tab exists: 无痕模式's routing decides what the
        // first launch's home surface is, and a restore's records carry their
        // own modes regardless of it.
        syncPrivateBrowsingRouting()

        tabManager.persistsSession = !(settings.preferences.tabsNotRetained ?? false)
        if tabManager.persistsSession,
           settings.preferences.restoreTabsOnLaunch,
           let snapshot = try? tabSessions.loadSession() {
            tabManager.restoreSession(snapshot)
        }
        if tabManager.tabs.isEmpty {
            // First launch, or a restore that produced nothing.
            let tab = tabManager.createTab()
            tabManager.activateTab(id: tab.id)
        }
    }

    /// Mirrors 无痕模式's preference onto the manager's new-page routing.
    ///
    /// The routing lives on the tab manager because that is where every
    /// creation entry point already lands; the preference lives in settings
    /// because that is where every toggle already lands. This one write is
    /// the bridge, called at startup and on every change of the switch.
    private func syncPrivateBrowsingRouting() {
        tabManager.newPagePrivacyMode = settings.preferences.privateBrowsingMode ?? false
            ? .private
            : .regular
    }

    /// Turns 无痕模式 on or off: the routing flips, and the browser moves to
    /// the surface the mode names — the private home on the way in, the
    /// regular home on the way out of a private page.
    /// Turns 不保留标签页 on or off. Enabling it clears the session already on
    /// disk so a later relaunch cannot resurrect tabs from before the choice;
    /// the open tabs stay on screen until the app is closed.
    public func setTabsNotRetained(_ notRetained: Bool) {
        settings.update { $0.tabsNotRetained = notRetained }
        tabManager.persistsSession = !notRetained
        if notRetained {
            try? tabSessions.removeSession()
        }
    }

    public func setPrivateBrowsingMode(_ on: Bool) {
        settings.update { $0.privateBrowsingMode = on }
        syncPrivateBrowsingRouting()
        if on {
            tabManager.enterPrivateBrowsing()
        } else if tabManager.activeTab?.privacyMode == .private {
            tabManager.exitPrivateBrowsing()
        }
    }

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

        settings.updateManualElementHide { $0 = .default }
    }

    /// Ends a private session: private tabs close, private records clear, and
    /// WebKit's ephemeral store goes with them.
    ///
    /// The profile database is deliberately untouched. Nothing private is in
    /// it to begin with — the history repository suppresses private-boundary
    /// writes, `tabManager.endPrivateSession` re-persists the session without
    /// the private tabs, and the downloads' private records are cleared below
    /// — so a whole-database erase here would not clean anything private. What
    /// it would do is take the regular profile's bookmarks, history and
    /// downloads with it, which is not a cleanup but a deletion of data the
    /// user never asked to lose.
    public func endPrivateSession() async {
        tabManager.endPrivateSession()
        downloads.clearPrivateRecords()

        let privateStore = WKWebsiteDataStore.nonPersistent()
        let types = WKWebsiteDataStore.allWebsiteDataTypes()
        await withCheckedContinuation { continuation in
            privateStore.removeData(ofTypes: types, modifiedSince: Date(timeIntervalSince1970: 0)) {
                continuation.resume()
            }
        }
    }
}
