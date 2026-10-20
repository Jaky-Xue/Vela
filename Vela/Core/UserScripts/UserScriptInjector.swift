//
//  UserScriptInjector.swift
//  Vela
//
//  Builds the `WKUserScript` objects that run installed user scripts.
//
//  The hard part is that `GM_getValue` is synchronous in the userscript API
//  while `WKScriptMessageHandler` is asynchronous. The solution — the one every
//  iOS userscript manager arrives at — is to snapshot the whole value store into
//  the page at document start, read from that snapshot, and write changes back
//  through the message bridge. A script that sets a value and reads it back in
//  the same tick therefore sees its own write, which is the behaviour scripts
//  actually depend on.
//
//  Asynchronous grants — GM_xmlhttpRequest, GM_fetch, GM_cookie, GM_openInTab,
//  GM_download and the per-tab store — keep a resolver in
//  `window.__velaUserScriptBridge.resolvers`, keyed by script and request id.
//  The host evaluates `__velaUserScriptBridge.resolve(scriptId, requestId,
//  payload)` when the native side has an answer. The bridge is shared by every
//  script on the page; each script gets its own resolver table.
//

import Foundation
import WebKit

public enum UserScriptInjector {
    /// The message-handler name the injected bridge posts to.
    public static let messageHandlerName = "velaUserScript"

    /// The names a script may use to reach the page's real `window`, and the
    /// object the bridge hangs itself off.
    public static let bridgeGlobalName = "__velaUserScriptBridge"

    /// Builds the `WKUserScript` set for one navigation.
    ///
    /// - Parameter valuesByScriptId: the GM_ store snapshot per script id.
    /// - Parameter tabId: the tab the page belongs to, used by the per-tab
    ///   `GM_getTab` / `GM_saveTab` store.
    /// - Returns: scripts ready to attach to a `WKUserContentController`, plus a
    ///   summary of what was injected.
    public static func makeUserScripts(
        for scripts: [InstalledUserScriptState],
        url: URL,
        valuesByScriptId: [String: [String: String]],
        tabId: String = ""
    ) -> (scripts: [WKUserScript], summary: UserScriptInjectionSummary) {
        var built: [WKUserScript] = []
        let failed: [String] = []

        for script in scripts {
            guard script.runAt.injectsOnLoad else { continue }

            let values = valuesByScriptId[script.id] ?? [:]
            let source = bootstrapSource(
                for: script,
                valuesJSON: encodeValues(values),
                tabId: tabId
            )

            let injectionTime: WKUserScriptInjectionTime =
                script.runAt == .documentStart ? .atDocumentStart : .atDocumentEnd

            // A `@noframes` script runs in the top frame only. WebKit decides
            // this per frame, so the flag is passed as a comment the bootstrap
            // checks against `window.top`.
            let wrapper = script.noframes
                ? "if (window.top === window) {\n\(source)\n}"
                : source

            built.append(
                WKUserScript(
                    source: wrapper,
                    injectionTime: injectionTime,
                    // `forMainFrameOnly: false` puts the script in subframes too,
                    // which is what a userscript manager does by default; the
                    // `@noframes` guard above is what opts a script out.
                    forMainFrameOnly: false
                )
            )
        }

        let summary = UserScriptInjectionSummary(
            injectedScriptCount: built.count,
            failedScriptNames: failed,
            url: url.absoluteString,
            skipReason: ""
        )
        return (built, summary)
    }

    /// The value snapshot the injected `GM_info` reports.
    private static func encodeValues(_ values: [String: String]) -> String {
        // Values are stored as JSON strings; the snapshot re-parses them so the
        // page receives real objects rather than double-encoded strings.
        var decoded: [String: Any] = [:]
        for (key, raw) in values {
            if let data = raw.data(using: .utf8),
               let object = try? JSONSerialization.jsonObject(with: data) {
                decoded[key] = object
            } else {
                decoded[key] = raw
            }
        }
        guard let data = try? JSONSerialization.data(withJSONObject: decoded, options: [.fragmentsAllowed]),
              let json = String(data: data, encoding: .utf8) else {
            return "{}"
        }
        return json
    }

