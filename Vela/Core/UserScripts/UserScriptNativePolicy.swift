import Foundation

/// Host checks remain authoritative even when a script calls postMessage directly.
enum UserScriptNativePolicy {
    static func allows(type: String, payload: [String: Any], script: InstalledUserScriptState, origin: URL) -> Bool {
        let required: [String: [UserScriptGrant]] = [
            "getValue": [.gmGetValue], "getValues": [.gmGetValues], "listValues": [.gmListValues],
            "setValue": [.gmSetValue, .gmSetValues], "deleteValue": [.gmDeleteValue, .gmDeleteValues],
            "setClipboard": [.gmSetClipboard], "notification": [.gmNotification],
            "registerMenuCommand": [.gmRegisterMenuCommand], "unregisterMenuCommand": [.gmUnregisterMenuCommand],
            "openInTab": [.gmOpenInTab], "download": [.gmDownload],
            "xhr": [.gmXmlhttpRequest, .gmFetch], "xhrAbort": [.gmXmlhttpRequest, .gmFetch],
            "getTab": [.gmGetTab], "saveTab": [.gmSaveTab], "getTabs": [.gmGetTabs]
        ]
        if type == "download" { return false } // Transfer engine lacks redirect permission hooks.
        if type == "executionError" { return true }
        if type == "cookie" {
            let action = payload["action"] as? String ?? ""
            let grant: UserScriptGrant = action == "set" ? .gmCookieSet : .gmCookieDelete
            guard script.grants.contains(.gmCookie) || (action != "list" && script.grants.contains(grant)) else { return false }
            guard ["list", "set", "delete"].contains(action), let host = origin.host?.lowercased() else { return false }
            let details = payload["details"] as? [String: Any] ?? [:]
            if let domain = details["domain"] as? String,
               domain.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ".")) != host { return false }
            if let raw = details["url"] as? String,
               URL(string: raw)?.host?.lowercased() != host { return false }
            return true
        }
        guard let grants = required[type], grants.contains(where: script.grants.contains) else { return false }
        if type == "xhr" || type == "download" {
            guard let raw = payload["url"] as? String, let url = URL(string: raw),
                  allowsConnection(to: url, script: script, origin: origin) else { return false }
        }
        return true
    }

    static func allowsConnection(to url: URL, script: InstalledUserScriptState, origin: URL) -> Bool {
        guard ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
              let host = url.host?.lowercased(), url.user == nil, url.password == nil else { return false }
        return script.connectRules.contains { raw in
            let rule = raw.lowercased()
            if rule == "*" { return true }
            if rule == "self" { return host == origin.host?.lowercased() }
            let domain = rule.hasPrefix("*.") ? String(rule.dropFirst(2)) : rule
            return host == domain || host.hasSuffix("." + domain)
        }
    }

    static func cookiePath(_ cookiePath: String, matches path: String) -> Bool {
        let scope = cookiePath.isEmpty ? "/" : cookiePath
        return path == scope || (path.hasPrefix(scope) && (scope.hasSuffix("/") || path.dropFirst(scope.count).hasPrefix("/")))
    }
}

/// Cross-origin redirects are declined because inherited Cookie/Authorization
/// headers must never be forwarded to another origin. Same-origin hops still
/// have to satisfy @connect. A caller can request an allowed new origin directly.
final class UserScriptRedirectPolicy: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    let script: InstalledUserScriptState
    let origin: URL
    init(script: InstalledUserScriptState, origin: URL) { self.script = script; self.origin = origin }

    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        guard let source = response.url, let target = request.url,
              source.scheme == target.scheme, source.host == target.host, source.port == target.port,
              UserScriptNativePolicy.allowsConnection(to: target, script: script, origin: origin) else {
            completionHandler(nil); return
        }
        completionHandler(request)
    }
}
