//
//  MainThreadHangMonitor.swift
//  Vela
//
//  A small watchdog for the failure mode navigation diagnostics cannot see:
//  the app is alive but the main thread has stopped answering.
//
//  Navigation events are recorded inside WebKit callbacks, so they necessarily
//  stop arriving during a hang. The watchdog runs its timer on a background
//  queue, asks the main actor for a heartbeat, and records the gap once the
//  main thread is able to answer again. It deliberately does not try to sample
//  the blocked stack: suspending threads from a watchdog is a crash risk of its
//  own, and "the main thread was unresponsive for 2.4s on this page" is enough
//  to correlate with the user's report.
//

import Foundation
import UIKit

@MainActor
final class MainThreadHangMonitor {
    /// A gap at least this long is reported. Normal SwiftUI/WebKit work can
    /// occupy the main actor for a frame or two; a second is already a stall a
    /// person notices.
    private let threshold: TimeInterval
    private let onHang: @MainActor (Int) -> Void

    private let queue = DispatchQueue(
        label: "org.vela.browser.main-thread-watchdog",
        qos: .utility
    )
    private var timer: DispatchSourceTimer?
    private var observers: [NSObjectProtocol] = []
    private var lastBeat = Date()

    init(threshold: TimeInterval = 2.0, onHang: @escaping @MainActor (Int) -> Void) {
        self.threshold = threshold
        self.onHang = onHang
    }

    func start() {
        guard timer == nil else { return }
        lastBeat = Date()

        // A transition through the background is not a hang: the app was
        // suspended, so the heartbeat could not run. Reset the clock when the
        // scene becomes active again.
        let center = NotificationCenter.default
        observers.append(center.addObserver(
            forName: UIApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.lastBeat = Date()
            }
        })
        observers.append(center.addObserver(
            forName: UIApplication.willResignActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.lastBeat = Date()
            }
        })

        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(
            deadline: .now() + 1,
            repeating: 0.5,
            leeway: .milliseconds(100)
        )
        timer.setEventHandler { [weak self] in
            Task { @MainActor [weak self] in
                self?.beat()
            }
        }
        timer.resume()
        self.timer = timer
    }

    func stop() {
        timer?.cancel()
        timer = nil
        let center = NotificationCenter.default
        for observer in observers { center.removeObserver(observer) }
        observers.removeAll()
    }

    private func beat() {
        let now = Date()
        let gap = now.timeIntervalSince(lastBeat)
        lastBeat = now

        // A long gap after a suspension is a background transition, not a
        // stall; the observer above resets it, and this bound guards the paths
        // where the notification is delayed.
        guard gap >= threshold, gap < 20 else { return }
        guard UIApplication.shared.applicationState == .active else { return }
        onHang(Int(gap * 1_000))
    }
}
