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

    /// Commands the active page's user scripts registered with
    /// `GM_registerMenuCommand`. The menu panel lists them; they are cleared
    /// when the page navigates, because the functions live in that document.
    public var userScriptMenuCommands: [UserScriptMenuCommand] = []

    /// The fullscreen video presentation in progress, if any.
    ///
    /// The page owns the media element and its own controls; this value is
    /// what the shell draws over the promoted video, and what it sends
    /// playback commands back through. `nil` means no presentation.
    public var mediaFullscreen: MediaFullscreenSession?

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
    /// The tag of the element the user actually tapped, so the confirmation
    /// can name it instead of showing a bare selector.
    public var tagName: String = ""
    /// A short text preview from the element, for the same reason.
    public var textPreview: String = ""
}

/// A fullscreen video presentation the page asked for.
///
/// A value rather than a controller. The page keeps the `<video>` element and
/// the player around it; the app promotes that element to the viewport and
/// draws its own controls over it. Everything this type carries is reported by
/// the page, and every control the host shows is sent back as a
/// `MediaPlayerCommand`, which is what keeps the app out of the media pipeline
/// and lets the site's own JavaScript stay in charge.
public struct MediaFullscreenSession: Identifiable, Equatable, Sendable {
    public enum Mode: String, Sendable {
        /// A bare `<video>` with no player wrapper: the host draws controls.
        case video
        /// A player container — the page's own, or the wrapper the injected
        /// script found around the video — which carries its own chrome:
        /// progress bar, settings, captions. The host only offers a way out.
        case container
    }

    public let tabId: String
    public var mode: Mode
    public var title: String
    public var duration: Double
    public var currentTime: Double
    public var isPaused: Bool
    public var isMuted: Bool
    public var volume: Double
    public var isEnded: Bool
    public var isReady: Bool
    public var canSeek: Bool
    /// True when the page itself asked. A frame's request needs the top
    /// document to promote the frame element as well.
    public var isMainFrame: Bool

    public var id: String { tabId }

    public init(
        tabId: String,
        mode: Mode,
        title: String,
        duration: Double = 0,
        currentTime: Double = 0,
        isPaused: Bool = true,
        isMuted: Bool = false,
        volume: Double = 1,
        isEnded: Bool = false,
        isReady: Bool = false,
        canSeek: Bool = false,
        isMainFrame: Bool = true
    ) {
        self.tabId = tabId
        self.mode = mode
        self.title = title
        self.duration = duration
        self.currentTime = currentTime
        self.isPaused = isPaused
        self.isMuted = isMuted
        self.volume = volume
        self.isEnded = isEnded
        self.isReady = isReady
        self.canSeek = canSeek
        self.isMainFrame = isMainFrame
    }

    /// Builds a session from the page's `enter` message.
    public init?(tabId: String, payload: [String: Any], fallbackTitle: String, isMainFrame: Bool) {
        guard (payload["event"] as? String) == "enter" else { return nil }
        let mode = Mode(rawValue: payload["mode"] as? String ?? "video") ?? .video
        let duration = Self.sanitizedNumber(payload["duration"])
        self.init(
            tabId: tabId,
            mode: mode,
            title: Self.sanitizedTitle(payload["title"] as? String ?? "", fallback: fallbackTitle),
            duration: duration,
            currentTime: Self.clampedTime(
                Self.sanitizedNumber(payload["currentTime"]),
                duration: duration
            ),
            isPaused: Self.flag(payload["paused"]),
            isMuted: Self.flag(payload["muted"]),
            volume: min(max(0, Self.sanitizedNumber(payload["volume"])), 1),
            isReady: Self.sanitizedNumber(payload["readyState"]) >= 2,
            canSeek: Self.flag(payload["canSeek"]),
            isMainFrame: isMainFrame
        )
    }

    /// Applies a `state` message. Returns false for anything else, so a stale
    /// report from a page that has already left cannot overwrite this one.
    @discardableResult
    public mutating func applyState(_ payload: [String: Any]) -> Bool {
        guard (payload["event"] as? String) == "state" else { return false }
        let nextDuration = Self.sanitizedNumber(payload["duration"])
        if nextDuration > 0 { duration = nextDuration }
        let reportedTime = Self.sanitizedNumber(payload["currentTime"])
        currentTime = Self.clampedTime(reportedTime, duration: duration)
        isPaused = Self.flag(payload["paused"])
        isMuted = Self.flag(payload["muted"])
        volume = min(max(0, Self.sanitizedNumber(payload["volume"])), 1)
        isEnded = Self.flag(payload["ended"])
        isReady = Self.sanitizedNumber(payload["readyState"]) >= 2
        canSeek = Self.flag(payload["canSeek"])
        return true
    }

    /// A live stream has no duration, so its elapsed time must not be clamped
    /// to zero with it. A finite film is clamped to its own length.
    private static func clampedTime(_ value: Double, duration: Double) -> Double {
        let time = max(0, value)
        return duration > 0 ? min(time, duration) : time
    }

    private static func sanitizedNumber(_ value: Any?) -> Double {
        let number: Double
        if let value = value as? NSNumber { number = value.doubleValue }
        else if let value = value as? Double { number = value }
        else if let value = value as? Int { number = Double(value) }
        else { number = 0 }
        return number.isFinite ? number : 0
    }

    private static func flag(_ value: Any?) -> Bool {
        if let value = value as? Bool { return value }
        if let value = value as? NSNumber { return value.boolValue }
        return false
    }

    private static func sanitizedTitle(_ raw: String, fallback: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let value = trimmed.isEmpty ? fallback.trimmingCharacters(in: .whitespacesAndNewlines) : trimmed
        return String(value.prefix(120))
    }
}

/// A playback command the shell sends to the page's own player.
public enum MediaPlayerCommand: Sendable {
    case play
    case pause
    case togglePlay
    case seek(Double)
    case skip(Double)
    case setMuted(Bool)
    case setVolume(Double)
    case exit
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
