//
//  ShellOverlay.swift
//  Vela
//
//  Everything that covers the main surface without replacing it.
//
//  Overlays are a set rather than a stack of booleans because the shell never
//  needs two of the same kind at once and does need to answer "is this on
//  screen?" from a dozen places. The menu's deferred presentation is a
//  separate value (`pendingMenuPresentation`) because it describes something
//  that has not been presented yet.
//

import Foundation

/// A screen the menu asked for.
///
/// The menu is itself a sheet; a destination it opens is a second one. They
/// are two steps — close, then present — rather than one update that asks
/// UIKit to do both at once. The shell holds the request until the menu sheet's
/// `onDismiss` runs.
enum MenuPresentation: Equatable {
    case addBookmark
    case share
    case bookmarks
    case history
    case downloads
    case offlinePages
    case settings
    case bookshelf
    case passwords
    case qrScanner
}

/// The shelf a bookshelf sheet was opened for.
///
/// Captured when the sheet opens, so a tab switch behind it cannot swap the
/// database under the shelf, and a private shelf never falls back to the
/// regular one. `sourceTabId` is the tab the sheet was opened from: a private
/// shelf's reader uses it for "open in browser" and never infers it later.
struct BookshelfContext: Equatable {
    let library: NovelLibraryService
    let isPrivate: Bool
    let generation: Int
    let sourceTabId: String

    static func == (lhs: BookshelfContext, rhs: BookshelfContext) -> Bool {
        lhs.isPrivate == rhs.isPrivate
            && lhs.generation == rhs.generation
            && lhs.sourceTabId == rhs.sourceTabId
            && lhs.library === rhs.library
    }
}

/// A layer the shell can show over its main surface.
///
/// Some are SwiftUI sheets, some are layers inside the shell's own hierarchy
/// (the overview, the scanner, the find bar). The enumeration is the same for
/// both because the question the rest of the code asks — "is this on screen?"
/// — is the same, and because a sheet that is presented through one API and
/// dismissed through another is how presentation state drifts.
enum ShellOverlay: Identifiable {
    case tabsOverview
    case menu
    case bookmarks
    case history
    case downloads
    case offlinePages
    case settings(SettingsDestination?)
    case passwords
    case bookshelf(BookshelfContext)
    case qrScanner
    case findBar
    case share
    case addBookmarkChoice
    case siteCapabilities

    /// The overlay's identity, without its payload.
    ///
    /// Associated values are data, not identity: there is one settings sheet
    /// and one shelf at a time, and the sheet reads the payload from whichever
    /// value is currently present. This is what lets a presentation binding
    /// ask "is settings open?" without knowing which screen it opens on.
    enum Kind: String, CaseIterable {
        case tabsOverview
        case menu
        case bookmarks
        case history
        case downloads
        case offlinePages
        case settings
        case passwords
        case bookshelf
        case qrScanner
        case findBar
        case share
        case addBookmarkChoice
        case siteCapabilities
    }

    var kind: Kind {
        switch self {
        case .tabsOverview: return .tabsOverview
        case .menu: return .menu
        case .bookmarks: return .bookmarks
        case .history: return .history
        case .downloads: return .downloads
        case .offlinePages: return .offlinePages
        case .settings: return .settings
        case .passwords: return .passwords
        case .bookshelf: return .bookshelf
        case .qrScanner: return .qrScanner
        case .findBar: return .findBar
        case .share: return .share
        case .addBookmarkChoice: return .addBookmarkChoice
        case .siteCapabilities: return .siteCapabilities
        }
    }

    var id: String { kind.rawValue }

    /// The overlay an identity stands for, when it can exist without a payload.
    ///
    /// The bookshelf cannot: it is only ever presented with the context it
    /// captured. Settings can, which is why opening it from the toolbar needs
    /// no destination.
    init?(kind: Kind) {
        switch kind {
        case .tabsOverview: self = .tabsOverview
        case .menu: self = .menu
        case .bookmarks: self = .bookmarks
        case .history: self = .history
        case .downloads: self = .downloads
        case .offlinePages: self = .offlinePages
        case .settings: self = .settings(nil)
        case .passwords: self = .passwords
        case .bookshelf: return nil
        case .qrScanner: self = .qrScanner
        case .findBar: self = .findBar
        case .share: self = .share
        case .addBookmarkChoice: self = .addBookmarkChoice
        case .siteCapabilities: self = .siteCapabilities
        }
    }
}

extension ShellOverlay: Hashable {
    /// Identity is the kind alone; the payload does not take part.
    static func == (lhs: ShellOverlay, rhs: ShellOverlay) -> Bool {
        lhs.kind == rhs.kind
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(kind)
    }
}
