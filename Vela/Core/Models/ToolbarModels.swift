//
//  ToolbarModels.swift
//  Vela
//
//  The bottom bar's controls, and the order the user put them in.
//
//  The omnibox is fixed at the centre — it is the bar's subject, not one of
//  its buttons — and the two clusters around it are made of controls the user
//  chooses and drags. A preference therefore has to name the controls and
//  their order, not merely toggle a fixed set, which is what this type is for.
//
//  Stored as raw-value strings inside two optional arrays in the preferences
//  document. Unknown values are dropped on read rather than trusted: a build
//  can remove a control without leaving an old install with a gap in its bar.
//

import Foundation

/// One control the bottom bar can host.
enum ToolbarControl: String, CaseIterable, Codable, Sendable, Identifiable, Hashable {
    case back
    case home
    case tabs
    case menu
    case bookmarks
    case history
    case downloads
    case reader
    case novel
    case bookshelf
    case passwords
    case share
    case reload
    case find
    case settings
    case adBlock
    case privateMode

    var id: String { rawValue }

    var title: String {
        switch self {
        case .back: return "后退"
        case .home: return "主页"
        case .tabs: return "标签页"
        case .menu: return "菜单"
        case .bookmarks: return "书签"
        case .history: return "历史记录"
        case .downloads: return "下载"
        case .reader: return "文章阅读"
        case .novel: return "小说模式"
        case .bookshelf: return "书架"
        case .passwords: return "密码"
        case .share: return "分享"
        case .reload: return "刷新"
        case .find: return "查找"
        case .settings: return "设置"
        case .adBlock: return "广告过滤"
        case .privateMode: return "无痕模式"
        }
    }

    /// The glyph used in the settings picker. The bar draws its own tab-count
    /// badge for `tabs` and uses the SF Symbol below for every other control.
    var symbolName: String {
        switch self {
        case .back: return "chevron.left"
        case .home: return "house"
        case .tabs: return "square.on.square"
        case .menu: return "ellipsis"
        case .bookmarks: return "book"
        case .history: return "clock.arrow.circlepath"
        case .downloads: return "arrow.down.circle"
        case .reader: return "doc.plaintext"
        case .novel: return "text.book.closed"
        case .bookshelf: return "books.vertical"
        case .passwords: return "key.fill"
        case .share: return "square.and.arrow.up"
        case .reload: return "arrow.clockwise"
        case .find: return "magnifyingglass"
        case .settings: return "gearshape"
        case .adBlock: return "shield.lefthalf.filled"
        case .privateMode: return "eyeglasses"
        }
    }

    /// Whether the control needs a loaded page to have an effect.
    var requiresPage: Bool {
        switch self {
        case .share, .reader, .novel, .find, .reload:
            return true
        default:
            return false
        }
    }
}

/// Which side of the omnibox a control sits on.
enum ToolbarSide: String, CaseIterable, Identifiable {
    case leading
    case trailing

    var id: String { rawValue }

    var title: String {
        switch self {
        case .leading: return "左侧"
        case .trailing: return "右侧"
        }
    }
}

/// The user's arrangement of the two clusters.
struct ToolbarLayout: Equatable, Sendable {
    /// Five controls a side is the point at which the omnibox still reads as
    /// a field rather than a sliver. The cap is enforced on read as well as in
    /// the editor, so a hand-edited preferences document cannot squeeze it.
    static let maximumPerSide = 5

    static let defaultLeading: [ToolbarControl] = [.back]
    static let defaultTrailing: [ToolbarControl] = [.tabs, .menu]
    /// The iPad top bar keeps the sidebar toggle and menu fixed; these are the
    /// user-controlled parts around the field.
    static let defaultPadLeading: [ToolbarControl] = [.back]
    static let defaultPadTrailing: [ToolbarControl] = [.share, .tabs]

    var leading: [ToolbarControl]
    var trailing: [ToolbarControl]

    init(leading: [ToolbarControl] = ToolbarLayout.defaultLeading,
         trailing: [ToolbarControl] = ToolbarLayout.defaultTrailing) {
        let lead = Array(leading.prefix(Self.maximumPerSide))
        self.leading = lead
        self.trailing = Array(trailing.filter { !lead.contains($0) }.prefix(Self.maximumPerSide))
    }

    /// Reads the two stored arrays, falling back to the shipped layout for a
    /// side that has never been written.
    init(
        storedLeading: [String]?,
        storedTrailing: [String]?,
        defaultLeading: [ToolbarControl] = ToolbarLayout.defaultLeading,
        defaultTrailing: [ToolbarControl] = ToolbarLayout.defaultTrailing
    ) {
        let leadRaw = storedLeading ?? defaultLeading.map(\.rawValue)
        let trailRaw = storedTrailing ?? defaultTrailing.map(\.rawValue)
        self.init(
            leading: Self.decode(leadRaw),
            trailing: Self.decode(trailRaw)
        )
    }

    /// The same layout with one side replaced, used by the settings editor.
    func replacing(_ side: ToolbarSide, with controls: [ToolbarControl]) -> ToolbarLayout {
        switch side {
        case .leading:
            return ToolbarLayout(leading: controls, trailing: trailing)
        case .trailing:
            return ToolbarLayout(leading: leading, trailing: controls)
        }
    }

    func controls(for side: ToolbarSide) -> [ToolbarControl] {
        side == .leading ? leading : trailing
    }

    /// Controls not on the bar, in catalogue order — the choices the editor
    /// offers to add.
    var availableControls: [ToolbarControl] {
        ToolbarControl.allCases.filter { !leading.contains($0) && !trailing.contains($0) }
    }

    private static func decode(_ raw: [String]) -> [ToolbarControl] {
        var seen = Set<ToolbarControl>()
        var decoded: [ToolbarControl] = []
        for value in raw {
            guard let control = ToolbarControl(rawValue: value), !seen.contains(control) else { continue }
            seen.insert(control)
            decoded.append(control)
        }
        return decoded
    }
}
