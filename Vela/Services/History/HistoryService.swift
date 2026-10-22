//
//  HistoryService.swift
//  Vela
//
//  Observable history state over `HistoryRepository`.
//
//  The service owns the visit chain: it remembers the visit id of the page the
//  user came from, so the repository can close that visit's duration when the
//  next one starts. Without that link the history list has no time-on-page.
//

import Foundation
import Observation

@MainActor
@Observable
public final class HistoryService {
    public private(set) var dayGroups: [HistoryDayGroup] = []
    public private(set) var entryCount: Int = 0

    private let repository: HistoryRepository
    private let settings: SettingsService

    /// The visit id currently in the foreground, per tab. Kept per tab so
    /// switching between two tabs does not attribute the wrong duration.
    private var currentVisitByTab: [String: String] = [:]
    /// One serial queue for the database work. The visit id is generated
    /// before the write, so the next navigation's chain does not have to wait
    /// for this one to return from SQLite.
    private let writeQueue = DispatchQueue(
        label: "org.vela.browser.history-writer",
        qos: .utility
    )

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
        // A user who has asked not to keep history gets no rows and no visit
        // chain; the previous chain is dropped with it.
        guard !(settings.preferences.historyNotRetained ?? false) else {
            currentVisitByTab[tabId] = nil
            return
        }
        // A private navigation returns nil from the repository and must not
        // leave a chain behind; skipping the enqueue also keeps the private
        // URL out of a background queue.
        guard boundary.persists else {
            currentVisitByTab[tabId] = nil
            return
        }

        let previousVisitId = currentVisitByTab[tabId]
        // Generate the id here, not in the repository: the next navigation can
        // chain to this visit before the serial writer has reached SQLite.
        let visitId = UUID().uuidString
        currentVisitByTab[tabId] = visitId

        let repository = self.repository
        let rawUrl = url.absoluteString
        writeQueue.async {
            _ = try? repository.recordVisit(
                url: rawUrl,
                title: title,
                transition: transition,
                boundary: boundary,
                sessionId: tabId,
                fromVisitId: previousVisitId,
                visitId: visitId
            )
        }
        // The published lists are deliberately not refreshed here. This runs
        // on every page load, and re-querying the day groups each time would
        // put a full scan on the navigation path for a list no one is looking
        // at. Every screen that shows history reloads in `onAppear`.
    }

    /// Updates the title of the visit in progress, once the page reports it.
    ///
    /// Writes through `HistoryRepository.updateTitle`, which touches only the
    /// title column — routing this through `recordVisit` would increment the
    /// visit count a second time for a single page view.
    public func updateTitle(url: URL, title: String, tabId: String, boundary: BrowserDataBoundary) {
        guard !(settings.preferences.historyNotRetained ?? false) else { return }
        guard boundary.persists else { return }
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        // Same serial queue as the record, so the title update cannot overtake
        // the insert it belongs to.
        let repository = self.repository
        let rawUrl = url.absoluteString
        writeQueue.async {
            guard let existingTitle = try? repository.title(forUrl: rawUrl),
                  existingTitle != trimmed else { return }
            guard let urlId = try? repository.urlId(forUrl: rawUrl) else { return }
            try? repository.updateTitle(urlId: urlId, title: trimmed)
        }
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
