//
//  AppleTranslationBridge.swift
//  Vela
//
//  The on-device Translation framework, behind the same small interface the
//  network providers use.
//
//  `TranslationSession` is handed to a SwiftUI `.translationTask` modifier;
//  it cannot be constructed as a free-standing client. This bridge owns the
//  one hidden host view, turns a page batch into `TranslationSession.Request`s,
//  and resumes the waiting caller when the session yields its responses. The
//  framework downloads language packs through its own UI, so translation can
//  keep working when a VPN makes Google unreachable.
//

import Foundation
import Observation
import SwiftUI
import Translation

/// The availability-agnostic seam TranslationService depends on.
@MainActor
protocol AppleTranslationBridging: AnyObject {
    func translate(_ texts: [String], target: TranslationTargetLanguage) async throws -> [String]
}

@available(iOS 18.0, *)
@MainActor
@Observable
final class AppleTranslationBridge: AppleTranslationBridging {
    private struct Job {
        let texts: [String]
        let target: TranslationTargetLanguage
        let continuation: CheckedContinuation<[String], Error>
    }

    private var pending: Job?
    /// Changing this value starts `.translationTask` with a fresh session.
    var configuration: TranslationSession.Configuration?

    func translate(
        _ texts: [String],
        target: TranslationTargetLanguage
    ) async throws -> [String] {
        guard pending == nil else {
            throw TranslationError.failed("系统翻译正在处理另一批段落，请稍后再试。")
        }
        return try await withCheckedThrowingContinuation { continuation in
            pending = Job(texts: texts, target: target, continuation: continuation)
            let configuration = TranslationSession.Configuration(
                source: nil,
                target: Locale.Language(identifier: target.appleTranslationCode)
            )
            // A nil → value transition makes the modifier create a new session
            // even when two consecutive batches target the same language.
            self.configuration = nil
            Task { @MainActor [weak self] in
                await Task.yield()
                self?.configuration = configuration
            }
        }
    }

    func run(_ session: TranslationSession) async {
        guard let job = pending else { return }
        pending = nil

        let requests = job.texts.enumerated().map { index, text in
            TranslationSession.Request(
                sourceText: text,
                clientIdentifier: String(index)
            )
        }
        var values = [String?](repeating: nil, count: job.texts.count)
        do {
            // Presents the system language-download flow when the pair is not
            // installed yet; no page text leaves the device.
            try await session.prepareTranslation()
            for try await response in session.translate(batch: requests) {
                if let identifier = response.clientIdentifier,
                   let index = Int(identifier),
                   values.indices.contains(index) {
                    values[index] = response.targetText
                }
            }
            job.continuation.resume(returning: values.map { $0 ?? "" })
        } catch {
            job.continuation.resume(throwing: error)
        }
        configuration = nil
    }
}

@available(iOS 18.0, *)
struct AppleTranslationHost: View {
    @Bindable var bridge: AppleTranslationBridge

    var body: some View {
        Color.clear
            .frame(width: 1, height: 1)
            .translationTask(bridge.configuration) { session in
                await bridge.run(session)
            }
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}
