//
//  NavigationLog.swift
//  Vela
//
//  A structured, in-memory record of what happened to each navigation.
//
//  The question this exists to answer is the one a browser cannot be debugged
//  without: *which* page, at *which* phase, failed, and *why*. Before it, a
//  failed load left a string on the tab that nothing rendered and nothing kept,
//  so the only way to find out what went wrong was to guess.
//
//  Two properties are load-bearing:
//
//    * It is never persisted. There is no file, no database row and no
//      `UserDefaults` entry — the ring buffer lives in the process and dies with
//      it. That is what makes it safe to record navigations in a private session:
//      there is nothing for a private session's data to leak into.
//    * URLs are redacted before they are stored. A query string is where a
//      search term, a session token or an email address ends up, and none of
//      that belongs in a log the user can share with a bug report. The shape of
//      a URL — scheme, host, path, how many query parameters it carried — is
//      enough to identify the page and is what is kept.
//
//  Cookies, `Authorization` headers, form contents and page text are not
//  recorded at all; nothing here can read them.
//

import Foundation
import Observation

/// What happened.
public enum NavigationEvent: String, Codable, Sendable, CaseIterable {
    /// The app handed WebKit a request.
    case requested
    /// `didStartProvisionalNavigation`.
    case start
    /// `didReceiveServerRedirectForProvisionalNavigation`.
    case redirect
    /// `didCommit`.
    case commit
    /// `didFinish`.
    case finish
    /// `didFailProvisionalNavigation` or `didFail`.
    case fail
    /// The navigation was stopped deliberately — by the user, or by the app
    /// declining to load it.
    case cancel
    /// The web content process died.
    case crash
    /// The main document's HTTP status was recorded.
    case httpStatus
    /// A `target="_blank"` link or `window.open` was turned into a new tab.
    case newTab
    /// A non-`http(s)` scheme was handed to the system, or blocked.
    case externalScheme
}

/// Whether the entry describes something that worked, something that did not, or
/// neither.
public enum NavigationOutcome: String, Codable, Sendable {
    case ok
    case failure
    case cancelled
    case info
}

/// One navigation event.
public struct NavigationLogEntry: Identifiable, Sendable {
    /// Monotonic, and only unique within a process lifetime.
    public let id: Int
    public let at: Date
    public var tabId: String
    /// Which navigation this belongs to. Assigned when the navigation starts, so
    /// every event for one navigation carries the same number.
    public var navigationSerial: Int
    public var event: NavigationEvent
    /// The tab's load state as the event was recorded, i.e. what the event left
    /// behind.
    public var phase: TabLoadState
    /// The redacted URL. Never the raw one.
    public var url: String
    /// The raw scheme, which is not sensitive and is what tells `http` from
    /// `https` in the log.
    public var scheme: String
    /// `WKNavigationType` as a string, e.g. `linkActivated`.
    public var navigationType: String
    /// Milliseconds from the navigation's start to this event, when the start is
    /// known.
    public var durationMs: Int?
    /// The redacted URL the navigation ended on, when it differed.
    public var finalUrl: String?
    public var errorDomain: String
    public var errorCode: Int
    /// The localized description WebKit supplied, truncated. WebKit's own
    /// messages name a host and a reason and do not carry page content.
    public var errorMessage: String
    public var outcome: NavigationOutcome
    /// Whether ad blocking and user scripts were contributing to this load. Part
    /// of every entry because "does turning it off change anything" is the first
    /// question asked of a page that will not load.
    public var adBlockActive: Bool
    public var userScriptsActive: Bool

    /// A one-line rendering for the diagnostics screen and the copied report.
    public var displayLine: String {
        var parts = [
            Self.timeFormatter.string(from: at),
            "#\(navigationSerial)",
            event.rawValue,
            phase.rawValue
        ]
        if let durationMs { parts.append("\(durationMs)ms") }
        parts.append(url)
        if !errorDomain.isEmpty {
            parts.append("\(errorDomain)/\(errorCode)")
        }
        if !errorMessage.isEmpty {
            parts.append(errorMessage)
        }
        return parts.joined(separator: "  ")
    }

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"
        return formatter
    }()
}

/// The settings that gate the log.
///
/// One switch, and deliberately no second "detailed" level. A level implies
/// something is held back at the lower setting, and nothing here is: the entries
/// are a handful per navigation, every one of them already reduced to a
/// non-sensitive shape, and a page's failure is usually explained by the event
/// the "quiet" setting would have dropped. Inventing a switch that gates nothing
/// would be worse than not having it.
public struct NavigationDiagnosticsSettings: Codable, Equatable, Sendable {
    /// Whether the log records anything at all.
    public var enabled: Bool

