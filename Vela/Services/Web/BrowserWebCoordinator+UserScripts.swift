//
//  BrowserWebCoordinator+UserScripts.swift
//  Vela
//
//  The user-script message channel: the GM value store's writes, clipboard and
//  notifications, and the asynchronous native bridge for requests, cookies,
//  downloads, tab state and menu commands.
//

import Foundation
import UIKit
import WebKit

extension BrowserWebCoordinator {
    func handleUserScriptMessage(_ message: WKScriptMessage, tab: BrowserTabState, webView: WKWebView) {
        guard let payload = message.body as? [String: Any],
              let type = payload["type"] as? String,
              let scriptId = payload["scriptId"] as? String else { return }
        // The bootstrap runs in every frame, and each frame keeps its own
        // resolver table. An answer has to go back to the frame that asked:
        // evaluating it in the handful of places below always targeted the
        // main frame, so a request a script made inside an iframe was answered
        // into a table that never held it, and the caller waited forever.
        let frame = message.frameInfo

        switch type {
        case "setValue":
            guard let key = payload["key"] as? String,
                  let value = payload["value"] as? String else { return }
            try? userScripts.setValue(value, key: key, scriptId: scriptId)

        case "deleteValue":
            guard let key = payload["key"] as? String else { return }
            try? userScripts.removeValue(key: key, scriptId: scriptId)

        case "setClipboard":
            guard let text = payload["text"] as? String else { return }
            UIPasteboard.general.string = text

        case "notification":
            // A script notification is surfaced through the app's own banner
            // rather than a page-level alert, so a script cannot block the page.
            if let text = payload["text"] as? String {
                retirePendingDialog()
                overlays.javascriptDialog = JavaScriptDialog(
                    kind: .alert,
                    message: text,
                    defaultText: "",
                    fromUserScript: true,
                    tabId: tab.id
                )
            }

        case "executionError":
            // Recorded rather than surfaced: a script error is the script
            // author's problem, and interrupting browsing with it would be
            // worse than the failure.
            break

        case "registerMenuCommand":
            guard let commandId = payload["commandId"] as? String,
                  let name = payload["name"] as? String else { return }
            let command = UserScriptMenuCommand(
                tabId: tab.id,
                scriptId: scriptId,
                scriptName: payload["scriptName"] as? String ?? "",
                commandId: commandId,
                name: name,
                accessKey: payload["accessKey"] as? String ?? ""
            )
            overlays.userScriptMenuCommands.removeAll {
                $0.tabId == tab.id && $0.scriptId == scriptId && $0.commandId == commandId
            }
            overlays.userScriptMenuCommands.append(command)

        case "unregisterMenuCommand":
            guard let commandId = payload["commandId"] as? String else { return }
            overlays.userScriptMenuCommands.removeAll {
                $0.tabId == tab.id && $0.scriptId == scriptId && $0.commandId == commandId
            }

        case "openInTab":
            guard let raw = payload["url"] as? String,
                  let url = URL(string: raw),
                  let scheme = url.scheme?.lowercased(),
                  scheme == "http" || scheme == "https" else { return }
            userScriptOpenTabHandler?(url, payload["active"] as? Bool ?? true, tab.privacyMode)

        case "download":
            handleUserScriptDownload(payload, tab: tab, webView: webView, frame: frame)

        case "xhr":
            handleUserScriptXHR(payload, tab: tab, webView: webView, frame: frame)

        case "xhrAbort":
            guard let requestId = payload["requestId"] as? String else { return }
            let key = "\(tab.id)|\(scriptId)|\(requestId)"
            userScriptXHRTasks.removeValue(forKey: key)?.cancel()
            resolveUserScript(
                scriptId: scriptId,
                requestId: requestId,
                payload: ["aborted": true],
                in: webView,
                frame: frame
            )

        case "cookie":
            handleUserScriptCookie(payload, tab: tab, webView: webView, frame: frame)

        case "getTab":
            guard let requestId = payload["requestId"] as? String else { return }
            resolveUserScript(
                scriptId: scriptId,
                requestId: requestId,
                payload: ["json": userScriptTabStates[tab.id] ?? "null"],
                in: webView,
                frame: frame
            )

        case "saveTab":
            if let json = payload["json"] as? String {
                userScriptTabStates[tab.id] = json
            }

        case "getTabs":
            guard let requestId = payload["requestId"] as? String else { return }
            resolveUserScript(
                scriptId: scriptId,
                requestId: requestId,
                payload: ["tabs": userScriptTabStates],
                in: webView,
                frame: frame
            )

        default:
            break
        }
    }

