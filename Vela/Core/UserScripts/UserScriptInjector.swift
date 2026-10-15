//
//  UserScriptInjector.swift
//  Vela
//
//  Builds the `WKUserScript` objects that run installed user scripts.
//  Ported from `UserScriptNativeBridgeModels.ets` and the injection path in
//  Aira's `services/userscripts/` (Aira Browser 3.7.4, GPL-3.0).
//
//  The hard part on iOS is that `GM_getValue` is synchronous in the userscript
//  API but `WKScriptMessageHandler` is asynchronous. The solution — the same one
//  every iOS userscript manager uses — is to snapshot the whole value store into
//  the page at document start, read from that snapshot, and write changes back
//  through the message bridge. A script that sets a value and reads it back in
//  the same tick therefore sees its own write, which is the behaviour scripts
//  actually depend on.
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
    /// - Returns: scripts ready to attach to a `WKUserContentController`, plus a
    ///   summary of what was injected.
    public static func makeUserScripts(
        for scripts: [InstalledUserScriptState],
        url: URL,
        valuesByScriptId: [String: [String: String]]
    ) -> (scripts: [WKUserScript], summary: UserScriptInjectionSummary) {
        var built: [WKUserScript] = []
        var failed: [String] = []

        for script in scripts {
            guard script.runAt.injectsOnLoad else { continue }

            let values = valuesByScriptId[script.id] ?? [:]
            let source = bootstrapSource(
                for: script,
                valuesJSON: encodeValues(values)
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

    /// The metadata snapshot the injected `GM_info` reports.
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
    private static func bootstrapSource(for script: InstalledUserScriptState, valuesJSON: String) -> String {
        let supportedGrants = script.grants
            .filter { $0.isSupportedByVela && $0 != .none }
            .map(\.rawValue)
        let grantsJSON = (try? JSONSerialization.data(withJSONObject: supportedGrants))
            .flatMap { String(data: $0, encoding: .utf8) } ?? "[]"

        let resourcesJSON: String = {
            var map: [String: String] = [:]
            for resource in script.resources {
                map[resource.name] = resource.text
            }
            guard let data = try? JSONSerialization.data(withJSONObject: map),
                  let json = String(data: data, encoding: .utf8) else { return "{}" }
            return json
        }()

        return """
        (function () {
          'use strict';

          var SCRIPT_ID = \(jsonString(script.id));
          var SCRIPT_NAME = \(jsonString(script.displayName));
          var SCRIPT_VERSION = \(jsonString(script.version));
          var SCRIPT_NAMESPACE = \(jsonString(script.namespace));
          var SCRIPT_DESCRIPTION = \(jsonString(script.description));
          var GRANTS = \(grantsJSON);
          var RESOURCES = \(resourcesJSON);

          // The value snapshot. Reads are local; writes go through the bridge
          // and also update the local copy so a read-after-write in the same
          // tick returns what the script just set.
          var valueStore = \(valuesJSON);
          var valueListeners = {};

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

          var api = {};

          api.GM_info = {
            script: {
              name: SCRIPT_NAME,
              namespace: SCRIPT_NAMESPACE,
              version: SCRIPT_VERSION,
              description: SCRIPT_DESCRIPTION,
              matches: \(jsonString(script.matches.joined(separator: ","))).split(',').filter(Boolean),
              grant: GRANTS
            },
            scriptHandler: 'Vela',
            version: '3.7.4',
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
            return Object.prototype.hasOwnProperty.call(RESOURCES, name) ? RESOURCES[name] : null;
          };

          api.GM_log = function () {
            try { console.log.apply(console, [SCRIPT_NAME + ':'].concat(Array.prototype.slice.call(arguments))); }
            catch (_error) {}
          };

          api.GM_setClipboard = function (data, type) {
            post({ type: 'setClipboard', scriptId: SCRIPT_ID, text: String(data), mimeType: type || 'text/plain' });
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
            window.\(bridgeGlobalName) = window.\(bridgeGlobalName) || {};
            window.\(bridgeGlobalName).menuCommands = window.\(bridgeGlobalName).menuCommands || {};
            window.\(bridgeGlobalName).menuCommands[commandId] = fn;
            post({
              type: 'registerMenuCommand',
              scriptId: SCRIPT_ID,
              commandId: commandId,
              name: String(name),
              accessKey: String(accessKey || '')
            });
            return commandId;
          };

          api.GM_unregisterMenuCommand = function (commandId) {
            if (window.\(bridgeGlobalName) && window.\(bridgeGlobalName).menuCommands) {
              delete window.\(bridgeGlobalName).menuCommands[commandId];
            }
            post({ type: 'unregisterMenuCommand', scriptId: SCRIPT_ID, commandId: String(commandId) });
          };

          // Grants Vela cannot honour are present but inert, so a script that
          // feature-detects instead of trusting @grant takes the fallback path
          // rather than throwing a ReferenceError on the first call.
          var unsupported = [];
          function defineUnsupported(name) {
            if (Object.prototype.hasOwnProperty.call(api, name)) { return; }
            unsupported.push(name);
            api[name] = function () {
              api.GM_log(name + ' 在 iOS 上不可用（WebKit 不提供该能力）。');
              return null;
            };
          }
          ['GM_xmlhttpRequest', 'GM_fetch', 'GM_download', 'GM_openInTab',
           'GM_getTab', 'GM_saveTab', 'GM_getTabs',
           'GM_cookie', 'GM_cookieSet', 'GM_cookieDelete'].forEach(defineUnsupported);

          // Scripts reach the API either as bare globals (the common case) or
          // through the bridge object. Both are provided.
          for (var name in api) {
            if (!Object.prototype.hasOwnProperty.call(api, name)) { continue; }
            try { window[name] = api[name]; } catch (_error) {}
          }
          window.\(bridgeGlobalName) = window.\(bridgeGlobalName) || {};
          window.\(bridgeGlobalName).api = api;
          window.\(bridgeGlobalName).values = valueStore;

          // `unsafeWindow` is the page's own window object. In a WKUserScript
          // the injected world shares the page's globals, so this is an alias
          // rather than the isolation-bypass it is in Firefox.
          try { window.unsafeWindow = window; } catch (_error) {}

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
}
