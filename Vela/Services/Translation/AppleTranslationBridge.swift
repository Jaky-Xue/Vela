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
    /// - Parameter source: The page's detected language tag, when one is
    ///   known. Passing it to the session avoids a second auto-detection pass
    ///   over HTML fragments, which is where a batch of short paragraphs is
    ///   most likely to be misread.
    func translate(
        _ texts: [String],
        target: TranslationTargetLanguage,
        source: String?
    ) async throws -> [String]
}

@available(iOS 18.0, *)
@MainActor
@Observable
final class AppleTranslationBridge: AppleTranslationBridging {
    private struct Job {
        let id = UUID()
        let texts: [String]
        let target: TranslationTargetLanguage
        let source: String?
        let continuation: CheckedContinuation<[String], Error>
    }

    private var pending: Job?
    /// Changing this value starts `.translationTask` with a fresh session.
    var configuration: TranslationSession.Configuration?

    func translate(
        _ texts: [String],
        target: TranslationTargetLanguage,
        source: String?
    ) async throws -> [String] {
        // A job whose session never arrived used to block every later request
        // with "系统翻译正在处理另一批段落" for the life of the app. Replace it
        // and terminate the old waiter instead of refusing the new work.
        if let existing = pending {
            pending = nil
            existing.continuation.resume(
                throwing: TranslationError.failed("翻译会话已被新的请求取代。")
            )
        }

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<[String], Error>) in
                let job = Job(
                    texts: texts,
                    target: target,
                    source: source,
                    continuation: continuation
                )
                pending = job

                let normalizedSource = source?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                let configuration = TranslationSession.Configuration(
                    source: (normalizedSource?.isEmpty == false)
                        ? Locale.Language(identifier: normalizedSource!)
                        : nil,
                    target: Locale.Language(identifier: target.appleTranslationCode)
                )
                // A nil → value transition makes the modifier create a new
                // session even when two consecutive batches target the same
                // language.
                self.configuration = nil
                Task { @MainActor [weak self] in
                    await Task.yield()
                    self?.configuration = configuration
                }

                // A host view that never delivers a session must not leave the
                // bridge permanently busy.
                Task { @MainActor [weak self] in
                    try? await Task.sleep(for: .seconds(25))
                    guard let self, self.pending?.id == job.id else { return }
                    let stuck = self.pending
                    self.pending = nil
                    stuck?.continuation.resume(
                        throwing: TranslationError.failed("系统翻译超时。")
                    )
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                guard let self, let job = self.pending else { return }
                self.pending = nil
                job.continuation.resume(throwing: CancellationError())
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
