//
//  WebRTCGuard.swift
//  Vela
//
//  The document-start script that applies the user's WebRTC policy.
//
//  This lives above the page: the guard runs before any page script, in every
//  frame, and replaces the peer-connection constructor with a wrapper. The
//  wrapper does not implement WebRTC — it only decides which candidates leave
//  the machine. Two policies are available once the user leaves 允许:
//
//    * 防泄露 filters `icecandidate` events whose address is a private,
//      loopback or link-local address. The connection still works; the local
//      network topology does not leave the browser.
//    * 仅中继 forces `iceTransportPolicy: "relay"`, so every candidate is a
//      TURN relay address. A site without a TURN server simply cannot connect,
//      which is the intended trade.
//
//  The constructor is installed with a non-writable property where possible so
//  a page cannot replace the wrapper afterwards.
//

import Foundation

enum WebRTCGuard {
    /// The script for a policy, or nil for 允许 (no intervention).
    static func script(for mode: WebRTCProtectionMode) -> String? {
        guard mode != .allow else { return nil }

        return """
        (function () {
          if (window.__velaWebRTCGuardInstalled === true) { return; }
          window.__velaWebRTCGuardInstalled = true;

          var Native = window.RTCPeerConnection || window.webkitRTCPeerConnection;
          if (typeof Native !== "function") { return; }
          var mode = "\(mode.rawValue)";

          function install(Constructor) {
            try {
              Object.defineProperty(window, "RTCPeerConnection", {
                value: Constructor,
                configurable: false,
                writable: false
              });
              Object.defineProperty(window, "webkitRTCPeerConnection", {
                value: Constructor,
                configurable: false,
                writable: false
              });
            } catch (error) {
              window.RTCPeerConnection = Constructor;
              window.webkitRTCPeerConnection = Constructor;
            }
          }

          if (mode === "blocked") {
            function BlockedPeerConnection() {
              throw new DOMException("WebRTC is disabled by Vela.", "NotAllowedError");
            }
            BlockedPeerConnection.prototype = Native.prototype;
            install(BlockedPeerConnection);

            try {
              var devices = navigator.mediaDevices;
              var deny = function () {
                return Promise.reject(
                  new DOMException("Media capture is disabled by Vela.", "NotAllowedError")
                );
              };
              if (devices) {
                try {
                  Object.defineProperty(devices, "getUserMedia", {
                    value: deny,
                    configurable: true
                  });
                } catch (error) {
                  devices.getUserMedia = deny;
                }
                try {
                  if (devices.getDisplayMedia) {
                    Object.defineProperty(devices, "getDisplayMedia", {
                      value: deny,
                      configurable: true
                    });
                  }
                } catch (error) {}
                try {
                  if (window.MediaDevices && MediaDevices.prototype) {
                    Object.defineProperty(MediaDevices.prototype, "getUserMedia", {
                      value: deny,
                      configurable: true
                    });
                    if (MediaDevices.prototype.getDisplayMedia) {
                      Object.defineProperty(MediaDevices.prototype, "getDisplayMedia", {
                        value: deny,
                        configurable: true
                      });
                    }
                  }
                } catch (error) {}
              }
              var legacyDeny = function (constraints, success, failure) {
                if (typeof failure === "function") {
                  failure(new DOMException("Media capture is disabled by Vela.", "NotAllowedError"));
                }
              };
              if (navigator.getUserMedia) { navigator.getUserMedia = legacyDeny; }
              if (navigator.webkitGetUserMedia) { navigator.webkitGetUserMedia = legacyDeny; }
            } catch (error) {}

            window.__velaWebRTCGuard = mode;
            return;
          }

          function isPrivateAddress(address) {
            if (!address) { return false; }
            var value = String(address).toLowerCase();

            if (value.indexOf(":") !== -1) {
              if (value === "::" || value === "::1") { return true; }
              if (value.indexOf("fe80:") === 0) { return true; }
              if (value.indexOf("fc") === 0 || value.indexOf("fd") === 0) { return true; }
              return false;
            }

            var parts = value.split(".");
            if (parts.length !== 4) { return false; }
            var first = parseInt(parts[0], 10);
            var second = parseInt(parts[1], 10);
            if (isNaN(first) || isNaN(second)) { return false; }
            if (first === 10 || first === 127) { return true; }
            if (first === 169 && second === 254) { return true; }
            if (first === 172 && second >= 16 && second <= 31) { return true; }
            if (first === 192 && second === 168) { return true; }
            if (first === 100 && second >= 64 && second <= 127) { return true; }
            return false;
          }

          function exposesLocalAddress(candidate) {
            if (!candidate) { return false; }
            var text = String(candidate.candidate || candidate);
            var parts = text.split(" ");
            if (parts.length < 8) { return false; }
            var address = parts[4];
            var type = parts[7];
            return type === "host" && isPrivateAddress(address);
          }

          function filteredListener(listener) {
            if (typeof listener !== "function") { return listener; }
            return function (event) {
              if (event && event.candidate && exposesLocalAddress(event.candidate)) { return; }
              return listener.call(this, event);
            };
          }

          function GuardedPeerConnection(configuration, constraints) {
            var config = {};
            if (configuration) {
              for (var key in configuration) { config[key] = configuration[key]; }
            }
            if (mode === "strict") {
              config.iceTransportPolicy = "relay";
            }

            var peer = new Native(config, constraints);
            var originalAdd = peer.addEventListener;
            var handler = null;

            if (typeof originalAdd === "function") {
              // The property-style handler is stored, not wrapped per
              // assignment: assigning onicecandidate twice must not double
              // every event.
              try {
                Object.defineProperty(peer, "onicecandidate", {
                  configurable: true,
                  get: function () { return handler; },
                  set: function (callback) { handler = callback; }
                });
              } catch (error) {}

              originalAdd.call(peer, "icecandidate", function (event) {
                if (event && event.candidate && exposesLocalAddress(event.candidate)) { return; }
                if (typeof handler === "function") { handler.call(peer, event); }
              });

              peer.addEventListener = function (type, listener, options) {
                if (type === "icecandidate") {
                  return originalAdd.call(peer, type, filteredListener(listener), options);
                }
                return originalAdd.call(peer, type, listener, options);
              };
            }

            return peer;
          }

          GuardedPeerConnection.prototype = Native.prototype;
          try { Object.setPrototypeOf(GuardedPeerConnection, Native); } catch (error) {}
          install(GuardedPeerConnection);
          window.__velaWebRTCGuard = mode;
        })();
        """
    }
}