    public init(enabled: Bool = true) {
        self.enabled = enabled
    }

    public static let `default` = NavigationDiagnosticsSettings()
}

@MainActor
@Observable
public final class NavigationLog {
    /// How many entries are kept.
    ///
    /// A hundred and twenty is a few dozen navigations' worth — enough to
    /// reconstruct what happened before a page broke, small enough that the
    /// buffer is never a memory consideration.
    public static let capacity = 120

    public private(set) var entries: [NavigationLogEntry] = []

    public var settings: NavigationDiagnosticsSettings

    private var nextId = 1

    public init(settings: NavigationDiagnosticsSettings = .default) {
        self.settings = settings
    }

    public func record(
        tabId: String,
        navigationSerial: Int,
        event: NavigationEvent,
        phase: TabLoadState,
        url: String,
        navigationType: String = "",
        durationMs: Int? = nil,
        finalUrl: String? = nil,
        errorDomain: String = "",
        errorCode: Int = 0,
        errorMessage: String = "",
        outcome: NavigationOutcome = .info,
        adBlockActive: Bool = false,
        userScriptsActive: Bool = false
    ) {
        guard settings.enabled else { return }

        let entry = NavigationLogEntry(
            id: nextId,
            at: Date(),
            tabId: tabId,
            navigationSerial: navigationSerial,
            event: event,
            phase: phase,
            url: Self.redact(url),
            scheme: Self.scheme(of: url),
            navigationType: navigationType,
            durationMs: durationMs,
            finalUrl: finalUrl.map(Self.redact),
            errorDomain: errorDomain,
            errorCode: errorCode,
            errorMessage: Self.truncate(errorMessage, to: 160),
            outcome: outcome,
            adBlockActive: adBlockActive,
            userScriptsActive: userScriptsActive
        )
        nextId += 1

        entries.append(entry)
        if entries.count > Self.capacity {
            entries.removeFirst(entries.count - Self.capacity)
        }
    }

    public func clear() {
        entries = []
    }

    /// The entries as shareable text, newest last.
    ///
    /// This is what the diagnostics screen copies. It contains only what
    /// `record` stored, which is already redacted — there is no second, more
    /// revealing rendering to accidentally hand out.
    public func report() -> String {
        guard !entries.isEmpty else { return "没有导航记录。" }
        return entries.map(\.displayLine).joined(separator: "\n")
    }

    // MARK: - Redaction

    /// The scheme of a raw URL string, without parsing the rest of it.
    public static func scheme(of raw: String) -> String {
        guard let colon = raw.firstIndex(of: ":") else { return "" }
        let candidate = String(raw[raw.startIndex..<colon]).lowercased()
        guard let first = candidate.first, first.isLetter else { return "" }
        return candidate
    }

    /// Strips a URL down to what identifies the page and nothing more.
    ///
    /// Kept: scheme, host, port, path. Dropped: userinfo (which is where a
    /// credential lives), the fragment, and every query value — the query is
    /// replaced by a count of its parameters, because "this URL carried four
    /// parameters" is diagnostic and "this URL carried `?q=…`" is not.
    ///
    /// A parse failure returns the scheme and a placeholder rather than the
    /// original string: an unparseable URL is exactly the sort of thing that
    /// carries something unexpected.
    public static func redact(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }

        if let components = URLComponents(string: trimmed), components.scheme != nil {
            var text = components.scheme.map { $0 + "://" } ?? ""
            if let host = components.host {
                text += host
                if let port = components.port { text += ":\(port)" }
            } else if let path = components.path.isEmpty ? nil : components.path {
                // A scheme with no authority: `mailto:someone@example.com`,
                // `data:text/html,…`. Only the scheme is safe to keep.
                return "\(components.scheme ?? ""):<\(path.count) 字符>"
            }
            text += components.percentEncodedPath
            let itemCount = components.queryItems?.count ?? 0
            if itemCount > 0 { text += "?<\(itemCount) 个参数>" }
            if components.fragment != nil { text += "#<片段>" }
            return text
        }

        // Not a URL. Record the shape, not the text.
        let scheme = scheme(of: trimmed)
        return scheme.isEmpty ? "<\(trimmed.count) 字符>" : "\(scheme):<\(trimmed.count) 字符>"
    }

    private static func truncate(_ value: String, to limit: Int) -> String {
        value.count <= limit ? value : String(value.prefix(limit)) + "…"
    }
}
