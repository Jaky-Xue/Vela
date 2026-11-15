import SwiftUI

/// Short, critically damped motion; no overshoot or full-screen slide.
enum BrowserMotion {
    static func layout(_ reduced: Bool) -> Animation? { reduced ? nil : .spring(response: 0.38, dampingFraction: 0.92) }
    static func overview(_ reduced: Bool) -> Animation { reduced ? .easeOut(duration: 0.14) : .spring(response: 0.42, dampingFraction: 0.94) }

    /// A menu tile being carried. Short and only lightly damped: the tiles it
    /// is displacing should settle under the finger, not trail behind it.
    static func tileDrag(_ reduced: Bool) -> Animation? {
        reduced ? nil : .spring(response: 0.32, dampingFraction: 0.82)
    }
}
