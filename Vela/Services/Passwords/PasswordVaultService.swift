//
//  PasswordVaultService.swift
//  Vela
//
//  The password vault: Keychain-backed storage, a biometric lock, and the two
//  page scripts the vault needs — fill a login, and read one back for saving.
//
//  The vault is not a server client and never syncs. Every credential lives as
//  one Keychain item (`KeychainStore`), which is why the list is decoded on
//  unlock rather than kept in a preferences document: locking the vault means
//  dropping the decoded copies as well as refusing the UI.
//
//  Reading a password out of a page is the one operation with real weight here.
//  It only runs when the user taps 保存当前页面, never on navigation, and its
//  result goes straight into the editor the user then confirms.
//

import Foundation
import LocalAuthentication
import Observation
import WebKit

@MainActor
@Observable
public final class PasswordVaultService {
    public private(set) var credentials: [VaultCredential] = []
    public private(set) var isUnlocked = false
    public private(set) var lastError: String?

    private let store: KeychainStore
    private let settings: SettingsService
    private let decoder = JSONDecoder()
    private let encoder = JSONEncoder()

    public init(settings: SettingsService) {
        self.settings = settings
        self.store = KeychainStore(service: "org.vela.browser.password-vault")
    }

    /// Whether the vault asks for the device's own authentication. On by
    /// default; the setting exists so a device with no passcode is not locked
    /// out of its own passwords.
    private var biometricsRequired: Bool {
        settings.preferences.vaultRequireBiometrics ?? true
    }

    // MARK: - Lock

    /// Prompts for Face ID / Touch ID / the device passcode and, on success,
    /// loads the vault.
    ///
    /// `deviceOwnerAuthentication` rather than a biometric-only policy: the
    /// passcode is the fallback the system already trusts, and a vault that
    /// refuses a device with Face ID disabled would be a vault its owner cannot
    /// open. When the device has no authentication configured at all there is
    /// nothing to evaluate, so the vault opens behind the Keychain's own
    /// protection instead of refusing forever.
    @discardableResult
    public func unlock() async -> Bool {
        lastError = nil

        guard biometricsRequired else {
            isUnlocked = true
            reload()
            return true
        }

        let context = LAContext()
        context.localizedCancelTitle = "取消"
        context.localizedFallbackTitle = "使用密码"

        var policyError: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &policyError) else {
            // No passcode and no biometrics: the Keychain is still encrypted
            // with the device key, so the vault is reachable rather than
            // bricked.
            isUnlocked = true
            reload()
            return true
        }

