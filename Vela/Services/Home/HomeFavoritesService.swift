//
//  HomeFavoritesService.swift
//  Vela
//
//  The home's own favourites shelf.
//
//  This store is deliberately not the bookmark store. The home used to keep a
//  set of bookmark ids and render whatever those ids still resolved to, which
//  meant deleting a bookmark silently took a home tile with it and renaming one
//  changed the tile too. A favourite is a copy: its name, its address and
//  whether it draws that name belong to the tile. The document lives in
//  `UserDefaults` as one JSON array so a half-written update cannot leave a
//  tile pointing at another one's name.
//

import Foundation
import Observation

@MainActor
@Observable
public final class HomeFavoritesService {
    /// The tiles in the order the home draws them.
    public private(set) var favorites: [HomeFavorite] = []

    private enum Key {
        /// The live document.
        static let document = "org.vela.browser.home-favorites"
        /// One-way marker: the retired bookmark-id store has been carried over.
        static let migrated = "org.vela.browser.home-favorites-migrated"
        /// The retired store: bookmark ids the home used to show.
        static let legacyIds = "org.vela.browser.home-bookmark-ids"
        static let legacySeeded = "org.vela.browser.home-bookmarks-seeded"
    }

    private let defaults: UserDefaults
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        reload()
    }

    // MARK: - Reading

    public func reload() {
        guard let data = defaults.data(forKey: Key.document),
              let decoded = try? decoder.decode([HomeFavorite].self, from: data) else {
            favorites = []
            return
        }
        favorites = decoded
    }

    /// Carries the home grid an existing install already had into this store.
    ///
    /// The retired store held bookmark ids in a set, so its order was whatever
    /// the bookmark tree gave it; the caller passes the tree walk and the ids
    /// filter that. Each id is resolved exactly once — from here on the tile is
    /// a copy and the bookmark may change or disappear without touching it.
    public func migrateFromLegacyHomeStoreIfNeeded(bookmarks: [BookmarkNode]) {
        guard !defaults.bool(forKey: Key.migrated) else { return }

        // A document created before the marker was written is already the
        // user's own shelf; migrating over it would duplicate or overwrite.
        guard favorites.isEmpty else {
            defaults.set(true, forKey: Key.migrated)
            discardLegacyStore()
            return
        }

        let wasSeeded = defaults.bool(forKey: Key.legacySeeded)
        let legacyIds = Set(defaults.stringArray(forKey: Key.legacyIds) ?? [])

        // The bookmark tree can come back empty because the database itself
        // failed to open. Marking the migration done in that state would
        // permanently forget which bookmarks the home was showing; leave the
        // legacy store in place and try again on the next launch.
        if wasSeeded, !legacyIds.isEmpty, bookmarks.isEmpty {
            return
        }

        let source = wasSeeded ? bookmarks.filter { legacyIds.contains($0.id) } : bookmarks

        favorites = source.compactMap { node in
            guard let url = node.url?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !url.isEmpty else { return nil }
            return HomeFavorite(title: node.title, url: url)
        }
        // The document is written before the marker: a crash between the
        // two leaves the migration runnable, and running it again with an
        // existing document takes the guard above rather than duplicating.
        persist()
        defaults.set(true, forKey: Key.migrated)
        discardLegacyStore()
    }

    private func discardLegacyStore() {
        defaults.removeObject(forKey: Key.legacyIds)
        defaults.removeObject(forKey: Key.legacySeeded)
    }

    // MARK: - Writing

    /// Adds a tile and returns it. A URL already on the shelf is not added a
    /// second time: the sheet that offers 「同时添加到主页收藏」 can be used
    /// more than once for the same page, and a duplicate tile would give the
    /// user two copies of one name to keep in step.
    @discardableResult
    public func add(url: String, title: String, showsTitle: Bool? = nil) -> HomeFavorite? {
        guard let normalized = Self.normalizedUrl(url) else { return nil }
        if let existing = favorites.first(where: { $0.url == normalized }) {
            return existing
        }
        let favorite = HomeFavorite(
            title: title.trimmingCharacters(in: .whitespacesAndNewlines),
            url: normalized,
            showsTitle: showsTitle
        )
        favorites.append(favorite)
        persist()
        return favorite
    }

    /// Replaces a tile's editable values. The address is normalised first; an
    /// address that does not resolve leaves the tile untouched and answers
    /// false, which is what the editor uses to keep its save button honest.
    @discardableResult
    public func update(
        id: String,
        title: String,
        url: String,
        showsTitle: Bool?
    ) -> Bool {
        guard let index = favorites.firstIndex(where: { $0.id == id }),
              let normalized = Self.normalizedUrl(url) else { return false }
        favorites[index].title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        favorites[index].url = normalized
        favorites[index].showsTitle = showsTitle
        favorites[index].updatedAt = Date()
        persist()
        return true
    }

    /// Sets only the name-visibility choice, which the tile's long-press menu
    /// flips without opening the editor.
    public func setShowsTitle(id: String, value: Bool?) {
        guard let index = favorites.firstIndex(where: { $0.id == id }) else { return }
        favorites[index].showsTitle = value
        favorites[index].updatedAt = Date()
        persist()
    }

    public func remove(id: String) {
        guard favorites.contains(where: { $0.id == id }) else { return }
        favorites.removeAll { $0.id == id }
        persist()
    }

    /// One address rule for the home, its editor and the bookmark sheet's
    /// hand-off: a bare host becomes `https`, and anything that is not a web
    /// address is refused rather than stored as a tile that cannot open.
    public static func normalizedUrl(_ raw: String) -> String? {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        if !text.contains("://") {
            text = "https://" + text
        }
        guard let url = URL(string: text),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              url.host?.isEmpty == false else {
            return nil
        }
        return HistoryUrlNormalizer.normalize(text) ?? text
    }

    private func persist() {
        guard let data = try? encoder.encode(favorites) else { return }
        defaults.set(data, forKey: Key.document)
    }
}
