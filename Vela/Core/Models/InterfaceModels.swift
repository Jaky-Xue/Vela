//
//  InterfaceModels.swift
//  Vela
//
//  Layout selection and the keyboard commands the app exposes.
//
//  The phone layout is the original single-column browser. The iPad layout adds
//  a tab sidebar, a bookmarks bar and keyboard commands, and is chosen
//  automatically on a regular-width iPad unless the user pins one of the two.
//

import Foundation

/// Which chrome the shell draws.
public enum InterfaceLayoutMode: String, CaseIterable, Codable, Sendable, Identifiable {
    /// iPad in a regular-width window gets the two-column layout; everything
    /// else gets the phone layout.
    case automatic
    /// Always the single-column phone chrome.
    case phone
    /// Always the sidebar + bookmarks-bar chrome.
    case pad

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .automatic: return "跟随设备"
        case .phone: return "手机布局"
        case .pad: return "iPad 布局"
        }
    }

    public var detail: String {
        switch self {
        case .automatic:
            return "iPad 常规宽度使用双栏布局，手机和窄窗口使用单栏布局。"
        case .phone:
            return "始终使用单栏底部工具栏布局。"
        case .pad:
            return "始终使用侧边栏、书签栏和底部工具栏布局。"
        }
    }

    public var symbolName: String {
        switch self {
        case .automatic: return "rectangle.split.2x1"
        case .phone: return "iphone"
        case .pad: return "ipad"
        }
    }

    public static func resolve(_ rawValue: String?) -> InterfaceLayoutMode {
        guard let rawValue, let mode = InterfaceLayoutMode(rawValue: rawValue) else {
            return .automatic
        }
        return mode
    }
}

/// One keyboard command the app can perform.
///
/// The commands are declared once and dispatched through `BrowserCommandCenter`
/// so the `Commands` scene does not need a reference to the shell. Hardware
/// keyboards are useful on both idioms; the commands are not gated on iPad.
public enum BrowserCommand: String, CaseIterable, Sendable {
    case newTab
    case closeTab
    case reopenClosedTab
    case focusAddressBar
    case reload
    case back
    case findInPage
    case togglePrivate
    case nextTab
    case previousTab
    case bookmarks
    case history
    case downloads
    case settings
}
