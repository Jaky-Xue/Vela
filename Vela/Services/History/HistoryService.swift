//
//  HistoryService.swift
//  Vela
//
//  Observable history state over `HistoryRepository`. Ported from
//  `AiraBrowser/entry/src/main/ets/services/history/` and
//  `core/browser/BrowserHistoryVisitPersistenceCoordinator.ets`
//  (Aira Browser 3.7.4, GPL-3.0).
//
//  The service owns the visit-tracking chain: it remembers the visit id of the
//  page the user came from so the repository can close that visit's duration
//  when the next one starts. Aira does the same through
//  `from_visit_id`, and without it the history list has no time-on-page.
//

import Foundation

@MainActor
public final class HistoryService: ObservableObject {
    @Published public private(set) var dayGroups: [HistoryDayGroup] = []
    @Published public private(set) var entryCount: Int = 0

    private let repository: HistoryRepository
    private let settings: SettingsService

    /// The visit id currently in the foreground, per tab. Kept per tab so
    /// switching between two tabs does not attribute the wrong duration.
    private var currentVisitByTab: [String: String] = [:]

    public init(repository: HistoryRepository, settings: SettingsService) {
        self.repository = repository
        self.settings = settings
    }

    // MARK: - Reading

    public func reload() {
        let profileId = browserMainProfileId
        dayGroups = (try? repository.dayGroups(profileId: profileId)) ?? []
        entryCount = (try? repository.count(profileId: profileId)) ?? 0
    }

    public func search(_ query: String) -> [HistoryUrl] {
        (try? repository.search(query, profileId: browserMainProfileId)) ?? []
    }

    public func omniboxSuggestions(_ query: String) -> [HistoryUrl] {
        (try? repository.omniboxSuggestions(query, profileId: browserMainProfileId)) ?? []
    }

    /// Every live history URL, newest first. Backs the home surface's shortcut
    /// grid, which needs the whole set to rank by visit count rather than the
    /// handful a suggestion query returns.
    public func allVisited() -> [HistoryUrl] {
        (try? repository.recentUrls(profileId: browserMainProfileId, limit: 500)) ?? []
    }

    public func visits(for url: HistoryUrl) -> [HistoryVisit] {
        (try? repository.visits(forUrlId: url.id)) ?? []
    }

    // MARK: - Recording

    /// Records a page view for a tab.
    ///
    /// - Parameter title: the page title, which may still be empty when the
    ///   navigation commits. The caller is expected to call this again once the
    ///   title arrives; the repository upserts by URL hash, so the second call
    ///   fills in the title rather than creating a second row.
    public func recordVisit(
        url: URL,
        title: String,
        tabId: String,
        boundary: BrowserDataBoundary,
        transition: HistoryTransition
    ) {
        let previousVisitId = currentVisitByTab[tabId]
        do {
            guard let entry = try repository.recordVisit(
                url: url.absoluteString,
                title: title,
                transition: transition,
                boundary: boundary,
                sessionId: tabId,
                fromVisitId: previousVisitId
            ) else {
                // A private-mode navigation returns nil and records nothing.
                // Clearing the per-tab chain here keeps a later regular
                // navigation from being attributed to a private one's duration.
                currentVisitByTab[tabId] = nil
                return
            }

            // The repository returns the URL row, not the visit row. The visit
            // id for the chain is read back from the newest visit of that URL.
            if let latest = try repository.visits(forUrlId: entry.id, limit: 1).first {
                currentVisitByTab[tabId] = latest.id
            }
            // The published lists are deliberately not refreshed here. This runs
            // on every page load, and re-querying the day groups each time would
            // put a full scan on the navigation path for a list no one is
            // looking at. Every screen that shows history reloads in `onAppear`.
        } catch {
            // A history write must never surface as a browsing failure.
        }
    }

    /// Updates the title of the visit in progress, once the page reports it.
    ///
    /// Writes through `HistoryRepository.updateTitle`, which touches only the
    /// title column — routing this through `recordVisit` would increment the
    /// visit count a second time for a single page view.
    public func updateTitle(url: URL, title: String, tabId: String, boundary: BrowserDataBoundary) {
        guard boundary.persists else { return }
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        guard let existingTitle = try? repository.title(forUrl: url.absoluteString),
              existingTitle != trimmed else { return }
        guard let urlId = try? repository.urlId(forUrl: url.absoluteString) else { return }
        try? repository.updateTitle(urlId: urlId, title: trimmed)
        // No reload: this fires on every page finish, and the history list
        // reloads in `onAppear` when someone is actually looking at it.
    }

    public func clearTabChain(tabId: String) {
        currentVisitByTab[tabId] = nil
    }

    // MARK: - Removing

    public func remove(_ entry: HistoryUrl, scope: HistoryRemovalScope = .singleUrl) {
        try? repository.remove(scope: scope, url: entry, profileId: browserMainProfileId)
        reload()
    }

    public func removeHost(_ entry: HistoryUrl) {
        try? repository.remove(scope: .host, url: entry, profileId: browserMainProfileId)
        reload()
    }

    public func remove(dayGroup: HistoryDayGroup) {
        guard let first = dayGroup.entries.first else { return }
        try? repository.remove(scope: .day, url: first, profileId: browserMainProfileId)
        reload()
    }

    public func removeAll() {
        try? repository.remove(scope: .all, profileId: browserMainProfileId)
        reload()
    }
}