    // MARK: - User-script runtime

    /// Resolves an asynchronous userscript API call in the frame that made it.
    ///
    /// The answer has to land in the caller's own `__velaUserScriptBridge`:
    /// every frame installs its own resolver table, and a request made from a
    /// subframe has no entry in the main frame's. When the frame is no longer
    /// addressable — a navigation replaced it while the request was in flight —
    /// the main frame is the best remaining guess, and the call there simply
    /// finds no resolver.
    private func resolveUserScript(
        scriptId: String,
        requestId: String,
        payload: [String: Any],
        in webView: WKWebView,
        frame: WKFrameInfo? = nil
    ) {
        guard let data = try? JSONSerialization.data(withJSONObject: payload),
              let json = String(data: data, encoding: .utf8) else { return }
        let script = """
        window.__velaUserScriptBridge && window.__velaUserScriptBridge.resolve &&
        window.__velaUserScriptBridge.resolve(\(jsonLiteral(scriptId)), \(jsonLiteral(requestId)), \(json));
        """
        guard let frame else {
            webView.evaluateJavaScript(script, completionHandler: nil)
            return
        }
        webView.evaluateJavaScript(script, in: frame, in: .page) { [weak webView] result in
            guard case .failure = result, let webView else { return }
            webView.evaluateJavaScript(script, completionHandler: nil)
        }
    }

    /// Reports a streaming request's body so far to the waiting script.
    private func resolveUserScriptProgress(
        scriptId: String,
        requestId: String,
        payload: [String: Any],
        in webView: WKWebView,
        frame: WKFrameInfo?
    ) {
        guard let data = try? JSONSerialization.data(withJSONObject: payload),
              let json = String(data: data, encoding: .utf8) else { return }
        let script = """
        window.__velaUserScriptBridge && window.__velaUserScriptBridge.reportProgress &&
        window.__velaUserScriptBridge.reportProgress(\(jsonLiteral(scriptId)), \(jsonLiteral(requestId)), \(json));
        """
        guard let frame else {
            webView.evaluateJavaScript(script, completionHandler: nil)
            return
        }
        webView.evaluateJavaScript(script, in: frame, in: .page) { [weak webView] result in
            guard case .failure = result, let webView else { return }
            webView.evaluateJavaScript(script, completionHandler: nil)
        }
    }

    /// Sends one userscript request. With progress requested the body is
    /// yielded as the server sends it; otherwise the whole response is taken
    /// in one go, which is cheaper and is what most scripts want.
    private func streamUserScriptRequest(
        _ request: URLRequest,
        reportsProgress: Bool,
        onProgress: ((Data, HTTPURLResponse?) -> Void)?
    ) async throws -> (Data, URLResponse) {
        guard reportsProgress, let onProgress else {
            return try await URLSession.shared.data(for: request)
        }
        let (bytes, response) = try await URLSession.shared.bytes(for: request)
        let http = response as? HTTPURLResponse
        var buffer = Data()
        var lastReportedCount = 0
        var lastReportedAt = Date.distantPast
        for try await byte in bytes {
            buffer.append(byte)
            if buffer.count > 24_000_000 {
                throw URLError(.dataLengthExceedsMaximum)
            }
            if buffer.count % 65_536 == 0 {
                try Task.checkCancellation()
            }
            let now = Date()
            if buffer.count - lastReportedCount >= 512
                || now.timeIntervalSince(lastReportedAt) >= 0.12 {
                lastReportedCount = buffer.count
                lastReportedAt = now
                onProgress(buffer, http)
                try Task.checkCancellation()
            }
        }
        onProgress(buffer, http)
        return (buffer, response)
    }

