//
//  AppEnvironment.swift
//  Vela
//
//  One browser window's composition.
//
//  `AppServices` owns everything the process shares — database, settings,
//  history, bookmarks, downloads, the offline shelf. This object owns what a
//  single window owns: its tab session, its web views, its page overlays, its
//  navigation log and its translation panel. A Stage Manager window therefore
//  gets its own environment, built here from the shared services, instead of
//  sharing one tab strip with every other window.
//
//  The environment is `@Observable` like every other service. A view that reads
//  `env.settings` tracks the settings service itself: the Observation framework
//  records the property each view actually reads, however many hops down it
//  sits, so nothing here forwards change notifications.
//

import Foundation
import WebKit
import Observation

@MainActor
@Observable
public final class AppEnvironment {
    /// The process-wide services every window reads from.
    public let services: AppServices
    /// The `window_id` this window's tab session is stored under.
    public let windowId: String

    /// The page overlays this window renders: dialogs, prompts, the file
    /// picker, the find bar.
    public let overlays: WebPageOverlays
    public let webCoordinator: BrowserWebCoordinator
    public let tabManager: TabManager
    /// The structured record of recent navigations in this window.
    public let navigationLog: NavigationLog
    /// The page translation panel's state.
    public let translation: TranslationService
    /// The on-device translation bridge, when the OS provides the framework.
    private(set) var appleTranslationBridge: (any AppleTranslationBridging)?

    /// The private session's novel shelf, created on demand and dropped when
    /// the session ends. It runs on its own in-memory database, so nothing it
    /// writes can reach the regular novel tables.
    private var privateNovelService: NovelLibraryService?

    /// Records stalls the navigation log cannot see: its entries are written by
    /// WebKit callbacks, and those stop during a main-thread hang.
    private var hangMonitor: MainThreadHangMonitor?

    /// Called synchronously at the start of an accepted private-session end,
    /// before tabs close. The shell uses it to take the private reader off the
    /// hierarchy first, so the reader's loader tasks and library are part of
    /// the shutdown's order rather than a later SwiftUI side effect.
    public var onPrivateSessionWillEnd: (() -> Void)?

    /// The last shell action, used as context when the hang watchdog records a
    /// stall. The watchdog cannot sample the blocked stack safely; knowing the
    /// page and the control that preceded the stall is the next best clue.
    public private(set) var lastInteraction = ""

    public func noteInteraction(_ label: String) {
        lastInteraction = label
    }

    /// Bumped when a private session begins and when it ends. A reader created
    /// in an earlier generation compares its captured value against this one
    /// before writing or closing; the value, not a bare "is private" flag,
    /// keeps a late callback from touching the session that replaced it.
    public private(set) var privateNovelSessionGeneration = 0

    public init(
        services: AppServices,
        windowId: String = TabSessionRepository.defaultWindowId
    ) {
        self.services = services
        self.windowId = windowId

        let overlays = WebPageOverlays()
        self.overlays = overlays

        let navigationLog = NavigationLog(settings: services.settings.navigationDiagnostics)
        self.navigationLog = navigationLog

        let coordinator = BrowserWebCoordinator(
            overlays: overlays,
            settings: services.settings,
            adBlock: services.adBlock,
            history: services.history,
            downloads: services.downloads,
            userScripts: services.userScriptRepository,
            navigationLog: navigationLog
        )
        self.webCoordinator = coordinator

        self.tabManager = TabManager(
            configurationProvider: coordinator,
            sessionRepository: services.tabSessions,
            windowId: windowId
        )
        self.translation = TranslationService()
        if #available(iOS 18.0, *) {
            let bridge = AppleTranslationBridge()
            appleTranslationBridge = bridge
            translation.appleBridge = bridge
        }

        coordinator.attach(tabManager: tabManager)
        tabManager.onPrivateSessionStarted = { [weak self] in
            self?.beginPrivateSession()
        }
        tabManager.onWillCloseTab = { [weak coordinator] tab in
            coordinator?.cleanupClosedTab(tab)
        }
        coordinator.userScriptOpenTabHandler = { [weak self] url, active, privacyMode in
            self?.tabManager.openTab(
                url: url,
                privacyMode: privacyMode,
                openSource: .webWindowOpen,
                activate: active
            )
        }
        // A translated page's observer reports new blocks here. The closure is
        // weak on both sides: the coordinator is owned by this environment, so
        // a strong capture would keep the window alive for the app's lifetime.
        coordinator.dynamicTranslationHandler = { [weak self] payload, tabId, webView in
            guard let self else { return }
            self.translation.handleDynamicUnits(
                payload,
                tabId: tabId,
                webView: webView,
                settings: self.settings.translationSettings
            )
        }
        services.bootOnce()
        bootWindow()

