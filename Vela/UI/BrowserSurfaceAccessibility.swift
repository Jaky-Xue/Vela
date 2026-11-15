import SwiftUI

private struct BrowserOpaqueSurfacesKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    /// A conservative opaque presentation, also used by visual previews.
    /// It may strengthen the system setting but can never turn it off.
    var browserOpaqueSurfaces: Bool {
        get { self[BrowserOpaqueSurfacesKey.self] }
        set { self[BrowserOpaqueSurfacesKey.self] = newValue }
    }

    var browserReduceTransparency: Bool {
        accessibilityReduceTransparency || browserOpaqueSurfaces
    }
}