    /// Starts a `GM_download` through the browser's own transfer engine.
    private func handleUserScriptDownload(
        _ payload: [String: Any],
        tab: BrowserTabState,
        webView: WKWebView,
        frame: WKFrameInfo?
    ) {
        guard let scriptId = payload["scriptId"] as? String,
              let requestId = payload["requestId"] as? String else { return }
        guard let raw = payload["url"] as? String,
              let url = URL(string: raw) else {
            resolveUserScript(
                scriptId: scriptId,
                requestId: requestId,
                payload: ["error": "无效的下载地址"],
                in: webView,
                frame: frame
            )
            return
        }
        let name = payload["name"] as? String ?? ""
        let task = downloads.enqueueScriptDownload(
            url: url,
            suggestedFileName: name,
            boundary: tab.dataBoundary,
            webView: webView
        )
        resolveUserScript(
            scriptId: scriptId,
            requestId: requestId,
            payload: ["taskId": task.guid],
            in: webView,
            frame: frame
        )
    }

    /// Performs a `GM_xmlhttpRequest` with the page's cookies and identity.
    ///
    /// URLSession is used rather than `fetch` on purpose: the grant exists to
    /// cross origins and carry the site's cookies, neither of which the page's
    /// own networking can do.
    private func handleUserScriptXHR(
        _ payload: [String: Any],
        tab: BrowserTabState,
        webView: WKWebView,
        frame: WKFrameInfo?
    ) {
        guard let scriptId = payload["scriptId"] as? String,
              let requestId = payload["requestId"] as? String,
              let rawURL = payload["url"] as? String,
              let url = URL(string: rawURL) else { return }

        let method = (payload["method"] as? String ?? "GET").uppercased()
        let responseType = payload["responseType"] as? String ?? ""
        let anonymous = payload["anonymous"] as? Bool ?? false
        // A script that passed `onprogress` expects the body in increments
        // while the response is still arriving — that is what lets a
        // streaming translator paint each sentence as it comes back rather
        // than after the whole answer closes.
        let reportsProgress = payload["progress"] as? Bool ?? false
        let headers = payload["headers"] as? [String: Any] ?? [:]
        let body = payload["data"] as? String ?? ""
        let timeoutMilliseconds = (payload["timeout"] as? NSNumber)?.doubleValue ?? 0
        let user = payload["user"] as? String ?? ""
        let password = payload["password"] as? String ?? ""
        let key = "\(tab.id)|\(scriptId)|\(requestId)"

        userScriptXHRTasks[key]?.cancel()
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                var request = URLRequest(url: url)
                request.httpMethod = method
                request.timeoutInterval = timeoutMilliseconds > 0
                    ? min(max(timeoutMilliseconds / 1000, 1), 120)
                    : 60
                for (name, value) in headers {
                    request.setValue(String(describing: value), forHTTPHeaderField: name)
                }
                if !body.isEmpty {
                    request.httpBody = body.data(using: .utf8)
                }
                if let agent = webView.customUserAgent, !agent.isEmpty {
                    request.setValue(agent, forHTTPHeaderField: "User-Agent")
                } else if let agent = (try? await webView.evaluateJavaScript("navigator.userAgent")) as? String,
                          !agent.isEmpty {
                    request.setValue(agent, forHTTPHeaderField: "User-Agent")
                }
                if let referer = webView.url?.absoluteString {
                    request.setValue(referer, forHTTPHeaderField: "Referer")
                }
                if !anonymous {
                    let cookies = await self.cookies(
                        from: webView.configuration.websiteDataStore,
                        for: url
                    )
                    for (name, value) in HTTPCookie.requestHeaderFields(with: cookies) {
                        if let existing = request.value(forHTTPHeaderField: name) {
                            request.setValue(existing + "; " + value, forHTTPHeaderField: name)
                        } else {
                            request.setValue(value, forHTTPHeaderField: name)
                        }
                    }
                }
                if !user.isEmpty {
                    let token = Data("\(user):\(password)".utf8).base64EncodedString()
                    request.setValue("Basic \(token)", forHTTPHeaderField: "Authorization")
                }

                var progress: ((Data, HTTPURLResponse?) -> Void)?
                if reportsProgress {
                    progress = { [weak self] buffer, response in
                        guard let self else { return }
                        // A chunk can end in the middle of a UTF-8 sequence;
                        // skipping that tick leaves the text valid, and the
                        // next cumulative report carries the character.
                        guard let text = String(data: buffer, encoding: .utf8), !text.isEmpty else { return }
                        let status = response?.statusCode ?? 0
                        let headerLines = (response?.allHeaderFields ?? [:])
                            .map { "\($0.key): \($0.value)" }
                            .joined(separator: "\n")
                        self.resolveUserScriptProgress(
                            scriptId: scriptId,
                            requestId: requestId,
                            payload: [
                                "status": status,
                                "statusText": response.map {
                                    HTTPURLResponse.localizedString(forStatusCode: $0.statusCode)
                                } ?? "",
                                "responseHeaders": headerLines,
                                "finalUrl": response?.url?.absoluteString ?? url.absoluteString,
                                "responseText": text
                            ],
                            in: webView,
                            frame: frame
                        )
                    }
                }
                let (data, response) = try await streamUserScriptRequest(
                    request,
                    reportsProgress: reportsProgress,
                    onProgress: progress
                )
                try Task.checkCancellation()
                if data.count > 24_000_000 {
                    throw URLError(.dataLengthExceedsMaximum)
                }
                let http = response as? HTTPURLResponse
                let headerLines = (http?.allHeaderFields ?? [:])
                    .map { "\($0.key): \($0.value)" }
                    .joined(separator: "\n")
                var result: [String: Any] = [
                    "status": http?.statusCode ?? 0,
                    "statusText": http.map {
                        HTTPURLResponse.localizedString(forStatusCode: $0.statusCode)
                    } ?? "",
                    "responseHeaders": headerLines,
                    "finalUrl": response.url?.absoluteString ?? url.absoluteString,
                    "mimeType": response.mimeType ?? ""
                ]
                if responseType == "arraybuffer" || responseType == "blob" {
                    result["responseBase64"] = data.base64EncodedString()
                    result["responseText"] = ""
                } else {
                    result["responseText"] = String(data: data, encoding: .utf8)
                        ?? String(data: data, encoding: .isoLatin1)
                        ?? ""
                }
                self.resolveUserScript(
                    scriptId: scriptId,
                    requestId: requestId,
                    payload: result,
                    in: webView,
                    frame: frame
                )
            } catch is CancellationError {
                self.resolveUserScript(
                    scriptId: scriptId,
                    requestId: requestId,
                    payload: ["aborted": true],
                    in: webView,
                    frame: frame
                )
            } catch {
                let nsError = error as NSError
                let timedOut = nsError.domain == NSURLErrorDomain
                    && nsError.code == NSURLErrorTimedOut
                self.resolveUserScript(
                    scriptId: scriptId,
                    requestId: requestId,
                    payload: [
                        "error": error.localizedDescription,
                        "timeout": timedOut
                    ],
                    in: webView,
                    frame: frame
                )
            }
            self.userScriptXHRTasks.removeValue(forKey: key)
        }
        userScriptXHRTasks[key] = task
    }

    private func cookies(
        from store: WKWebsiteDataStore,
        for url: URL
    ) async -> [HTTPCookie] {
        await withCheckedContinuation { continuation in
            store.httpCookieStore.getAllCookies { cookies in
                let host = url.host?.lowercased() ?? ""
                let path = url.path.isEmpty ? "/" : url.path
                let secure = url.scheme?.lowercased() == "https"
                let matching = cookies.filter { cookie in
                    let domain = cookie.domain
                        .lowercased()
                        .trimmingCharacters(in: CharacterSet(charactersIn: "."))
                    let hostMatches = cookie.domain.hasPrefix(".")
                        ? host == domain || host.hasSuffix("." + domain)
                        : host == domain
                    return hostMatches
                        && path.hasPrefix(cookie.path.isEmpty ? "/" : cookie.path)
                        && (!cookie.isSecure || secure)
                }
                continuation.resume(returning: matching)
            }
        }
    }

    private func handleUserScriptCookie(
        _ payload: [String: Any],
        tab: BrowserTabState,
        webView: WKWebView,
        frame: WKFrameInfo?
    ) {
        guard let scriptId = payload["scriptId"] as? String,
              let requestId = payload["requestId"] as? String,
              let action = payload["action"] as? String else { return }
        let details = payload["details"] as? [String: Any] ?? [:]
        let store = webView.configuration.websiteDataStore.httpCookieStore

        Task { @MainActor [weak self] in
            guard let self else { return }
            switch action {
            case "list":
                let all = await self.allCookies(from: store)
                let wantedDomain = (details["domain"] as? String)?.lowercased()
                let wantedURL = (details["url"] as? String).flatMap { URL(string: $0) }
                let wantedName = details["name"] as? String
                let filtered = all.filter { cookie in
                    if let wantedName, cookie.name != wantedName { return false }
                    if let wantedDomain {
                        let domain = cookie.domain.lowercased()
                        if domain != wantedDomain
                            && domain != "." + wantedDomain
                            && !domain.hasSuffix("." + wantedDomain) {
                            return false
                        }
                    }
                    if let wantedURL, let host = wantedURL.host?.lowercased() {
                        let domain = cookie.domain.lowercased()
                            .trimmingCharacters(in: CharacterSet(charactersIn: "."))
                        let hostMatches = cookie.domain.hasPrefix(".")
                            ? host == domain || host.hasSuffix("." + domain)
                            : host == domain
                        if !hostMatches { return false }
                    }
                    return true
                }
                self.resolveUserScript(
                    scriptId: scriptId,
                    requestId: requestId,
                    payload: ["cookies": filtered.map(Self.cookieJSON)],
                    in: webView,
                    frame: frame
                )

            case "set":
                guard let name = details["name"] as? String,
                      let value = details["value"] as? String else {
                    self.resolveUserScript(
                        scriptId: scriptId,
                        requestId: requestId,
                        payload: ["error": "Cookie 缺少 name 或 value"],
                        in: webView,
                        frame: frame
                    )
                    return
                }
                var properties: [HTTPCookiePropertyKey: Any] = [
                    .name: name,
                    .value: value
                ]
                let rawDomain = details["domain"] as? String
                let rawURL = details["url"] as? String
                if let rawDomain, !rawDomain.isEmpty {
                    properties[.domain] = rawDomain
                } else if let rawURL, let url = URL(string: rawURL), let host = url.host {
                    properties[.domain] = host
                    if (details["path"] as? String) == nil {
                        properties[.path] = url.path.isEmpty ? "/" : url.path
                    }
                } else {
                    self.resolveUserScript(
                        scriptId: scriptId,
                        requestId: requestId,
                        payload: ["error": "Cookie 缺少 domain 或 url"],
                        in: webView,
                        frame: frame
                    )
                    return
                }
                properties[.path] = details["path"] as? String ?? "/"
                if let expires = (details["expirationDate"] as? NSNumber)?.doubleValue {
                    properties[.expires] = Date(timeIntervalSince1970: expires)
                }
                if let secure = details["secure"] as? Bool {
                    properties[.secure] = secure ? "TRUE" : "FALSE"
                }
                if let httpOnly = details["httpOnly"] as? Bool, httpOnly {
                    properties[HTTPCookiePropertyKey("HttpOnly")] = "TRUE"
                }
                guard let cookie = HTTPCookie(properties: properties) else {
                    self.resolveUserScript(
                        scriptId: scriptId,
                        requestId: requestId,
                        payload: ["error": "Cookie 属性无效"],
                        in: webView,
                        frame: frame
                    )
                    return
                }
                await self.setCookie(cookie, in: store)
                self.resolveUserScript(
                    scriptId: scriptId,
                    requestId: requestId,
                    payload: [:],
                    in: webView,
                    frame: frame
                )

            case "delete":
                let all = await self.allCookies(from: store)
                let wantedName = details["name"] as? String
                let wantedDomain = (details["domain"] as? String)?.lowercased()
                let wantedURL = (details["url"] as? String).flatMap { URL(string: $0) }
                for cookie in all {
                    if let wantedName, cookie.name != wantedName { continue }
                    if let wantedDomain {
                        let domain = cookie.domain.lowercased()
                        if domain != wantedDomain && domain != "." + wantedDomain
                            && !domain.hasSuffix("." + wantedDomain) {
                            continue
                        }
                    }
                    if let wantedURL, let host = wantedURL.host?.lowercased() {
                        let domain = cookie.domain.lowercased()
                            .trimmingCharacters(in: CharacterSet(charactersIn: "."))
                        let hostMatches = cookie.domain.hasPrefix(".")
                            ? host == domain || host.hasSuffix("." + domain)
                            : host == domain
                        if !hostMatches { continue }
                    }
                    await self.deleteCookie(cookie, from: store)
                }
                self.resolveUserScript(
                    scriptId: scriptId,
                    requestId: requestId,
                    payload: [:],
                    in: webView,
                    frame: frame
                )

            default:
                self.resolveUserScript(
                    scriptId: scriptId,
                    requestId: requestId,
                    payload: ["error": "未知的 Cookie 操作"],
                    in: webView,
                    frame: frame
                )
            }
        }
    }

    private func allCookies(from store: WKHTTPCookieStore) async -> [HTTPCookie] {
        await withCheckedContinuation { continuation in
            store.getAllCookies { continuation.resume(returning: $0) }
        }
    }

    private func setCookie(_ cookie: HTTPCookie, in store: WKHTTPCookieStore) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            store.setCookie(cookie) { continuation.resume() }
        }
    }

    private func deleteCookie(_ cookie: HTTPCookie, from store: WKHTTPCookieStore) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            store.delete(cookie) { continuation.resume() }
        }
    }

    private static func cookieJSON(_ cookie: HTTPCookie) -> [String: Any] {
        var value: [String: Any] = [
            "name": cookie.name,
            "value": cookie.value,
            "domain": cookie.domain,
            "path": cookie.path,
            "secure": cookie.isSecure,
            "httpOnly": cookie.isHTTPOnly,
            "session": cookie.isSessionOnly,
            "hostOnly": !cookie.domain.hasPrefix(".")
        ]
        if let expires = cookie.expiresDate {
            value["expirationDate"] = expires.timeIntervalSince1970
        }
        return value
    }

    /// Runs a menu command a page's script registered.
    public func runUserScriptMenuCommand(_ command: UserScriptMenuCommand) {
        guard let target = webView(for: command.tabId) else { return }
        let script = """
        window.__velaUserScriptBridge && window.__velaUserScriptBridge.menuCommands &&
        window.__velaUserScriptBridge.menuCommands[\(jsonLiteral(command.commandId))] &&
        window.__velaUserScriptBridge.menuCommands[\(jsonLiteral(command.commandId))]();
        """
        target.evaluateJavaScript(script, completionHandler: nil)
    }

}
