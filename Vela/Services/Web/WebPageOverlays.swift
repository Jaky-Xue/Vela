//
//  WebPageOverlays.swift
//  Vela
//
//  The transient chrome the shell draws over a page: the native stand-ins for a
//  page's own dialogs, the external-navigation prompt, the media-capture prompt,
//  the file picker, the find bar and the element picker.
//
//  These live apart from the web engine deliberately. Each one is a value the
//  shell renders and the user answers, so a view that shows a dialog should
//  observe the dialog state and nothing else. Holding them on the engine made
//  every view that read one of them depend on the whole WebKit surface, and made
//  the engine the busiest observable in the app for no reason beyond convenience.
//
//  The split follows the same line WebKit does: `WKNavigationDelegate` and
//  `WKUIDelegate` hand a question to the app, and the answer is a value the UI
//  owns. The delegate methods stay on the engine; the values land here.
//

import Foundation
import WebKit
import Observation

@MainActor
@Observable
public final class WebPageOverlays {
    /// An `alert` / `confirm` / `prompt` a page raised, held until the user
    /// answers the shell's dialog.
    public var javascriptDialog: JavaScriptDialog?

    /// A non-`http(s)` URL the page asked to open, held while the policy is
    /// `ask`. A policy of `allow` or `block` never reaches here.
    public var externalNavigation: ExternalNavigationRequest?

    /// A camera or microphone request waiting on the user.
    public var permissionRequest: SitePermissionRequest?

    /// The element the user picked while the picker was armed.
    public var elementPick: ElementPickResult?

    /// A file upload the page is blocked on. The shell presents the picker and
    /// then calls the stored handler.
    public var fileUpload: FileUploadRequest?

    /// Find-in-page state, read by the find bar.
    public var findResult = FindResult(count: 0, index: -1)

    /// Element picker mode. Armed by the shell, consumed on the next pick.
    public var isElementPickerArmed = false

    /// `alert` / `confirm` / `prompt` completion handlers.
    ///
    /// WebKit blocks the page on these, so the handler is held until the user
    /// answers. They sit next to the dialog they belong to rather than on the
    /// engine, so there is one place that owns the lifetime of a prompt.
    var javascriptAlertCompletion: (() -> Void)?
    var javascriptConfirmCompletion: ((Bool) -> Void)?
    var javascriptPromptCompletion: ((String?) -> Void)?

    public init() {}
}

// MARK: - Overlay values

/// A page-originated dialog waiting for the shell to render it.
public struct JavaScriptDialog: Identifiable, Equatable, Sendable {
    public enum Kind: String, Sendable {
        case alert
        case confirm
        case prompt
    }

    public let id = UUID()
    public var kind: Kind
    public var message: String
    public var defaultText: String
    /// True when a user script raised it, which the shell labels differently so
    /// the user knows the page is not the source.
    public var fromUserScript: Bool
    public var tabId: String
}

/// A navigation the page asked for that would leave the browser.
public struct ExternalNavigationRequest: Identifiable, Sendable {
    public let id = UUID()
    public var url: URL
    public var sourceHost: String
    public var tabId: String

    /// The scheme's human name, used by the prompt copy.
    public var displayScheme: String {
        url.scheme?.lowercased() ?? "unknown"
    }
}

/// A camera or microphone request holding WebKit's decision handler.
public struct SitePermissionRequest: Identifiable {
    public let id = UUID()
    public var origin: String
    public var kind: SitePermissionKind
    public var decisionHandler: (WKPermissionDecision) -> Void
}

/// A file upload holding the completion handler the page is blocked on.
public struct FileUploadRequest: Identifiable {
    public let id = UUID()
    public var allowsMultipleSelection: Bool
    public var completionHandler: ([URL]?) -> Void
}

/// What the element picker reported for a tap.
public struct ElementPickResult: Identifiable, Sendable {
    public let id = UUID()
    public var selector: String
    public var host: String
    public var matchedElementCount: Int
}

/// The find bar's position in the page's matches.
public struct FindResult: Equatable, Sendable {
    public var count: Int
    public var index: Int

    public var displayText: String {
        guard count > 0, index >= 0 else { return "无结果" }
        return "\(index + 1)/\(count)"
    }
}
