import SwiftUI

/// Short, critically damped motion; no overshoot or full-screen slide.
enum BrowserMotion {
    static func layout(_ reduced: Bool) -> Animation { reduced ? .easeOut(duration: 0.12) : .spring(response: 0.38, dampingFraction: 0.92) }
    static func overview(_ reduced: Bool) -> Animation { reduced ? .easeOut(duration: 0.14) : .spring(response: 0.42, dampingFraction: 0.94) }
}
