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

    private let subscriber = DiagnosticSubscriber()
    private static let exceptionKey = "org.vela.browser.last-uncaught-exception"

    public init() {
        lastException = UserDefaults.standard.string(forKey: Self.exceptionKey)
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

    public func clear() {
        metricKitReport = nil
        lastException = nil
        UserDefaults.standard.removeObject(forKey: Self.exceptionKey)
    }

    public var hasAnyReport: Bool {
        metricKitReport != nil || lastException != nil
    }

    public var reportText: String {
        var parts: [String] = []
        if let lastException, !lastException.isEmpty {
            parts.append("未捕获异常：\(lastException)")
        }
        if let metricKitReport, !metricKitReport.isEmpty {
            parts.append(metricKitReport)
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
