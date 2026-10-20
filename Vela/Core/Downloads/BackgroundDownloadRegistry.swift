//
//  BackgroundDownloadRegistry.swift
//  Vela
//
//  The hand-off between UIKit's background-session launch and the download
//  service.
//
//  When iOS relaunches an app to deliver the events of a background
//  `URLSession`, it calls the application delegate first, with a completion
//  handler the app must call once every event has been processed. The service
//  that owns those sessions is built later, as part of the scene's
//  environment, so the identifier and the handler are parked here in the
//  meantime. The service installs a reconnector at boot and drains the parked
//  identifiers through it.
//

import Foundation

/// A small, thread-safe mailbox for background-session launch events.
final class BackgroundDownloadRegistry: @unchecked Sendable {
    static let shared = BackgroundDownloadRegistry()

    private let lock = NSLock()
    private var handlers: [String: () -> Void] = [:]
    private var pendingIdentifiers: Set<String> = []
    private var reconnector: ((String) -> Void)?

    private init() {}

    /// Called by the app delegate when iOS has events for `identifier`.
    func register(identifier: String, completion: @escaping () -> Void) {
        lock.lock()
        handlers[identifier] = completion
        let reconnect = reconnector
        if reconnect == nil {
            pendingIdentifiers.insert(identifier)
        }
        lock.unlock()

        reconnect?(identifier)
    }

    /// Installs the service's reconnector and drains anything that arrived
    /// before the service existed.
    func setReconnector(_ reconnect: @escaping (String) -> Void) {
        lock.lock()
        reconnector = reconnect
        let pending = pendingIdentifiers
        pendingIdentifiers.removeAll()
        lock.unlock()

        for identifier in pending {
            reconnect(identifier)
        }
    }

    /// Called from `URLSessionDelegate.urlSessionDidFinishEvents` once the
    /// session has delivered everything; releases the system's completion
    /// handler.
    func complete(identifier: String) {
        lock.lock()
        let handler = handlers.removeValue(forKey: identifier)
        lock.unlock()

        guard let handler else { return }
        DispatchQueue.main.async {
            handler()
        }
    }
}