    /// Wraps a script body in the GM bridge.
    private static func bootstrapSource(
        for script: InstalledUserScriptState,
        valuesJSON: String,
        tabId: String
    ) -> String {
        let supportedGrants = script.grants
            .filter { $0.isSupportedByVela && $0 != .none }
            .map(\.rawValue)
        let grantsJSON = jsonObject(supportedGrants)

        let resourcesJSON = jsonObject(
            script.resources.reduce(into: [String: String]()) { map, resource in
                map[resource.name] = resource.text
            }
        )
        let resourceURLsJSON = jsonObject(
            script.resources.reduce(into: [String: String]()) { map, resource in
                if let base64 = resource.contentBase64, !base64.isEmpty {
                    map[resource.name] = "data:\(resource.mimeType);base64,\(base64)"
                } else {
                    let mime = resource.mimeType.isEmpty ? "text/plain" : resource.mimeType
                    let base64 = Data(resource.text.utf8).base64EncodedString()
                    map[resource.name] = "data:\(mime);base64,\(base64)"
                }
            }
        )
        let requireURLsJSON = jsonObject(script.requireUrls)
        let requiresBlock = script.requireSources.enumerated().map { index, source in
            """
            try {
            \(source)
            } catch (requireError) {
              api.GM_log('@require \(index + 1) 执行出错：' + requireError);
            }
            """
        }.joined(separator: "\n")

        return """
        (function () {
          var SCRIPT_ID = \(jsonString(script.id));
          var TAB_ID = \(jsonString(tabId));
          var SCRIPT_NAME = \(jsonString(script.displayName));
          var SCRIPT_VERSION = \(jsonString(script.version));
          var SCRIPT_NAMESPACE = \(jsonString(script.namespace));
          var SCRIPT_DESCRIPTION = \(jsonString(script.description));
          var SCRIPT_UPDATE_URL = \(jsonString(script.updateUrl));
          var SCRIPT_DOWNLOAD_URL = \(jsonString(script.downloadUrl));
          var SCRIPT_RUN_AT = \(jsonString(script.runAt.rawValue));
          var GRANTS = \(grantsJSON);
          var RESOURCES = \(resourcesJSON);
          var RESOURCE_URLS = \(resourceURLsJSON);
          var REQUIRE_URLS = \(requireURLsJSON);

          var valueStore = \(valuesJSON);
          var valueListeners = {};

          // Every script on the page shares this object. Each script has its
          // own resolver table, so an answer is delivered to the script that
          // asked even when several scripts use GM_xmlhttpRequest at once.
          window.\(bridgeGlobalName) = window.\(bridgeGlobalName) || {};
          var bridge = window.\(bridgeGlobalName);
          bridge.resolvers = bridge.resolvers || {};
          bridge.resolvers[SCRIPT_ID] = bridge.resolvers[SCRIPT_ID] || {};
          bridge.menuCommands = bridge.menuCommands || {};
          if (typeof bridge.resolve !== 'function') {
            bridge.resolve = function (scriptId, requestId, payload) {
              var table = bridge.resolvers[scriptId] || {};
              var resolver = table[requestId];
              if (!resolver) { return; }
              delete table[requestId];
              try {
                resolver(payload || {});
              } catch (_error) {
              }
            };
          }

          function newRequestId(prefix) {
            return prefix + '-' + Date.now().toString(36) + '-' +
              Math.random().toString(36).slice(2);
          }

          function expectResolution(requestId, resolver) {
            bridge.resolvers[SCRIPT_ID][requestId] = resolver;
          }

          function post(message) {
            try {
              if (window.webkit && window.webkit.messageHandlers &&
                  window.webkit.messageHandlers.\(messageHandlerName)) {
                window.webkit.messageHandlers.\(messageHandlerName).postMessage(message);
                return true;
              }
            } catch (_error) {
            }
            return false;
          }

          function notifyListeners(key, oldValue, newValue) {
            var listeners = valueListeners[key] || [];
            for (var i = 0; i < listeners.length; i++) {
              try {
                listeners[i](key, oldValue, newValue, false);
              } catch (_error) {
              }
            }
          }

          function parseStoredValue(raw, fallback) {
            if (typeof raw === 'undefined' || raw === null) { return fallback; }
            if (typeof raw !== 'string') { return raw; }
            try {
              return JSON.parse(raw);
            } catch (_error) {
              return raw;
            }
          }

          function parseResponseHeaders(raw) {
            var result = {};
            var lines = String(raw || '').split(/\\r?\\n/);
            for (var i = 0; i < lines.length; i++) {
              var line = lines[i];
              if (!line) { continue; }
              var separator = line.indexOf(':');
              if (separator <= 0) { continue; }
              result[line.slice(0, separator).trim()] = line.slice(separator + 1).trim();
            }
            return result;
          }

          function bytesFromBase64(base64) {
            try {
              var binary = atob(base64 || '');
              var bytes = new Uint8Array(binary.length);
              for (var i = 0; i < binary.length; i++) {
                bytes[i] = binary.charCodeAt(i);
              }
              return bytes;
            } catch (_error) {
              return new Uint8Array(0);
            }
          }

          function responseValue(details, payload) {
            var type = details.responseType || '';
            var text = payload.responseText || '';
            var bytes = payload.responseBase64 ? bytesFromBase64(payload.responseBase64) : null;
            if (type === 'arraybuffer') {
              var buffer = bytes
                ? bytes.buffer.slice(bytes.byteOffset, bytes.byteOffset + bytes.byteLength)
                : new ArrayBuffer(0);
              return { response: buffer, responseText: '' };
            }
            if (type === 'blob') {
              return {
                response: new Blob([bytes || new Uint8Array(0)], { type: payload.mimeType || '' }),
                responseText: ''
              };
            }
            if (type === 'json') {
              try {
                return { response: JSON.parse(text), responseText: text };
              } catch (_error) {
                return { response: null, responseText: text };
              }
            }
            if (type === 'document') {
              try {
                return {
                  response: new DOMParser().parseFromString(text, payload.mimeType || 'text/html'),
                  responseText: text
                };
              } catch (_error) {
                return { response: null, responseText: text };
              }
            }
            return { response: text, responseText: text };
          }

          var api = {};

          api.GM_info = {
            script: {
              name: SCRIPT_NAME,
              namespace: SCRIPT_NAMESPACE,
              version: SCRIPT_VERSION,
              description: SCRIPT_DESCRIPTION,
              matches: \(jsonString(script.matches.joined(separator: ","))).split(',').filter(Boolean),
              grant: GRANTS,
              require: REQUIRE_URLS,
              resources: Object.keys(RESOURCES),
              updateURL: SCRIPT_UPDATE_URL,
              downloadURL: SCRIPT_DOWNLOAD_URL,
              runAt: SCRIPT_RUN_AT
            },
            scriptHandler: 'Vela',
            version: '1.0',
            platform: { browserName: 'Vela', version: '1.0' }
          };

          api.GM_getValue = function (key, defaultValue) {
            return parseStoredValue(valueStore[key], defaultValue);
          };

          api.GM_getValues = function (defaults) {
            var result = {};
            for (var key in defaults) {
              if (Object.prototype.hasOwnProperty.call(defaults, key)) {
                result[key] = api.GM_getValue(key, defaults[key]);
              }
            }
            var keys = Object.keys(valueStore);
            for (var i = 0; i < keys.length; i++) {
              result[keys[i]] = parseStoredValue(valueStore[keys[i]], undefined);
            }
            return result;
          };

          api.GM_setValue = function (key, value) {
            var oldValue = parseStoredValue(valueStore[key], undefined);
            var encoded = JSON.stringify(value);
            valueStore[key] = encoded;
            post({ type: 'setValue', scriptId: SCRIPT_ID, key: String(key), value: encoded });
            notifyListeners(String(key), oldValue, value);
            return value;
          };

          api.GM_setValues = function (values) {
            for (var key in values) {
              if (Object.prototype.hasOwnProperty.call(values, key)) {
                api.GM_setValue(key, values[key]);
              }
            }
          };

          api.GM_deleteValue = function (key) {
            var oldValue = parseStoredValue(valueStore[key], undefined);
            delete valueStore[key];
            post({ type: 'deleteValue', scriptId: SCRIPT_ID, key: String(key) });
            notifyListeners(String(key), oldValue, undefined);
          };

          api.GM_deleteValues = function (keys) {
            for (var i = 0; i < keys.length; i++) { api.GM_deleteValue(keys[i]); }
          };

          api.GM_listValues = function () {
            return Object.keys(valueStore);
          };

          api.GM_addValueChangeListener = function (key, listener) {
            var name = String(key);
            if (!valueListeners[name]) { valueListeners[name] = []; }
            valueListeners[name].push(listener);
            return listener;
          };

          api.GM_removeValueChangeListener = function (listener) {
            for (var name in valueListeners) {
              var list = valueListeners[name];
              var index = list.indexOf(listener);
              if (index >= 0) { list.splice(index, 1); }
            }
          };

          api.GM_addStyle = function (css) {
            var style = document.createElement('style');
            style.textContent = String(css);
            (document.head || document.documentElement).appendChild(style);
            return style;
          };

          api.GM_addElement = function (tag, attributes, parent) {
            // Tampermonkey has two signatures: (tag, attributes, parent) and
            // (parent, tagName, attributes). The first argument being an
            // element is how the second is recognized.
            if (tag && typeof tag === 'object' && tag.nodeType === 1) {
              return api.GM_addElement(
                String(attributes || 'div'),
                parent && typeof parent === 'object' ? parent : null,
                tag
              );
            }
            var element = document.createElement(String(tag));
            if (attributes) {
              for (var key in attributes) {
                if (!Object.prototype.hasOwnProperty.call(attributes, key)) { continue; }
                if (key === 'textContent') {
                  element.textContent = attributes[key];
                } else {
                  element.setAttribute(key, attributes[key]);
                }
              }
            }
            (parent || document.body || document.documentElement).appendChild(element);
            return element;
          };

          api.GM_getResourceText = function (name) {
            return Object.prototype.hasOwnProperty.call(RESOURCES, name) ? RESOURCES[name] : null;
          };

          api.GM_getResourceURL = function (name) {
            return Object.prototype.hasOwnProperty.call(RESOURCE_URLS, name)
              ? RESOURCE_URLS[name]
              : null;
          };

          api.GM_log = function () {
            try {
              console.log.apply(console, [SCRIPT_NAME + ':'].concat(Array.prototype.slice.call(arguments)));
            } catch (_error) {}
          };

          api.GM_setClipboard = function (data, type) {
            post({
              type: 'setClipboard',
              scriptId: SCRIPT_ID,
              text: String(data),
              mimeType: type || 'text/plain'
            });
          };

          api.GM_notification = function (text, title, options) {
            post({
              type: 'notification',
              scriptId: SCRIPT_ID,
              text: String(text),
              title: String(title || SCRIPT_NAME),
              onclick: false,
              silent: !!(options && options.silent)
            });
          };

          api.GM_registerMenuCommand = function (name, fn, accessKey) {
            var commandId = 'cmd-' + Math.random().toString(36).slice(2);
            bridge.menuCommands[commandId] = fn;
            post({
              type: 'registerMenuCommand',
              scriptId: SCRIPT_ID,
              commandId: commandId,
              name: String(name),
              accessKey: String(accessKey || ''),
              scriptName: SCRIPT_NAME
            });
            return commandId;
          };

          api.GM_unregisterMenuCommand = function (commandId) {
            delete bridge.menuCommands[commandId];
            post({
              type: 'unregisterMenuCommand',
              scriptId: SCRIPT_ID,
              commandId: String(commandId)
            });
          };

          api.GM_openInTab = function (url, options) {
            var active = true;
            if (typeof options === 'boolean') {
              active = options;
            } else if (options && typeof options === 'object' && options.active === false) {
              active = false;
            }
            post({
              type: 'openInTab',
              scriptId: SCRIPT_ID,
              url: String(url || ''),
              active: !!active
            });
            return {
              close: function () {},
              closed: false,
              onclose: null
            };
          };

          api.GM_download = function (details, onload, onerror) {
            if (typeof details === 'string') { details = { url: details }; }
            details = details || {};
            var requestId = newRequestId('download');
            expectResolution(requestId, function (payload) {
              if (payload.error) {
                try {
                  if (details.onerror) { details.onerror(payload.error); }
                  if (onerror) { onerror(payload.error); }
                } catch (_error) {}
                return;
              }
              var result = { id: payload.taskId || '', finalUrl: details.url };
              try {
                if (details.onload) { details.onload(result); }
                if (onload) { onload(result); }
              } catch (_error) {}
            });
            post({
              type: 'download',
              scriptId: SCRIPT_ID,
              requestId: requestId,
              url: String(details.url || ''),
              name: String(details.name || '')
            });
          };

          api.GM_cookie = function (action, details, callback) {
            if (typeof action === 'object') {
              return api.GM_cookie.list(action, details);
            }
            var requestId = newRequestId('cookie');
            var verb = String(action || 'list');
            expectResolution(requestId, function (payload) {
              try {
                if (verb === 'list') {
                  if (callback) { callback(payload.cookies || [], payload.error || null); }
                } else if (callback) {
                  callback(payload.error || null);
                }
              } catch (_error) {}
            });
            post({
              type: 'cookie',
              scriptId: SCRIPT_ID,
              requestId: requestId,
              action: verb,
              details: details || {}
            });
          };
          api.GM_cookie.list = function (details, callback) {
            return api.GM_cookie('list', details, callback);
          };
          api.GM_cookie.set = function (details, callback) {
            return api.GM_cookie('set', details, callback);
          };
          api.GM_cookie.delete = function (details, callback) {
            return api.GM_cookie('delete', details, callback);
          };
          // Older Tampermonkey builds exposed these as separate globals.
          api.GM_cookieSet = function (details, callback) {
            return api.GM_cookie.set(details, callback);
          };
          api.GM_cookieDelete = function (details, callback) {
            return api.GM_cookie.delete(details, callback);
          };

          api.GM_getTab = function (callback) {
            var requestId = newRequestId('tab');
            expectResolution(requestId, function (payload) {
              var value = null;
              try { value = payload.json ? JSON.parse(payload.json) : null; } catch (_error) {}
              try { if (callback) { callback(value); } } catch (_error) {}
            });
            post({ type: 'getTab', scriptId: SCRIPT_ID, requestId: requestId, tabId: TAB_ID });
          };

          api.GM_saveTab = function (value) {
            var json = 'null';
            try { json = JSON.stringify(value); } catch (_error) {}
            post({ type: 'saveTab', scriptId: SCRIPT_ID, tabId: TAB_ID, json: json });
          };

          api.GM_getTabs = function (callback) {
            var requestId = newRequestId('tabs');
            expectResolution(requestId, function (payload) {
              var result = {};
              var tabs = payload.tabs || {};
              for (var key in tabs) {
                if (!Object.prototype.hasOwnProperty.call(tabs, key)) { continue; }
                try { result[key] = JSON.parse(tabs[key]); } catch (_error) { result[key] = null; }
              }
              try { if (callback) { callback(result); } } catch (_error) {}
            });
            post({ type: 'getTabs', scriptId: SCRIPT_ID, requestId: requestId });
          };

          api.GM_xmlhttpRequest = function (details) {
            details = details || {};
            var requestId = newRequestId('xhr');
            var headers = details.headers || {};
            var data = details.data;
            if (data && typeof data === 'object' && !(data instanceof ArrayBuffer)) {
              var pairs = [];
              for (var key in data) {
                if (!Object.prototype.hasOwnProperty.call(data, key)) { continue; }
                pairs.push(encodeURIComponent(key) + '=' + encodeURIComponent(data[key]));
              }
              data = pairs.join('&');
              if (!headers['Content-Type'] && !headers['content-type']) {
                headers['Content-Type'] = 'application/x-www-form-urlencoded';
              }
            }
            var handle = {
              abort: function () {
                post({ type: 'xhrAbort', scriptId: SCRIPT_ID, requestId: requestId });
              }
            };
            expectResolution(requestId, function (payload) {
              var values = responseValue(details, payload);
              var response = {
                readyState: 4,
                status: payload.status || 0,
                statusText: payload.statusText || '',
                responseHeaders: payload.responseHeaders || '',
                responseText: values.responseText,
                response: values.response,
                finalUrl: payload.finalUrl || details.url
              };
              try {
                if (payload.aborted) {
                  if (details.onabort) { details.onabort(response); }
                  return;
                }
                if (payload.timeout) {
                  if (details.ontimeout) { details.ontimeout(response); }
                  return;
                }
                if (payload.error) {
                  if (details.onerror) { details.onerror(response); }
                  return;
                }
                if (details.onreadystatechange) { details.onreadystatechange(response); }
                if (details.onload) { details.onload(response); }
              } catch (_error) {}
            });
            post({
              type: 'xhr',
              scriptId: SCRIPT_ID,
              requestId: requestId,
              method: String(details.method || 'GET').toUpperCase(),
              url: String(details.url || ''),
              headers: headers,
              data: typeof data === 'string' ? data : '',
              responseType: details.responseType || '',
              timeout: Number(details.timeout) || 0,
              anonymous: !!details.anonymous,
              user: details.user || '',
              password: details.password || ''
            });
            return handle;
          };

          api.GM_fetch = function (input, init) {
            return new Promise(function (resolve, reject) {
              var url = typeof input === 'string' ? input : ((input && input.url) || '');
              var method = (init && init.method) || (input && input.method) || 'GET';
              var headers = {};
              var sourceHeaders = (init && init.headers) || (input && input.headers);
              if (sourceHeaders) {
                if (Array.isArray(sourceHeaders)) {
                  for (var i = 0; i < sourceHeaders.length; i++) {
                    headers[sourceHeaders[i][0]] = sourceHeaders[i][1];
                  }
                } else if (typeof sourceHeaders.forEach === 'function') {
                  sourceHeaders.forEach(function (value, key) { headers[key] = value; });
                } else {
                  for (var key in sourceHeaders) {
                    if (Object.prototype.hasOwnProperty.call(sourceHeaders, key)) {
                      headers[key] = String(sourceHeaders[key]);
                    }
                  }
                }
              }
              var handle = api.GM_xmlhttpRequest({
                method: method,
                url: url,
                headers: headers,
                data: init && init.body,
                responseType: 'arraybuffer',
                onload: function (response) {
                  try {
                    resolve(new Response(response.response, {
                      // A data: or local response has status 0, which the
                      // Response constructor rejects; those are successes.
                      status: response.status || 200,
                      statusText: response.statusText,
                      headers: parseResponseHeaders(response.responseHeaders)
                    }));
                  } catch (error) {
                    reject(error);
                  }
                },
                onerror: function () { reject(new TypeError('Failed to fetch')); },
                ontimeout: function () { reject(new TypeError('Network timeout')); },
                onabort: function () { reject(new DOMException('Aborted', 'AbortError')); }
              });
              var signal = init && init.signal;
              if (signal && typeof signal.addEventListener === 'function') {
                signal.addEventListener('abort', function () {
                  if (handle && typeof handle.abort === 'function') { handle.abort(); }
                });
              }
            });
          };

          // The promise-based `GM` namespace that Violentmonkey and current
          // Tampermonkey expose. Scripts written for either manager often use
          // these instead of the old synchronous GM_* globals.
          function promiseCall(value) {
            return new Promise(function (resolve) { resolve(value); });
          }
          api.GM = {
            info: api.GM_info,
            getValue: function (key, defaultValue) {
              return promiseCall(api.GM_getValue(key, defaultValue));
            },
            getValues: function (defaults) {
              return promiseCall(api.GM_getValues(defaults));
            },
            setValue: function (key, value) {
              return promiseCall(api.GM_setValue(key, value));
            },
            setValues: function (values) {
              return promiseCall(api.GM_setValues(values));
            },
            deleteValue: function (key) {
              return promiseCall(api.GM_deleteValue(key));
            },
            deleteValues: function (keys) {
              return promiseCall(api.GM_deleteValues(keys));
            },
            listValues: function () {
              return promiseCall(api.GM_listValues());
            },
            addValueChangeListener: function (key, listener) {
              return api.GM_addValueChangeListener(key, listener);
            },
            removeValueChangeListener: function (listener) {
              return api.GM_removeValueChangeListener(listener);
            },
            addStyle: function (css) {
              return promiseCall(api.GM_addStyle(css));
            },
            getResourceText: function (name) {
              return promiseCall(api.GM_getResourceText(name));
            },
            getResourceUrl: function (name) {
              return promiseCall(api.GM_getResourceURL(name));
            },
            xmlHttpRequest: function (details) {
              return new Promise(function (resolve, reject) {
                var copy = {};
                for (var key in details) {
                  if (Object.prototype.hasOwnProperty.call(details, key)) {
                    copy[key] = details[key];
                  }
                }
                copy.onload = resolve;
                copy.onerror = reject;
                copy.ontimeout = reject;
                copy.onabort = reject;
                api.GM_xmlhttpRequest(copy);
              });
            },
            download: function (details) {
              return new Promise(function (resolve, reject) {
                var copy = {};
                for (var key in details) {
                  if (Object.prototype.hasOwnProperty.call(details, key)) {
                    copy[key] = details[key];
                  }
                }
                copy.onload = resolve;
                copy.onerror = reject;
                api.GM_download(copy);
              });
            },
            openInTab: function (url, options) {
              return promiseCall(api.GM_openInTab(url, options));
            },
            notification: function (text, title, options) {
              return promiseCall(api.GM_notification(text, title, options));
            },
            setClipboard: function (data, type) {
              return promiseCall(api.GM_setClipboard(data, type));
            },
            registerMenuCommand: function (name, fn, accessKey) {
              return api.GM_registerMenuCommand(name, fn, accessKey);
            },
            unregisterMenuCommand: function (commandId) {
              return api.GM_unregisterMenuCommand(commandId);
            },
            getTab: function () {
              return new Promise(function (resolve) { api.GM_getTab(resolve); });
            },
            saveTab: function (value) {
              return promiseCall(api.GM_saveTab(value));
            },
            getTabs: function () {
              return new Promise(function (resolve) { api.GM_getTabs(resolve); });
            },
            cookie: {
              list: function (details) {
                return new Promise(function (resolve, reject) {
                  api.GM_cookie.list(details, function (cookies, error) {
                    if (error) { reject(error); } else { resolve(cookies); }
                  });
                });
              },
              set: function (details) {
                return new Promise(function (resolve, reject) {
                  api.GM_cookie.set(details, function (error) {
                    if (error) { reject(error); } else { resolve(); }
                  });
                });
              },
              delete: function (details) {
                return new Promise(function (resolve, reject) {
                  api.GM_cookie.delete(details, function (error) {
                    if (error) { reject(error); } else { resolve(); }
                  });
                });
              }
            }
          };

          // Grants Vela cannot honour are present but inert, so a script that
          // feature-detects instead of trusting @grant takes the fallback path
          // rather than throwing a ReferenceError on the first call.
          function defineUnsupported(name) {
            if (Object.prototype.hasOwnProperty.call(api, name)) { return; }
            api[name] = function () {
              api.GM_log(name + ' 在 iOS 上不可用（WebKit 不提供该能力）。');
              return null;
            };
          }
          ['GM_EX_getSearchEngines', 'GM_EX_getAppSearchEngineUrl', 'GM_EX_TTS',
           'GM_EX_ShareTextToApp', 'GM_EX_sniffMedia'].forEach(defineUnsupported);

          bridge.api = api;
          bridge.values = valueStore;

          // `unsafeWindow` is the page's own window object. In a WKUserScript
          // the injected world shares the page's globals, so this is an alias
          // rather than the isolation-bypass it is in Firefox.
          api.unsafeWindow = window;

          // The GM globals are scoped with `with (api)` below instead of
          // being written to `window`. Each script's API closures carry its
          // own SCRIPT_ID, and two scripts on one page must not overwrite each
          // other's value store or menu commands. Sloppy mode is deliberate:
          // many user scripts are not strict-mode safe.

          // `window.onurlchange` is opt-in through @grant in Tampermonkey.
          (function () {
            var lastUrl = String(window.location.href || '');
            function report() {
              var nextUrl = String(window.location.href || '');
              if (nextUrl === lastUrl) { return; }
              lastUrl = nextUrl;
              try {
                if (typeof window.onurlchange === 'function') {
                  window.onurlchange({ url: nextUrl });
                }
              } catch (_error) {}
            }
            try {
              var pushState = window.history.pushState;
              window.history.pushState = function () {
                var result = pushState.apply(window.history, arguments);
                report();
                return result;
              };
              var replaceState = window.history.replaceState;
              window.history.replaceState = function () {
                var result = replaceState.apply(window.history, arguments);
                report();
                return result;
              };
              window.addEventListener('popstate', report);
              window.addEventListener('hashchange', report);
            } catch (_error) {}
          })();

          with (api) {
            // @require dependencies, in declaration order, before the script.
        \(requiresBlock)

            try {
              (function () {
        \(script.source)
              }).call(window);
            } catch (error) {
              api.GM_log('脚本执行出错：' + (error && error.message ? error.message : String(error)));
              post({
                type: 'executionError',
                scriptId: SCRIPT_ID,
                message: String(error && error.message ? error.message : error)
              });
            }
          }
        })();
        """
    }

    /// JSON-encodes a Swift string for embedding in the bootstrap.
    private static func jsonString(_ value: String) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: [value]),
              let array = String(data: data, encoding: .utf8),
              array.count >= 2 else {
            return "\"\""
        }
        // `["x"]` → `"x"`
        return String(array.dropFirst().dropLast())
    }

    /// JSON-encodes any JSON-serializable value.
    private static func jsonObject(_ value: Any) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: value),
              let json = String(data: data, encoding: .utf8) else {
            return "null"
        }
        return json
    }
}
