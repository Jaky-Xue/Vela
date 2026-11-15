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
        guard var payload = message.body as? [String: Any],
              let type = payload["type"] as? String,
              let scriptId = payload["scriptId"] as? String else { return }
        let contextKey = tab.id + "|" + scriptId
        guard settings.preferences.userScriptsEnabled, tab.privacyMode != .private,
              (message.frameInfo.isMainFrame || !((try? userScripts.script(id: scriptId))?.noframes ?? true)),
              let world = userScriptWorlds[contextKey], message.world.name == world,
              let script = try? userScripts.script(id: scriptId),
              script.updatedAt == userScriptVersions[contextKey],
              let frameURL = message.frameInfo.request.url,
              UserScriptMatcher.matches(script, url: frameURL)
        else { return }
        guard let token = payload["documentToken"] as? String, UUID(uuidString: token) != nil else { return }
        let frame = message.frameInfo
        let frameKey = contextKey + "|" + token
        if type == "authorize" {
            guard userScriptFrames.keys.filter({ $0.hasPrefix(tab.id + "|") }).count < 256 else { return }
            userScriptFrames[frameKey] = frame
            if UserScriptService.permitsPageWorld(script), settings.userScriptSettings.pageWorldApprovals?[script.id] == script.updatedAt {
                webView.evaluateJavaScript(UserScriptInjector.pageWorldSource(for: script), in: frame, in: .page) { _ in }
                return
            }
            let start = "if(window.__velaDocument === \(jsonLiteral(token))) { window.__velaStart(\(jsonLiteral(token))); }"
            webView.evaluateJavaScript(start, in: frame, in: .world(name: world)) { _ in }
            return
        }
        guard userScriptFrames[frameKey] != nil else { return }
        if let requestId = payload["requestId"] as? String,
           !requestId.hasPrefix(world + "|" + token + "|") { return }
        let probe = "JSON.stringify([window.__velaDocument,location.href])"
        webView.evaluateJavaScript(probe, in: frame, in: .world(name: world)) { [weak self, weak webView] result in
            guard let self, let webView, case let .success(value) = result,
                  let raw = value as? String, let data = raw.data(using: .utf8),
                  let current = try? JSONDecoder().decode([String].self, from: data), current.count == 2,
                  current[0] == token, let currentURL = URL(string: current[1]),
                  self.userScriptWorlds[contextKey] == world,
                  self.settings.preferences.userScriptsEnabled,
                  let live = try? self.userScripts.script(id: scriptId), live.enabled,
                  live.updatedAt == self.userScriptVersions[contextKey],
                  UserScriptMatcher.matches(live, url: currentURL),
                  self.tab(for: webView)?.privacyMode != .private else { return }
            payload["_world"] = world
            self.dispatchUserScriptMessage(payload, script: live, origin: currentURL, tab: tab, webView: webView, frame: frame)
        }
    }

    private func dispatchUserScriptMessage(_ original: [String: Any], script: InstalledUserScriptState, origin frameURL: URL,
                                          tab: BrowserTabState, webView: WKWebView, frame: WKFrameInfo) {
        var payload = original
        guard let type = payload["type"] as? String, let scriptId = payload["scriptId"] as? String,
              let world = payload["_world"] as? String else { return }
        let contextKey = tab.id + "|" + scriptId
        guard UserScriptNativePolicy.allows(type: type, payload: payload, script: script, origin: frameURL) else {
            if let requestId = payload["requestId"] as? String {
                resolveUserScript(scriptId: scriptId, requestId: requestId,
                                  payload: ["error": "脚本未获准执行该操作或访问目标域名"],
                                  in: webView, frame: frame)
            }
            return
        }
        // The bootstrap runs in every frame, and each frame keeps its own
        // resolver table. An answer has to go back to the frame that asked:
        // evaluating it in the handful of places below always targeted the
        // main frame, so a request a script made inside an iframe was answered
        // into a table that never held it, and the caller waited forever.
        payload["_world"] = world

        switch type {
        case "getValue", "getValues", "listValues":
            guard let requestId = payload["requestId"] as? String else { return }
            do {
                let snapshot = try userScripts.storageSnapshot(scriptId: scriptId)
                var values = snapshot.values
                if type == "listValues" {
                    resolveUserScript(scriptId: scriptId, requestId: requestId,
                        payload: ["keys": snapshot.values.keys.sorted(), "revision": snapshot.revision], in: webView, frame: frame)
                    return
                }
                if type == "getValue" {
                    guard let key = payload["key"] as? String else {
                        throw FilterError.invalid("GM.getValue 缺少键名")
                    }
                    values = snapshot.values[key].map { [key: $0] } ?? [:]
                }
                resolveUserScript(scriptId: scriptId, requestId: requestId,
                    payload: ["values": values, "revision": snapshot.revision], in: webView, frame: frame)
            } catch {
                resolveUserScript(scriptId: scriptId, requestId: requestId,
                    payload: ["error": error.localizedDescription], in: webView, frame: frame)
            }

        case "setValue", "deleteValue":
            guard let key = payload["key"] as? String else { return }
            var response: [String: Any] = ["success": true]
            do {
                if type == "setValue" {
                    guard let value = payload["value"] as? String else { throw FilterError.invalid("GM 值必须能被 JSON 编码") }
                    response["revision"] = try userScripts.setValue(value, key: key, scriptId: scriptId, origin: world + "|" + (payload["documentToken"] as? String ?? ""))
                } else { response["revision"] = try userScripts.removeValue(key: key, scriptId: scriptId, origin: world + "|" + (payload["documentToken"] as? String ?? "")) }
            } catch {
                response = ["error": error.localizedDescription]
                overlays.userScriptRuntimeErrors[contextKey] = "存储失败：" + error.localizedDescription
            }
            if let requestId = payload["requestId"] as? String {
                resolveUserScript(scriptId: scriptId, requestId: requestId, payload: response, in: webView, frame: frame)
            }

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
            let name = script.displayName + " · " + (payload["phase"] as? String ?? "脚本") + " · " + frameURL.absoluteString
            overlays.userScriptRuntimeErrors[contextKey] = name + "：" + String((payload["message"] as? String ?? "执行失败").prefix(512))

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
            userScriptCommandFrames[tab.id + "|" + scriptId + "|" + commandId] = frame

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

    /// All windows observe writes from the shared repository, then update only
    /// this script's live, eligible contexts. The sender already updates locally.
    func broadcastUserScriptValue(scriptId: String, key: String, value: String,
                                  origin: String, removed: Bool, reset: Bool, revision: Int) {
        guard settings.preferences.userScriptsEnabled,
              let installed = try? userScripts.script(id: scriptId), installed.enabled else { return }
        for (frameKey, frame) in userScriptFrames {
            let parts = frameKey.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
            guard parts.count == 3, parts[1] == scriptId else { continue }
            let context = parts[0] + "|" + scriptId
            guard let world = userScriptWorlds[context], world + "|" + parts[2] != origin,
                  let web = webView(for: parts[0]), let tab = tab(for: web), tab.privacyMode != .private,
                  installed.updatedAt == userScriptVersions[context],
                  let url = frame.request.url, UserScriptMatcher.matches(installed, url: url) else { continue }
            let source = "if(window.__velaDocument === \(jsonLiteral(parts[2]))) { window.__velaUserScriptBridge && window.__velaUserScriptBridge.applyValue && window.__velaUserScriptBridge.applyValue(\(jsonLiteral(key)), \(jsonLiteral(value)), \(removed ? "true" : "false"), \(reset ? "true" : "false"), \(revision), true); }"
            web.evaluateJavaScript(source, in: frame, in: .world(name: world)) { _ in }
        }
    }

    // MARK: - User-script runtime

    /// Resolves an asynchronous userscript API call in the frame that made it.
    ///
    /// The answer has to land in the caller's own `__velaUserScriptBridge`:
    /// every frame installs its own resolver table, and a request made from a
    /// subframe has no entry in the main frame's. When the frame is no longer
    /// addressable — a navigation replaced it while the request was in flight —
    /// the response is discarded. It never falls back to the page world.
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
        guard let frame, let tab = tab(for: webView),
              settings.preferences.userScriptsEnabled, tab.privacyMode != .private,
              let world = userScriptWorlds[tab.id + "|" + scriptId],
              requestId.hasPrefix(world + "|"),
              let installed = try? userScripts.script(id: scriptId), installed.enabled,
              installed.updatedAt == userScriptVersions[tab.id + "|" + scriptId],
              let currentURL = frame.request.url, UserScriptMatcher.matches(installed, url: currentURL) else { return }
        webView.evaluateJavaScript(script, in: frame, in: .world(name: world)) { _ in }
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
        guard let frame, let tab = tab(for: webView),
              settings.preferences.userScriptsEnabled, tab.privacyMode != .private,
              let world = userScriptWorlds[tab.id + "|" + scriptId],
              requestId.hasPrefix(world + "|"),
              let installed = try? userScripts.script(id: scriptId), installed.enabled,
              installed.updatedAt == userScriptVersions[tab.id + "|" + scriptId],
              let currentURL = frame.request.url, UserScriptMatcher.matches(installed, url: currentURL) else { return }
        webView.evaluateJavaScript(script, in: frame, in: .world(name: world)) { _ in }
    }

    /// Sends one userscript request. With progress requested the body is
    /// yielded as the server sends it; otherwise the whole response is taken
    /// in one go, which is cheaper and is what most scripts want.
    private func handleUserScriptDownload(_ payload: [String: Any], tab: BrowserTabState, webView: WKWebView, frame: WKFrameInfo?) {
        var request = payload
        request["method"] = "GET"; request["responseType"] = "arraybuffer"; request["_download"] = true
        handleUserScriptXHR(request, tab: tab, webView: webView, frame: frame)
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

        guard let installedScript = try? userScripts.script(id: scriptId),
              let origin = frame?.request.url else { return }
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
        let binaryBody = (payload["dataBase64"] as? String).flatMap { $0.isEmpty ? nil : Data(base64Encoded: $0) }
        guard (binaryBody?.count ?? body.utf8.count) <= 24_000_000 else {
            resolveUserScript(scriptId: scriptId, requestId: requestId, payload: ["error": "请求正文超过 24 MB"], in: webView, frame: frame); return
        }
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
                if let binaryBody { request.httpBody = binaryBody }
                else if !body.isEmpty {
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

                guard !Task.isCancelled,
                      self.userScriptWorlds[tab.id + "|" + scriptId] == payload["_world"] as? String,
                      self.settings.preferences.userScriptsEnabled,
                      (try? self.userScripts.script(id: scriptId))?.enabled == true else { return }
                var progress: (@MainActor @Sendable (Data, HTTPURLResponse?, Int) -> Void)?
                if reportsProgress || responseType == "stream" {
                    progress = { [weak self] chunk, response, received in
                        guard let self else { return }
                        let headers = (response?.allHeaderFields ?? [:]).map { "\($0.key): \($0.value)" }.joined(separator: "\n")
                        self.resolveUserScriptProgress(scriptId: scriptId, requestId: requestId,
                            payload: ["status": response?.statusCode ?? 0, "responseHeaders": headers,
                                      "finalUrl": response?.url?.absoluteString ?? url.absoluteString,
                                      "responseChunkBase64": chunk.base64EncodedString(), "loaded": received,
                                      "total": response?.expectedContentLength ?? -1], in: webView, frame: frame)
                    }
                }
                let (data, response) = try await UserScriptHTTP.load(request, script: installedScript, origin: origin,
                                                                   buffered: responseType != "stream", progress: progress)
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
                if payload["_download"] as? Bool == true {
                    guard let http, (200..<300).contains(http.statusCode) else { throw URLError(.badServerResponse) }
                    guard let token = payload["documentToken"] as? String,
                          let frame, let live = self.userScriptWorlds[tab.id + "|" + scriptId], live == payload["_world"] as? String else { return }
                    let current = try await webView.evaluateJavaScript("window.__velaDocument", in: frame, contentWorld: .world(name: live)) as? String
                    guard current == token, self.settings.preferences.userScriptsEnabled,
                          (try? self.userScripts.script(id: scriptId))?.enabled == true else { return }
                    let saved = try await self.downloads.saveScriptFile(data, response: response,
                        suggestedName: payload["name"] as? String ?? "", boundary: tab.dataBoundary)
                    result = ["taskId": saved.guid, "finalUrl": saved.finalUrl, "success": true]
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
                        && UserScriptNativePolicy.cookiePath(cookie.path, matches: path)
                        && (cookie.expiresDate.map { $0 > Date() } ?? true)
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
        var details = payload["details"] as? [String: Any] ?? [:]
        guard let origin = frame?.request.url else { return }
        details["url"] = origin.absoluteString
        let store = webView.configuration.websiteDataStore.httpCookieStore

        Task { @MainActor [weak self] in
            guard let self else { return }
            guard self.userScriptWorlds[tab.id + "|" + scriptId] == payload["_world"] as? String,
                  self.settings.preferences.userScriptsEnabled,
                  (try? self.userScripts.script(id: scriptId))?.enabled == true else { return }
            switch action {
            case "list":
                let all = await self.cookies(from: webView.configuration.websiteDataStore, for: origin)
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
                guard self.userScriptWorlds[tab.id + "|" + scriptId] == payload["_world"] as? String else { return }
                await self.setCookie(cookie, in: store)
                self.resolveUserScript(
                    scriptId: scriptId,
                    requestId: requestId,
                    payload: [:],
                    in: webView,
                    frame: frame
                )

            case "delete":
                let all = await self.cookies(from: webView.configuration.websiteDataStore, for: origin)
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
                    guard self.userScriptWorlds[tab.id + "|" + scriptId] == payload["_world"] as? String else { return }
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

    public func hasScriptFrame(id: String, tabId: String) -> Bool {
        userScriptFrames.keys.contains { $0.hasPrefix(tabId + "|" + id + "|") }
    }

    public func runMenuScript(id: String, tabId: String) {
        guard settings.preferences.userScriptsEnabled, let installed = try? userScripts.script(id: id),
              installed.enabled, !installed.runAt.injectsOnLoad, let target = webView(for: tabId),
              tab(for: target)?.privacyMode != .private,
              let world = userScriptWorlds[tabId + "|" + id], installed.updatedAt == userScriptVersions[tabId + "|" + id] else { return }
        for (key, frame) in userScriptFrames where key.hasPrefix(tabId + "|" + id + "|") {
            guard let url = frame.request.url, UserScriptMatcher.matches(installed, url: url) else { continue }
            let token = String(key.split(separator: "|").last ?? "")
            target.evaluateJavaScript("if(window.__velaDocument === \(jsonLiteral(token))) { window.__velaUserScriptBridge?.runMenuScript?.(); }", in: frame, in: .world(name: world)) { _ in }
        }
    }

    /// Runs a menu command a page's script registered.
    public func runUserScriptMenuCommand(_ command: UserScriptMenuCommand) {
        guard let target = webView(for: command.tabId) else { return }
        let script = """
        window.__velaUserScriptBridge && window.__velaUserScriptBridge.menuCommands &&
        window.__velaUserScriptBridge.menuCommands[\(jsonLiteral(command.commandId))] &&
        window.__velaUserScriptBridge.menuCommands[\(jsonLiteral(command.commandId))]();
        """
        let key = command.tabId + "|" + command.scriptId
        guard settings.preferences.userScriptsEnabled,
              let tab = tab(for: target), tab.privacyMode != .private,
              let installed = try? userScripts.script(id: command.scriptId), installed.enabled,
              installed.updatedAt == userScriptVersions[key],
              let world = userScriptWorlds[key],
              let frame = userScriptCommandFrames[key + "|" + command.commandId],
              let url = frame.request.url, UserScriptMatcher.matches(installed, url: url) else { return }
        let parts = command.commandId.split(separator: "|")
        guard parts.count >= 3 else { return }
        target.evaluateJavaScript("if(window.__velaDocument === \(jsonLiteral(String(parts[1])))) { \(script) }", in: frame, in: .world(name: world)) { _ in }
    }

}
