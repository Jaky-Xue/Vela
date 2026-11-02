//
//  WebPageScripts+Permissions.swift
//  Vela
//
//  The page-side half of the site-permission gate.
//
//  Camera, microphone and motion/orientation reach Vela through `WKUIDelegate`.
//  Location, clipboard reads and notifications do not: WebKit exposes no
//  per-site hook for them, so the only place a browser can ask is the page's
//  own API. This bridge wraps those APIs at document start, posts a question
//  to the host, and defers to the platform implementation only after the user
//  answers.
//
//  The wrappers never guess. If the message handler is missing — an older
//  build, or a frame the host did not instrument — the request is allowed
//  through unchanged, because breaking a site to gate a permission the host
//  cannot record would be the wrong failure.
//

import Foundation

extension WebPageScripts {
    public static let permissionBridge = """
    (function () {
      if (window.__velaPermissionBridgeInstalled === true) { return; }
      window.__velaPermissionBridgeInstalled = true;

      var pending = {};
      var sequence = 0;

      function handlerAvailable() {
        return !!(window.webkit && window.webkit.messageHandlers &&
                  window.webkit.messageHandlers.velaPermissionAsk);
      }

      function post(kind, callback) {
        if (!handlerAvailable()) { callback(true); return; }
        var id = 'perm-' + (++sequence) + '-' + Date.now();
        pending[id] = callback;
        try {
          window.webkit.messageHandlers.velaPermissionAsk.postMessage({
            id: id,
            kind: String(kind || '')
          });
        } catch (error) {
          delete pending[id];
          callback(false);
        }
      }

      window.__velaPermissionResolve = function (id, allowed) {
        var callback = pending[id];
        if (!callback) { return; }
        delete pending[id];
        try { callback(!!allowed); } catch (error) {}
      };

      function deniedError(message) {
        try { return new DOMException(message || 'Permission denied', 'NotAllowedError'); }
        catch (error) {
          var fallback = new Error(message || 'Permission denied');
          fallback.name = 'NotAllowedError';
          return fallback;
        }
      }

      function positionError() {
        return { code: 1, message: 'Permission denied', PERMISSION_DENIED: 1,
                 POSITION_UNAVAILABLE: 2, TIMEOUT: 3 };
      }

      // Location. The wrapper gates the page's call and then defers to the
      // browser's own implementation; a denial supplies the platform's error
      // shape so a site's failure path runs.
      try {
        var geolocation = navigator.geolocation;
        if (geolocation) {
          var nativeGet = geolocation.getCurrentPosition;
          var nativeWatch = geolocation.watchPosition;
          var nativeClearWatch = geolocation.clearWatch;
          var watches = {};
          var watchSequence = 0;

          if (typeof nativeGet === 'function') {
            geolocation.getCurrentPosition = function (success, failure, options) {
              post('location', function (allowed) {
                if (allowed) {
                  try { nativeGet.call(geolocation, success, failure, options); } catch (error) {}
                  return;
                }
                if (typeof failure === 'function') {
                  try { failure(positionError()); } catch (error) {}
                }
              });
            };
          }

          if (typeof nativeWatch === 'function') {
            geolocation.watchPosition = function (success, failure, options) {
              var id = ++watchSequence;
              watches[id] = { alive: true, native: 0 };
              post('location', function (allowed) {
                var entry = watches[id];
                if (!entry || !entry.alive) { return; }
                if (!allowed) {
                  if (typeof failure === 'function') {
                    try { failure(positionError()); } catch (error) {}
                  }
                  return;
                }
                try {
                  entry.native = nativeWatch.call(geolocation, success, failure, options);
                } catch (error) {}
              });
              return id;
            };
          }

          if (typeof nativeClearWatch === 'function') {
            geolocation.clearWatch = function (id) {
              var entry = watches[id];
              if (!entry) { return; }
              entry.alive = false;
              if (entry.native) {
                try { nativeClearWatch.call(geolocation, entry.native); } catch (error) {}
              }
              delete watches[id];
            };
          }
        }
      } catch (error) {}

      // Clipboard reads. Writes are left alone: putting text on the clipboard
      // is not the disclosure reading it is.
      try {
        var clipboard = navigator.clipboard;
        if (clipboard) {
          var nativeReadText = clipboard.readText;
          var nativeRead = clipboard.read;
          if (typeof nativeReadText === 'function') {
            clipboard.readText = function () {
              var self = this;
              var args = arguments;
              return new Promise(function (resolve, reject) {
                post('clipboard', function (allowed) {
                  if (!allowed) { reject(deniedError()); return; }
                  try { resolve(nativeReadText.apply(self, args)); } catch (error) { reject(error); }
                });
              });
            };
          }
          if (typeof nativeRead === 'function') {
            clipboard.read = function () {
              var self = this;
              var args = arguments;
              return new Promise(function (resolve, reject) {
                post('clipboard', function (allowed) {
                  if (!allowed) { reject(deniedError()); return; }
                  try { resolve(nativeRead.apply(self, args)); } catch (error) { reject(error); }
                });
              });
            };
          }
        }
      } catch (error) {}

      // Notifications. WKWebView has no system notification surface; the gate
      // is still meaningful because a site reads the answer and stops asking.
      try {
        if (window.Notification && typeof window.Notification.requestPermission === 'function') {
          var nativeRequestPermission = window.Notification.requestPermission;
          window.Notification.requestPermission = function (callback) {
            var self = this;
            var args = arguments;
            return new Promise(function (resolve) {
              post('notification', function (allowed) {
                if (!allowed) {
                  if (typeof callback === 'function') {
                    try { callback('denied'); } catch (error) {}
                  }
                  resolve('denied');
                  return;
                }
                try {
                  resolve(nativeRequestPermission.apply(self, args));
                } catch (error) {
                  resolve('default');
                }
              });
            });
          };
        }
      } catch (error) {}
    })();
    """
}
