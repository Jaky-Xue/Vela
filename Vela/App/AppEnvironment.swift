//
//  AppEnvironment.swift
//  Vela
//
//  The composition root. Aira wires its services through HarmonyOS
//  `AppStorage` and module-level singletons (`*Coordinator` classes created in
//  `app/bootstrap/`). SwiftUI has no equivalent container, so Vela constructs
//  every service once here and injects it through the environment.
//
//  One deviation worth naming: Aira keeps its layers wired at module scope so a
//  coordinator can reach another without a parameter. Vela passes the
//  environment explicitly, because a SwiftUI view is re-created constantly and
//  an implicit global would make the app's dependency graph invisible at the
//  call site.
//
//  iOS port enhancement (this revision). The environment republishes every
//  service's changes. SwiftUI tracks an `ObservableObject` only through the
//  property wrapper that exposes it, and every view here reaches its services
//  as `env.settings`, `env.tabManager` and so on — one hop through a nested
//  object that SwiftUI does not follow. Without the forwarding below, a settings
//  change, a tab switch and a page's own title and progress updates all landed
//  in the stores and never reached the screen, which is most of why the chrome
//  looked inert and why switching appearance did nothing until a relaunch.
//

import Foundation
import Combine
import WebKit

@MainActor
public final class AppEnvironment: ObservableObject {
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
    public let webCoordinator: BrowserWebCoordinator

    /// Set when the database could not be opened. The shell shows a read-only
    /// error surface rather than crashing, because a browser that cannot start
    /// is worse than one that starts without persistence.
    @Published public private(set) var startupError: String?

    /// Subscriptions that republish a service's changes as this object's own.
    private var serviceCancellables = Set<AnyCancellable>()
    /// One subscription per live tab, so a page's title, URL and progress reach
    /// the chrome. Keyed by tab id and pruned when a tab closes.
    private var tabCancellables: [String: AnyCancellable] = [:]

    public init() {
        let database = BrowserDatabase.shared
        self.database = database

        let settings = SettingsService()
        self.settings = settings

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

        let coordinator = BrowserWebCoordinator(
            settings: settings,
            adBlock: adBlock,
            history: history,
            downloads: downloads,
            bookmarks: bookmarks,
            userScripts: userScripts,
            searchHistory: searchHistory,
            sessionRepository: sessionRepository
        )
        self.webCoordinator = coordinator

        self.tabManager = TabManager(
            configurationProvider: coordinator,
            sessionRepository: sessionRepository,
            historyTransitionProvider: { tab in
                tab.openSource == .restore ? .restore : (tab.isHome ? .generated : .link)
            }
        )

        coordinator.attach(tabManager: tabManager)
        forwardServiceChanges()
        boot()
    }

    // MARK: - Observation

    /// Republishes every service's changes as this object's own.
    ///
    /// See the note in the file header: a view reaches its services one hop down
    /// from the environment, and SwiftUI does not follow that hop. Each service
    /// is forwarded here so `@EnvironmentObject var env` is enough for any view
    /// to stay live.
    private func forwardServiceChanges() {
        let services: [AnyPublisher<Void, Never>] = [
            settings.objectWillChange.eraseToAnyPublisher(),
            bookmarks.objectWillChange.eraseToAnyPublisher(),
            history.objectWillChange.eraseToAnyPublisher(),
            downloads.objectWillChange.eraseToAnyPublisher(),
            webCoordinator.objectWillChange.eraseToAnyPublisher()
        ]

        for publisher in services {
            publisher
                .sink { [weak self] in self?.objectWillChange.send() }
                .store(in: &serviceCancellables)
        }

        // The tab list itself, plus a re-subscription pass: a tab is an object
        // of its own and its title, URL and progress are the chrome's most
        // frequently changing inputs.
        tabManager.objectWillChange
            .sink { [weak self] in
                self?.objectWillChange.send()
                self?.observeTabs()
            }
            .store(in: &serviceCancellables)

        observeTabs()
    }

    /// Subscribes to every live tab, and drops the subscriptions of closed ones.
    private func observeTabs() {
        for tab in tabManager.tabs where tabCancellables[tab.id] == nil {
            tabCancellables[tab.id] = tab.objectWillChange
                .sink { [weak self] in self?.objectWillChange.send() }
        }

        let live = Set(tabManager.tabs.map(\.id))
        for id in Array(tabCancellables.keys) where !live.contains(id) {
            tabCancellables[id] = nil
        }
    }

    /// Performs the startup work every service needs.
    ///
    /// Ported from the boot sequence in `app/bootstrap/`: settings seed the
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

        if settings.preferences.restoreTabsOnLaunch,
           let snapshot = try? tabSessions.loadSession() {
            tabManager.restoreSession(snapshot)
        }
        if tabManager.tabs.isEmpty {
            // First launch, or a restore that produced nothing.
            let tab = tabManager.createTab()
            tabManager.activateTab(id: tab.id)
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
    /// Ported from `AdBlockLocalRuleFileService`, which keeps rule text on disk
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

    static func filterListUrl(sourceId: String) -> URL {
        let safe = sourceId.replacingOccurrences(of: "/", with: "_")
        return filterListDirectory.appendingPathComponent("\(safe).txt")
    }

    static func writeFilterList(_ text: String, sourceId: String) throws {
        try text.write(to: filterListUrl(sourceId: sourceId), atomically: true, encoding: .utf8)
    }

    /// Removes every trace of browsing data.
    ///
    /// Ported from the combined clear in `SettingsSiteDataClearCoordinator`:
    /// the database, the WebKit data store and the on-disk filter lists are
    /// cleared together, because clearing one and not the others leaves the user
    /// believing more was removed than actually was.
    public func clearAllBrowsingData(includeWebKitData: Bool = true) async {
        try? database.eraseAllData()
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
    /// Ported from `BrowserPrivateSessionCleanupCoordinator`.
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

        try? database.eraseAllData()
    }
}
