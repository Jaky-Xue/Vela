//
//  CrashDiagnosticsService.swift
//  Vela
//
//  The missing half of the diagnostics story: the app's own crashes and hangs,
//  not just its navigations.
//
//  MetricKit delivers diagnostics on the launch after the event; nothing can be
//  captured while the process is dead. The service keeps the most recent
//  summary in memory and, for Objective-C exceptions that do not become a
//  MetricKit report until later, an exception reason in UserDefaults. The
//  diagnostics screen reads both, which is what turns "重新打开崩溃" from an
//  unanswerable report into a timestamped reason.
//

import Foundation
import MetricKit
import Observation

@MainActor
@Observable
public final class CrashDiagnosticsService {
    /// The latest MetricKit summary, once the system has delivered one.
    public private(set) var metricKitReport: String?
    /// The reason of the last uncaught Objective-C exception, if one was
    /// recorded before the process terminated.
    public private(set) var lastException: String?
    /// The last interactions of the previous session, newest last. Written on
    /// every note, so a crash on the next launch still has the actions that led
    /// to it — the one piece of context a crash report cannot supply.
    public private(set) var previousSessionBreadcrumbs: String?

    private let subscriber = DiagnosticSubscriber()
    private var breadcrumbs: [String] = []
    private static let exceptionKey = "org.vela.browser.last-uncaught-exception"
    private static let breadcrumbKey = "org.vela.browser.session-breadcrumbs"
    private static let breadcrumbLimit = 24

    public init() {
        lastException = UserDefaults.standard.string(forKey: Self.exceptionKey)
        previousSessionBreadcrumbs = UserDefaults.standard.string(forKey: Self.breadcrumbKey)
        UserDefaults.standard.removeObject(forKey: Self.breadcrumbKey)
        subscriber.owner = self
        MXMetricManager.shared.add(subscriber)
        NSSetUncaughtExceptionHandler { exception in
            // A C-convention handler cannot capture context; the literal key
            // is the same one the service reads on the next launch.
            let reason = "\(exception.name.rawValue): \(exception.reason ?? "")"
            UserDefaults.standard.set(
                reason,
                forKey: "org.vela.browser.last-uncaught-exception"
            )
        }
    }

    fileprivate func record(_ report: String) {
        metricKitReport = report
    }

    /// Appends one interaction to this session's trail. The write is small and
    /// happens on a user action, not per frame.
    public func recordBreadcrumb(_ label: String) {
        let trimmed = label.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let time = Date().formatted(date: .omitted, time: .standard)
        breadcrumbs.append("[\(time)] \(trimmed)")
        if breadcrumbs.count > Self.breadcrumbLimit {
            breadcrumbs.removeFirst(breadcrumbs.count - Self.breadcrumbLimit)
        }
        UserDefaults.standard.set(
            breadcrumbs.joined(separator: "\n"),
            forKey: Self.breadcrumbKey
        )
    }

    public func clear() {
        metricKitReport = nil
        lastException = nil
        previousSessionBreadcrumbs = nil
        breadcrumbs.removeAll()
        UserDefaults.standard.removeObject(forKey: Self.exceptionKey)
        UserDefaults.standard.removeObject(forKey: Self.breadcrumbKey)
    }

    public var hasAnyReport: Bool {
        metricKitReport != nil
            || lastException != nil
            || !(previousSessionBreadcrumbs ?? "").isEmpty
    }

    public var reportText: String {
        var parts: [String] = []
        if let lastException, !lastException.isEmpty {
            parts.append("未捕获异常：\(lastException)")
        }
        if let metricKitReport, !metricKitReport.isEmpty {
            parts.append(metricKitReport)
        }
        if let previousSessionBreadcrumbs, !previousSessionBreadcrumbs.isEmpty {
            parts.append("上次会话最后动作：\n" + previousSessionBreadcrumbs)
        }
        return parts.isEmpty ? "暂无崩溃/卡顿报告。" : parts.joined(separator: "\n")
    }
}

/// MetricKit's callback is delivered off the main actor. The subscriber owns no
/// state beyond a weak owner and hands the formatted summary back explicitly.
private final class DiagnosticSubscriber: NSObject, MXMetricManagerSubscriber {
    weak var owner: CrashDiagnosticsService?

    func didReceive(_ payloads: [MXMetricPayload]) {}

    func didReceive(_ payloads: [MXDiagnosticPayload]) {
        let crashes = payloads.reduce(0) { total, payload in
            total + (payload.crashDiagnostics?.count ?? 0)
        }
        let hangs = payloads.reduce(0) { total, payload in
            total + (payload.hangDiagnostics?.count ?? 0)
        }
        guard crashes > 0 || hangs > 0 else { return }
        let report = "系统诊断（MetricKit）：崩溃 \(crashes) 条，卡顿 \(hangs) 条。"
        Task { @MainActor [weak owner] in
            owner?.record(report)
        }
    }
}
