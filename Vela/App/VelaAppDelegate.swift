//
//  VelaAppDelegate.swift
//  Vela
//
//  The one thing SwiftUI's lifecycle does not expose: the call iOS makes when
//  it has events for a background `URLSession`.
//
//  `application(_:handleEventsForBackgroundURLSession:completionHandler:)` has
//  no SwiftUI equivalent. Without it, a background transfer that finishes while
//  the app is not running is delivered to nothing, and the system's completion
//  handler is never called — which reads, from the URLSession daemon's side, as
//  an app that ignored its own download.
//

import UIKit

final class VelaAppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        handleEventsForBackgroundURLSession identifier: String,
        completionHandler: @escaping () -> Void
    ) {
        BackgroundDownloadRegistry.shared.register(
            identifier: identifier,
            completion: completionHandler
        )
    }
}
