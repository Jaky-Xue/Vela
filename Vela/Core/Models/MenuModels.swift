//
//  MenuModels.swift
//  Vela
//
//  What the menu panel can show, and the user's arrangement of it.
//
//  The panel used to be every case of `VelaMenuAction`, in declaration order.
//  It is now a layout: built-in actions can be hidden and dragged, and the
//  user can add their own URL shortcuts. The order is stored as raw strings in
//  the preferences document, because that document decodes as a whole and a
//  nested Codable model would make an old install fail to decode.
//

import Foundation

// MARK: - Built-in actions

/// One action the menu panel can offer.
enum VelaMenuAction: String, CaseIterable, Identifiable, Sendable, Equatable {
    case addBookmark
    case share
    case findInPage
    case reader
    case novel
    case bookshelf
    case passwords
    case hideElements
    case desktopSite
    case home
    case bookmarks
    case history
    case downloads
    case scanQRCode
    case privateTab
    case adBlock
    case reload
    case settings
    /// Not a grid tile: offered on the private-tab tile's long-press menu when
    /// the browser is in private mode, which is the one manual way out of it.
    case leavePrivate

    var id: String { rawValue }

    var title: String {
        switch self {
        case .addBookmark: return "添加书签"
        case .share: return "分享"
        case .findInPage: return "查找网页"
        case .reader: return "阅读模式"
        case .novel: return "小说模式"
        case .bookshelf: return "书架"
        case .passwords: return "密码与保险箱"
        case .hideElements: return "隐藏元素"
        case .desktopSite: return "桌面网站"
        case .home: return "主页"
        case .bookmarks: return "书签"
        case .history: return "历史记录"
        case .downloads: return "下载管理"
        case .scanQRCode: return "扫一扫"
        case .privateTab: return "无痕模式"
        case .adBlock: return "广告过滤"
        case .reload: return "重新载入"
        case .settings: return "设置"
        case .leavePrivate: return "离开无痕模式"
        }
    }

    var symbolName: String {
        switch self {
        case .addBookmark: return "bookmark"
        case .share: return "square.and.arrow.up"
        case .findInPage: return "magnifyingglass"
        case .reader: return "doc.plaintext"
        case .novel: return "text.book.closed"
        case .bookshelf: return "books.vertical"
        case .passwords: return "key.fill"
        case .hideElements: return "eye.slash"
        case .desktopSite: return "desktopcomputer"
        case .home: return "house"
        case .bookmarks: return "book"
        case .history: return "clock.arrow.circlepath"
        case .downloads: return "arrow.down.circle"
        case .scanQRCode: return "qrcode.viewfinder"
        case .privateTab: return "eyeglasses"
        case .adBlock: return "shield.lefthalf.filled"
        case .reload: return "arrow.clockwise"
        case .settings: return "gearshape"
        case .leavePrivate: return "eyeglasses.slash"
        }
    }

    /// Actions that need a document to act on. On the home surface — or with
    /// no tab at all — they are drawn dimmed and do nothing, the same way the
    /// reference panels grey out what a page-less context cannot do.
    var requiresPage: Bool {
        switch self {
        case .addBookmark, .share, .findInPage, .reader, .novel, .hideElements,
             .desktopSite, .reload:
            return true
        default:
            return false
        }
    }
}

// MARK: - User shortcuts

/// A URL the user put in the menu panel.
///
/// Public because it is stored inside `BrowserPreferences`, whose initializer
/// is public: an internal type there would make the initializer's signature
/// less accessible than the type.
public struct MenuShortcut: Identifiable, Codable, Equatable, Sendable {
    public var id: String
    public var title: String
    public var url: String
    /// An SF Symbol name chosen from `symbolChoices`; unknown names simply draw
    /// nothing and the tile falls back to a link glyph at the call site.
    public var symbolName: String

    public init(
        id: String = UUID().uuidString,
        title: String,
        url: String,
        symbolName: String = "link"
    ) {
        self.id = id
        self.title = title
        self.url = url
        self.symbolName = symbolName
    }

    /// The symbols the editor offers. A fixed set, so a shortcut cannot name a
    /// symbol that does not exist on an older iOS.
    public static let symbolChoices: [String] = [
        "link",
        "star.fill",
        "globe",
        "bolt.fill",
        "heart.fill",
        "bookmark.fill",
        "cart.fill",
        "newspaper.fill",
        "play.rectangle.fill",
        "terminal.fill"
    ]
}

// MARK: - Tiles

/// One tile the menu can draw.
enum MenuTile: Identifiable, Equatable {
    case action(VelaMenuAction)
    case shortcut(MenuShortcut)

    var id: String {
        switch self {
        case let .action(action): return action.rawValue
        case let .shortcut(shortcut): return shortcut.id
        }
    }

