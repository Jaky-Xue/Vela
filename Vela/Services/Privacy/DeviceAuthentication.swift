//
//  DeviceAuthentication.swift
//  Vela
//
//  The one device-owner check behind every feature that is declared as
//  requiring identity verification.
//
//  Face ID / Touch ID / the device passcode are the system's own prompt. The
//  app never draws a password field of its own: `LAContext` is what the user
//  trusts, and a second in-app credential would be one more secret to leak.
//
//  `.deviceOwnerAuthentication` rather than a biometric-only policy: the
//  passcode is the fallback the system itself trusts, so a device whose Face ID
//  is unavailable is not a device whose owner is locked out. Callers decide what
//  "no passcode or biometry configured at all" means; it is reported as
//  `.unavailable` rather than being silently treated as success or failure.
//

import Foundation
import LocalAuthentication

@MainActor
enum DeviceAuthentication {
    enum Result: Equatable {
        /// The user passed the check.
        case success
        /// The user dismissed the system prompt.
        case cancelled
        /// The device has no passcode and no enrolled biometry.
        case unavailable
        /// The check ran and did not pass, or the system refused it.
        case failed
    }

    /// Runs the system check. The prompt itself is the standard iOS one; the
    /// reason is what the system prints under the Face ID / passcode sheet.
    static func evaluate(
        reason: String,
        fallbackTitle: String = "使用密码"
    ) async -> Result {
        let context = LAContext()
        context.localizedCancelTitle = "取消"
        context.localizedFallbackTitle = fallbackTitle
        // The context is deliberately fresh for every request: a reused one
        // can answer from its previous evaluation, which would let a stale
        // success stand in for a new check.
        var policyError: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &policyError) else {
            return .unavailable
        }

        do {
            let success = try await context.evaluatePolicy(
                .deviceOwnerAuthentication,
                localizedReason: reason
            )
            return success ? .success : .failed
        } catch {
            let code = (error as NSError).code
            if code == LAError.Code.userCancel.rawValue
                || code == LAError.Code.systemCancel.rawValue
                || code == LAError.Code.appCancel.rawValue {
                return .cancelled
            }
            return .failed
        }
    }
}
