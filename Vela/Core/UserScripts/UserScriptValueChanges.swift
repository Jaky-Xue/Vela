import Foundation

extension Notification.Name {
    static let velaScriptValueChanged = Notification.Name("org.vela.script-value-changed")
}

final class UserScriptValueObserver: @unchecked Sendable {
    var token: NSObjectProtocol?
    deinit { if let token { NotificationCenter.default.removeObserver(token) } }
}