    var title: String {
        switch self {
        case let .action(action): return action.title
        case let .shortcut(shortcut): return shortcut.title
        }
    }

    var symbolName: String {
        switch self {
        case let .action(action): return action.symbolName
        case let .shortcut(shortcut): return shortcut.symbolName
        }
    }

    var requiresPage: Bool {
        switch self {
        case let .action(action): return action.requiresPage
        case .shortcut: return false
        }
    }

    var action: VelaMenuAction? {
        if case let .action(action) = self { return action }
        return nil
    }

    var shortcut: MenuShortcut? {
        if case let .shortcut(shortcut) = self { return shortcut }
        return nil
    }
}

// MARK: - Layout

/// The user's menu arrangement: order, hidden built-ins, custom shortcuts.
struct MenuLayout: Equatable {
    /// Every configured tile id, visible and hidden. Hidden items keep their
    /// place at the tail; re-showing one does not scramble the visible order.
    var order: [String]
    var hidden: Set<String>
    var shortcuts: [MenuShortcut]

    static let defaultOrder: [String] = VelaMenuAction.allCases
        .filter { $0 != .leavePrivate }
        .map(\.rawValue)

    init(orderRaw: [String]? = nil, hiddenRaw: [String]? = nil, shortcutsRaw: [MenuShortcut]? = nil) {
        let shortcuts = shortcutsRaw ?? []
        var known = Set(Self.defaultOrder)
        known.formUnion(shortcuts.map(\.id))

        var resolved: [String] = []
        for id in (orderRaw ?? Self.defaultOrder) where known.contains(id) && !resolved.contains(id) {
            resolved.append(id)
        }
        // A build can add a built-in action after this install wrote its
        // order, and a shortcut added from another path may be missing from
        // it; both are appended rather than dropped.
        for id in Self.defaultOrder where !resolved.contains(id) {
            resolved.append(id)
        }
        for shortcut in shortcuts where !resolved.contains(shortcut.id) {
            resolved.append(shortcut.id)
        }

        self.order = resolved
        self.shortcuts = shortcuts
        self.hidden = Set((hiddenRaw ?? []).filter { resolved.contains($0) })
    }

    private func tile(for id: String) -> MenuTile? {
        if let action = VelaMenuAction(rawValue: id), action != .leavePrivate {
            return .action(action)
        }
        if let shortcut = shortcuts.first(where: { $0.id == id }) {
            return .shortcut(shortcut)
        }
        return nil
    }

    var allTiles: [MenuTile] {
        order.compactMap { tile(for: $0) }
    }

    var visibleTiles: [MenuTile] {
        order.filter { !hidden.contains($0) }.compactMap { tile(for: $0) }
    }

    var hiddenTiles: [MenuTile] {
        order.filter { hidden.contains($0) }.compactMap { tile(for: $0) }
    }

    func settingVisible(_ visible: Bool, id: String) -> MenuLayout {
        var copy = self
        if visible {
            copy.hidden.remove(id)
        } else if copy.order.contains(id) {
            copy.hidden.insert(id)
        }
        return copy
    }

    func hidingVisible(at offsets: IndexSet) -> MenuLayout {
        let visibleIds = order.filter { !hidden.contains($0) }
        var copy = self
        for index in offsets where visibleIds.indices.contains(index) {
            copy.hidden.insert(visibleIds[index])
        }
        return copy
    }

    func movingVisible(from source: IndexSet, to destination: Int) -> MenuLayout {
        let original = order.filter { !hidden.contains($0) }
        let moving = source.compactMap { original.indices.contains($0) ? original[$0] : nil }
        var remaining = original
        for index in source.sorted(by: >) where remaining.indices.contains(index) {
            remaining.remove(at: index)
        }

        // SwiftUI reports the destination in the original coordinates; after
        // removing the moved rows, an insertion after them shifts left.
        var insertion = destination
        for index in source where index < destination {
            insertion -= 1
        }
        insertion = max(0, min(insertion, remaining.count))
        remaining.insert(contentsOf: moving, at: insertion)

        let hiddenIds = order.filter { hidden.contains($0) }
        var copy = self
        copy.order = remaining + hiddenIds
        return copy
    }

    func adding(_ shortcut: MenuShortcut) -> MenuLayout {
        var copy = self
        copy.order.append(shortcut.id)
        copy.shortcuts.append(shortcut)
        copy.hidden.remove(shortcut.id)
        return copy
    }

    /// Removes a shortcut outright. It is not a built-in, so hiding it would
    /// leave an entry the user cannot delete.
    func removingShortcut(id: String) -> MenuLayout {
        var copy = self
        copy.order.removeAll { $0 == id }
        copy.hidden.remove(id)
        copy.shortcuts.removeAll { $0.id == id }
        return copy
    }

    func reset() -> MenuLayout {
        MenuLayout()
    }
}
