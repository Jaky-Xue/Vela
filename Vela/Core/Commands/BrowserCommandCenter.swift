//
//  BrowserCommandCenter.swift
//  Vela
//
//  The one link between the menu-bar commands and the shell.
//
//  SwiftUI's `Commands` scene is built by the app, while the actions it drives
//  live in `BrowserShellView`. Rather than thread the shell's state through the
//  scene, the shell registers one handler here on appear and the commands call
//  `perform`. A command pressed before the shell is on screen is a no-op.
//

import Foundation
import Observation

@MainActor
@Observable
public final class BrowserCommandCenter {
    /// One handler per window, in the order the windows registered.
    ///
    /// A `Commands` menu is a property of the app, but the tabs a command acts
    /// on belong to a window. The most recently registered window is the one
    /// the command drives; when it closes it removes only its own handler, so
    /// the window behind it keeps working.
    private var handlers: [String: (BrowserCommand) -> Void] = [:]
    private var order: [String] = []

    public init() {}

    public func register(owner: String, _ handler: @escaping (BrowserCommand) -> Void) {
        handlers[owner] = handler
        order.removeAll { $0 == owner }
        order.append(owner)
    }

    public func unregister(owner: String) {
        handlers.removeValue(forKey: owner)
        order.removeAll { $0 == owner }
    }

    public func perform(_ command: BrowserCommand) {
        guard let owner = order.last else { return }
        handlers[owner]?(command)
    }

    public var isAvailable: Bool { !order.isEmpty }
}