        let monitor = MainThreadHangMonitor { [weak self] durationMs in
            guard let self else { return }
            let tab = self.tabManager.activeTab
            self.navigationLog.recordHang(
                durationMs: durationMs,
                tabId: tab?.id ?? "",
                navigationSerial: tab?.navigationSerial ?? 0,
                phase: tab?.loadState ?? .idle,
                url: tab?.url ?? "",
                note: self.lastInteraction
            )
        }
        hangMonitor = monitor
        monitor.start()
    }

    // MARK: - Shared services, forwarded

    public var database: BrowserDatabase { services.database }
    public var settings: SettingsService { services.settings }
    public var bookmarks: BookmarkService { services.bookmarks }
    public var history: HistoryService { services.history }
    public var downloads: DownloadService { services.downloads }
    public var adBlock: AdBlockEngine { services.adBlock }
    public var searchHistory: SearchHistoryRepository { services.searchHistory }
    public var userScripts: UserScriptService { services.userScripts }
    public var tabSessions: TabSessionRepository { services.tabSessions }
    public var novels: NovelLibraryService { services.novels }
    public var passwords: PasswordVaultService { services.passwords }
    public var offlinePages: OfflinePageService { services.offlinePages }
    public var commands: BrowserCommandCenter { services.commands }
    public var startupError: String? { services.startupError }

    // MARK: - Window startup

    /// Restores this window's own tab session, or opens its first home tab.
    ///
    /// The first window of a launch owns `window-main`; windows opened beside
    /// it have an identifier with no saved rows, so they start on the home
    /// surface. That is the intended difference between "the browser I
    /// relaunched" and "another window I just opened".
    private func bootWindow() {
        // Before the first tab exists: 无痕模式's routing decides what the
        // first launch's home surface is, and a restore's records carry their
        // own modes regardless of it.
        syncPrivateBrowsingRouting()

        tabManager.persistsSession = !(settings.preferences.tabsNotRetained ?? false)
        if tabManager.persistsSession,
           settings.preferences.restoreTabsOnLaunch,
           let snapshot = try? tabSessions.loadSession(windowId: windowId) {
            tabManager.restoreSession(snapshot)
        }
        // The recently-closed list is persisted, so a relaunch offers the
        // entries it saved. Private entries are loaded only when a private
        // session is actually open (restored tabs or the routing switch);
        // otherwise they are stale private metadata and are cleared.
        // A process can die before the private-session end hook runs. Private
        // download records and files have no business surviving that, so a
        // launch with no private session clears them before any window reads
        // the shared download service.
        if tabManager.privateTabs.isEmpty,
           !(settings.preferences.privateBrowsingMode ?? false) {
            downloads.clearPrivateRecords()
        }
        if tabManager.persistsSession {
            var records = (try? tabSessions.recentlyClosed(privacyMode: .regular)) ?? []
            let privateSessionIsOpen = !tabManager.privateTabs.isEmpty
                || (settings.preferences.privateBrowsingMode ?? false)
            if privateSessionIsOpen {
                records += (try? tabSessions.recentlyClosed(privacyMode: .private)) ?? []
            } else {
                try? tabSessions.clearRecentlyClosed(privacyMode: .private)
            }
            tabManager.restoreRecentlyClosed(records)
        } else {
            try? tabSessions.clearRecentlyClosed(privacyMode: .regular)
            try? tabSessions.clearRecentlyClosed(privacyMode: .private)
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

    /// Re-reads 无痕模式's routing after another window changed the switch.
    ///
    /// The preference is app-wide, but the routing lives on each window's tab
    /// manager; a window that did not make the change would otherwise keep
    /// opening regular tabs with the mode on.
    public func refreshPrivateBrowsingRouting() {
        syncPrivateBrowsingRouting()
    }

    // MARK: - Diagnostics

    /// Pushes the diagnostics switches into the log.
    ///
    /// The log holds its own copy of the settings so a record does not have to
    /// consult the settings service on every navigation event; this is the one
    /// place that keeps the copy in step.
    public func applyNavigationDiagnosticsSettings() {
        navigationLog.settings = settings.navigationDiagnostics
    }

    // MARK: - Preferences with a window side effect

    /// Turns 不保留标签页 on or off. Enabling it clears this window's session
    /// already on disk so a later relaunch cannot resurrect tabs from before
    /// the choice; the open tabs stay on screen until the app is closed.
    public func setTabsNotRetained(_ notRetained: Bool) {
        settings.update { $0.tabsNotRetained = notRetained }
        tabManager.persistsSession = !notRetained
        if notRetained {
            try? tabSessions.removeSession(windowId: windowId)
        }
    }

    /// Turns 无痕模式 on or off: the routing flips, and the browser moves to
    /// the surface the mode names — the private home on the way in, the
    /// regular home on the way out of a private page.
    public func setPrivateBrowsingMode(_ on: Bool) {
        settings.update { $0.privateBrowsingMode = on }
        syncPrivateBrowsingRouting()
        if on {
            tabManager.enterPrivateBrowsing()
        } else if tabManager.activeTab?.privacyMode == .private {
            tabManager.exitPrivateBrowsing()
        }
    }

    /// The one flip every 无痕模式 entry point uses. Keeping the expression here
    /// means the menu, the toolbar, the hardware command and the empty-browser
    /// menu cannot disagree about whether the current value was read before or
    /// after the write.
    public func togglePrivateBrowsingMode() {
        setPrivateBrowsingMode(!(settings.preferences.privateBrowsingMode ?? false))
    }

    /// The mode the current strip presents: the active tab's own mode, or the
    /// routing preference when no tab exists.
    public var currentPrivacyMode: BrowserSessionPrivacyMode {
        tabManager.activeTab?.privacyMode
            ?? ((settings.preferences.privateBrowsingMode ?? false) ? .private : .regular)
    }

    // MARK: - Ad-blocking, forwarded

    public func refreshAdBlockRules() async {
        await services.refreshAdBlockRules()
    }

    public func updateAdBlockSource(id: String) async {
        await services.updateAdBlockSource(id: id)
    }

    public func adBlockRuleText(sourceId: String) -> String? {
        services.adBlockRuleText(sourceId: sourceId)
    }

    public func clearAllBrowsingData(includeWebKitData: Bool = true) async {
        await services.clearAllBrowsingData(includeWebKitData: includeWebKitData)
    }

    // MARK: - Novel services

    /// The shelf a reading session should use.
    ///
    /// Ordinary sessions share the process-wide service. A private session gets
    /// a service over a fresh in-memory database: the same NovelLibraryService
    /// and schema, a different SQLite file. `nil` means the in-memory database
    /// could not be created; callers must not fall back to the regular service.
    public func novelLibrary(privateMode: Bool) async -> NovelLibraryService? {
        guard privateMode else { return services.novels }
        if let privateNovelService { return privateNovelService }

        // The in-memory schema is created off-main. If the session ends while
        // it is being built, the result belongs to no session: close it rather
        // than installing a shelf into the next one.
        let generation = privateNovelSessionGeneration
        guard let service = await InMemoryNovelLibrary.makeAsync() else { return nil }
        guard generation == privateNovelSessionGeneration else {
            service.close()
            return nil
        }
        if let existing = privateNovelService {
            service.close()
            return existing
        }
        privateNovelService = service
        return service
    }

    // MARK: - Private session

    /// Starts a new private session's identity and storage.
    ///
    /// TabManager fires this when the first private tab of a session is
    /// appended. The generation bumps so readers and shelves from the previous
    /// session close; the private novel service is dropped and the old WebKit
    /// store is retired. The next private page creates a fresh store and an
    /// empty in-memory shelf.
    private func beginPrivateSession() {
        privateNovelSessionGeneration &+= 1
        let retiring = privateNovelService
        privateNovelService = nil
        scheduleRetirement(of: retiring)
        webCoordinator.beginNewPrivateSession()
    }

    /// Closes a retired private shelf's database after the reader has had a
    /// short grace period to leave the hierarchy. A service that is already
    /// gone is skipped. The generation guards stop late writes before this
    /// point; the delay only avoids pulling the handle out from under a view
    /// that is still rendering its last frame.
    private func scheduleRetirement(of service: NovelLibraryService?) {
        guard let service else { return }
        Task { @MainActor [weak service] in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            service?.close()
        }
    }

    /// Ends a private session: private tabs close, private records clear, and
    /// the non-persistent WebKit store those tabs shared is emptied.
    ///
    /// The profile database is deliberately untouched. Nothing private is in
    /// it to begin with — the history repository suppresses private-boundary
    /// writes, `tabManager.endPrivateSession` re-persists the session without
    /// the private tabs, and the downloads' private records are cleared below
    /// — so a whole-database erase here would not clean anything private. What
    /// it would do is take the regular profile's bookmarks, history and
    /// downloads with it, which is not a cleanup but a deletion of data the
    /// user never asked to lose.
    ///
    /// Ends the private session identified by `expectedGeneration`.
    ///
    /// The caller captures the generation when it decides to end. A delayed or
    /// duplicate request whose generation no longer matches returns without
    /// closing tabs, clearing downloads, releasing the novel service or
    /// touching the store. The generation is advanced only by the run that is
    /// allowed to end the session.
    /// The handle from the synchronous half of a private-session end.
    ///
    /// The retired store is captured before the asynchronous half starts, so a
    /// new private session cannot have its fresh store mistaken for the one
    /// being emptied.
    struct PrivateSessionEndToken {
        let generation: Int
        let retiredStore: WKWebsiteDataStore?
    }

    /// Synchronously invalidates the session, closes the reader, closes tabs,
    /// clears private download records, retires the WebKit store and releases
    /// the shelf. Only the store's `removeData` is left for the async half.
    ///
    /// Kept separate from `endPrivateSession` so a caller that needs the exact
    /// order can hold the token while it updates UI, then finish.
    @discardableResult
    func beginEndPrivateSession(expectedGeneration: Int) -> PrivateSessionEndToken? {
        var retiredStore: WKWebsiteDataStore?
        guard let nextGeneration = PrivateSessionLedger.end(
            expectedGeneration: expectedGeneration,
            currentGeneration: privateNovelSessionGeneration,
            perform: {
                // Cancels both novel loaders and drops the reader's weak shelf
                // reference before tabs or the store are touched.
                onPrivateSessionWillEnd?()
                tabManager.endPrivateSession()
                downloads.clearPrivateRecords()
                retiredStore = webCoordinator.takePrivateWebsiteDataStoreForCleanup()
                let retiring = privateNovelService
                privateNovelService = nil
                scheduleRetirement(of: retiring)
            }
        ) else { return nil }

        privateNovelSessionGeneration = nextGeneration
        return PrivateSessionEndToken(
            generation: nextGeneration,
            retiredStore: retiredStore
        )
    }

    /// Empties the store captured at the start of the end. Safe to call after a
    /// new private session has begun: the token names the old store, not
    /// whatever is current.
    func finishEndPrivateSession(_ token: PrivateSessionEndToken) async {
        guard let store = token.retiredStore else { return }
        await webCoordinator.clearPrivateWebsiteData(store)
    }

    /// Ends a private session. The synchronous half runs to completion before
    /// the first suspension; the asynchronous half only clears the store that
    /// was retired in that same turn.
    public func endPrivateSession(expectedGeneration: Int) async {
        guard let token = beginEndPrivateSession(expectedGeneration: expectedGeneration) else {
            return
        }
        await finishEndPrivateSession(token)
    }
}

/// The private-session generation rule.
///
/// A caller captures the generation when it decides to end the session. Only
/// that exact session may run the end; a delayed request from an older session
/// returns nil and touches nothing. The returned value is the next generation,
/// which the caller assigns before starting the asynchronous store cleanup.
enum PrivateSessionLedger {
    @MainActor
    static func end(
        expectedGeneration: Int,
        currentGeneration: Int,
        perform: () -> Void
    ) -> Int? {
        guard expectedGeneration == currentGeneration else { return nil }
        perform()
        return currentGeneration &+ 1
    }
}