        do {
            let success = try await context.evaluatePolicy(
                .deviceOwnerAuthentication,
                localizedReason: "解锁密码与保险箱"
            )
            guard success else {
                lastError = "未能验证身份"
                return false
            }
            isUnlocked = true
            reload()
            return true
        } catch {
            // A user cancellation is not an error worth reporting twice; the
            // lock screen is its own answer.
            if (error as NSError).code != LAError.userCancel.rawValue {
                lastError = "未能验证身份"
            }
            return false
        }
    }

    /// Drops the decoded credentials. Called when the app leaves the
    /// foreground.
    public func lock() {
        isUnlocked = false
        credentials = []
    }

    // MARK: - Reading and writing

    public func reload() {
        do {
            let decoded = try store.allData().compactMap { data -> VaultCredential? in
                try? decoder.decode(VaultCredential.self, from: data)
            }
            credentials = decoded.sorted {
                if $0.host != $1.host { return $0.host < $1.host }
                return $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending
            }
        } catch {
            lastError = error.localizedDescription
            credentials = []
        }
    }

    public func save(_ credential: VaultCredential) throws {
        var record = credential
        if let existing = credentials.first(where: { $0.id == record.id }) {
            record.createdAt = existing.createdAt
        }
        record.host = VaultCredential.normalizeHost(record.host)
        if record.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            record.title = VaultCredential.fallbackTitle(for: record.host)
        }
        record.updatedAt = Date()

        let data = try encoder.encode(record)
        try store.save(account: record.id, data: data)
        reload()
    }

    public func delete(id: String) throws {
        try store.delete(account: id)
        reload()
    }

    public func deleteAll() throws {
        try store.deleteAll()
        reload()
    }

    public func credential(id: String) -> VaultCredential? {
        credentials.first { $0.id == id }
    }

    /// Credentials that belong to a page's host, best match first.
    ///
    /// Most-specific first: a saved `login.example.com` outranks a saved
    /// `example.com` for a form on the former, which is the same rule the
    /// system's own AutoFill uses.
    public func credentials(matching pageHost: String) -> [VaultCredential] {
        credentials
            .filter { $0.matches(host: pageHost) }
            .sorted { $0.host.count > $1.host.count }
    }

    // MARK: - Autofill

    /// Fills the page's login form with a saved credential.
    ///
    /// The script only writes values and dispatches the events frameworks
    /// listen to; it never submits. A site that reacts to `input` sees exactly
    /// what it would see from typing, which is what keeps its own validation
    /// and its sign-in button in the state the user expects.
    public func fill(_ credential: VaultCredential, in webView: WKWebView) async -> Bool {
        let script = Self.fillScript(
            username: credential.username,
            password: credential.password
        )
        do {
            let result = try await webView.evaluateJavaScript(script)
            if let value = result as? Bool { return value }
            if let number = result as? NSNumber { return number.boolValue }
            return false
        } catch {
            return false
        }
    }

    /// Reads the first filled login form on the page, for the explicit
    /// "save this login" action. Returns nil when there is nothing to save.
    public func captureCredentials(from webView: WKWebView) async -> (username: String, password: String)? {
        do {
            guard let raw = try await webView.evaluateJavaScript(Self.captureScript) as? String,
                  !raw.isEmpty,
                  let data = raw.data(using: .utf8),
                  let payload = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let password = payload["password"] as? String,
                  !password.isEmpty else {
                return nil
            }
            let username = (payload["username"] as? String) ?? ""
            return (username, password)
        } catch {
            return nil
        }
    }

    // MARK: - Password generation

    /// A random password that avoids the characters (0/O, 1/l/I) people
    /// misread when they have to retype it.
    public func generatePassword(length: Int = 20) -> String {
        let lower = Array("abcdefghijkmnopqrstuvwxyz")
        let upper = Array("ABCDEFGHJKLMNPQRSTUVWXYZ")
        let digits = Array("23456789")
        let symbols = Array("!@#$%^&*-_=+?")
        let all = lower + upper + digits + symbols

        var characters: [Character] = [
            lower.randomElement() ?? "a",
            upper.randomElement() ?? "A",
            digits.randomElement() ?? "2",
            symbols.randomElement() ?? "!"
        ]
        while characters.count < max(length, 8) {
            characters.append(all.randomElement() ?? "a")
        }
        return String(characters.shuffled())
    }

    // MARK: - Scripts

    /// Builds a JSON string literal safe to paste inside JavaScript source.
    private static func jsonString(_ value: String) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: [value]),
              let text = String(data: data, encoding: .utf8) else {
            return "\"\""
        }
        // `["..."]` minus the brackets is the quoted, escaped string.
        return String(text.dropFirst().dropLast())
    }

    static func fillScript(username: String, password: String) -> String {
        let user = jsonString(username)
        let secret = jsonString(password)
        return """
        (function () {
          function isVisible(element) {
            if (!element || element.disabled || element.readOnly) { return false; }
            var style = window.getComputedStyle ? window.getComputedStyle(element) : null;
            if (style && (style.display === 'none' || style.visibility === 'hidden')) { return false; }
            var rect = element.getBoundingClientRect ? element.getBoundingClientRect() : null;
            return !rect || (rect.width > 0 && rect.height > 0);
          }

          function setValue(element, value) {
            var prototype = element instanceof HTMLTextAreaElement
              ? HTMLTextAreaElement.prototype
              : HTMLInputElement.prototype;
            var descriptor = Object.getOwnPropertyDescriptor(prototype, 'value');
            if (descriptor && descriptor.set) {
              descriptor.set.call(element, value);
            } else {
              element.value = value;
            }
            element.dispatchEvent(new Event('input', { bubbles: true }));
            element.dispatchEvent(new Event('change', { bubbles: true }));
          }

          var passwords = document.querySelectorAll('input[type="password"]');
          var passwordField = null;
          for (var i = 0; i < passwords.length; i++) {
            if (isVisible(passwords[i])) { passwordField = passwords[i]; break; }
          }
          if (!passwordField) { return false; }

          var scope = passwordField.form || document;
          var userField = null;
          var inputs = scope.querySelectorAll('input');
          for (var j = 0; j < inputs.length; j++) {
            var input = inputs[j];
            var type = (input.type || 'text').toLowerCase();
            if (type === 'password' || type === 'hidden' || type === 'submit' ||
                type === 'button' || type === 'checkbox' || type === 'radio' ||
                type === 'file' || type === 'image' || type === 'reset') {
              continue;
            }
            if (!isVisible(input)) { continue; }
            var hint = [
              input.autocomplete || '',
              input.name || '',
              input.id || '',
              input.placeholder || '',
              input.getAttribute('aria-label') || ''
            ].join(' ');
            if (type === 'email' || type === 'tel' ||
                /username|email|phone|mobile|account|login|user|账号|帐号|邮箱|手机|用户名/i.test(hint)) {
              userField = input;
              break;
            }
          }

          // A form that marks nothing: the visible text field immediately
          // before the password is the username by every convention.
          if (!userField) {
            var previous = passwordField.previousElementSibling;
            while (previous) {
              if (previous.tagName === 'INPUT' &&
                  (previous.type || 'text').toLowerCase() !== 'password' &&
                  isVisible(previous)) {
                userField = previous;
                break;
              }
              previous = previous.previousElementSibling;
            }
          }

          if (userField && \(user).length > 0) {
            setValue(userField, \(user));
          }
          setValue(passwordField, \(secret));
          passwordField.focus({ preventScroll: true });
          passwordField.blur();
          return true;
        })();
        """
    }

    static let captureScript = """
    (function () {
      function isVisible(element) {
        if (!element || element.disabled) { return false; }
        var style = window.getComputedStyle ? window.getComputedStyle(element) : null;
        if (style && (style.display === 'none' || style.visibility === 'hidden')) { return false; }
        var rect = element.getBoundingClientRect ? element.getBoundingClientRect() : null;
        return !rect || (rect.width > 0 && rect.height > 0);
      }

      var passwords = document.querySelectorAll('input[type="password"]');
      var passwordField = null;
      for (var i = 0; i < passwords.length; i++) {
        if (isVisible(passwords[i]) && passwords[i].value) {
          passwordField = passwords[i];
          break;
        }
      }
      if (!passwordField) { return ''; }

      var scope = passwordField.form || document;
      var username = '';
      var inputs = scope.querySelectorAll('input');
      for (var j = 0; j < inputs.length; j++) {
        var input = inputs[j];
        var type = (input.type || 'text').toLowerCase();
        if (type === 'password' || type === 'hidden') { continue; }
        if (!isVisible(input)) { continue; }
        var hint = [
          input.autocomplete || '',
          input.name || '',
          input.id || '',
          input.placeholder || ''
        ].join(' ');
        if (type === 'email' || type === 'tel' ||
            /username|email|phone|mobile|account|login|user|账号|帐号|邮箱|手机|用户名/i.test(hint)) {
          username = input.value || '';
          break;
        }
      }
      if (!username) {
        var previous = passwordField.previousElementSibling;
        while (previous) {
          if (previous.tagName === 'INPUT' &&
              (previous.type || 'text').toLowerCase() !== 'password' &&
              isVisible(previous)) {
            username = previous.value || '';
            break;
          }
          previous = previous.previousElementSibling;
        }
      }

      return JSON.stringify({
        username: String(username || ''),
        password: String(passwordField.value || '')
      });
    })();
    """
}
