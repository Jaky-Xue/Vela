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
    private var handler: ((BrowserCommand) -> Void)?

    public init() {}

    public func register(_ handler: @escaping (BrowserCommand) -> Void) {
        self.handler = handler
    }

    public func unregister() {
        handler = nil
    }

    public func perform(_ command: BrowserCommand) {
        handler?(command)
    }

    public var isAvailable: Bool { handler != nil }
}
