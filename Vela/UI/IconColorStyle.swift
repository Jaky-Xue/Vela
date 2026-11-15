import SwiftUI

/// Stable colors shared by menu and settings; white glyph contrast >= 4.5:1.
enum IconColorStyle {
    static let hexColors: [UInt32] = [0x2156C6, 0x007565, 0x8338A8, 0xB03849, 0xA85216, 0x326D35, 0x246B87, 0x6645AD]
    static func index(for key: String) -> Int {
        Int(key.utf8.reduce(UInt64(5381)) { ($0 &* 33) &+ UInt64($1) } % UInt64(hexColors.count))
    }
    static func color(for key: String) -> Color { Color(velaHex: hexColors[index(for: key)]) }
    static func lineColor(for key: String) -> Color {
        let bright: [UInt32] = [0x91B8FF, 0x79DEC9, 0xD4A5F6, 0xFFA4B6, 0xFFC18C, 0xA1DAA1, 0x8CCFE9, 0xC8B1FF]
        let light = UIColor(Color(velaHex: hexColors[index(for: key)]))
        let dark = UIColor(Color(velaHex: bright[index(for: key)]))
        return Color(uiColor: UIColor { trait in trait.userInterfaceStyle == .dark ? dark : light })
    }
    static func gradient(for key: String) -> LinearGradient {
        let color = color(for: key)
        return LinearGradient(colors: [color, color.opacity(0.92)], startPoint: .topLeading, endPoint: .bottomTrailing)
    }
}

extension Color {
    init(velaHex value: UInt32) {
        self.init(red: Double((value >> 16) & 255) / 255,
                  green: Double((value >> 8) & 255) / 255,
                  blue: Double(value & 255) / 255)
    }
}
