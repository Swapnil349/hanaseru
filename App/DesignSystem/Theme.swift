import SwiftUI
import UIKit

/// Colours drawn from Japanese railway information design rather than cliché imagery (spec §49):
/// the ivory and blue line of a Tōkaidō Shinkansen, platform-sign amber for "your turn", and the
/// quiet greys of station signage. Every colour has a dark-mode pair.
enum Palette {
    static let background = Color(light: 0xF4F3EE, dark: 0x0B111A)
    static let surface = Color(light: 0xFFFFFF, dark: 0x141C28)
    static let surfaceMuted = Color(light: 0xEAE8E1, dark: 0x1B2533)
    static let ink = Color(light: 0x111827, dark: 0xECEFF4)
    static let inkSecondary = Color(light: 0x596373, dark: 0x9BA6B5)
    static let hairline = Color(light: 0xD9D6CC, dark: 0x273345)
    /// The blue stripe along a Shinkansen's body.
    static let line = Color(light: 0x1C4E9B, dark: 0x6F9CEB)
    /// Platform-sign amber: it's your turn to speak.
    static let signal = Color(light: 0xC98A00, dark: 0xF2B63A)
    static let go = Color(light: 0x2B7A4B, dark: 0x5CC48A)
    static let caution = Color(light: 0xB54708, dark: 0xF79A5B)
}

enum Metrics {
    static let corner: CGFloat = 16
    static let padding: CGFloat = 20
}

extension Color {
    init(light: UInt32, dark: UInt32) {
        self.init(uiColor: UIColor { traits in
            UIColor(hex: traits.userInterfaceStyle == .dark ? dark : light)
        })
    }
}

extension UIColor {
    convenience init(hex: UInt32) {
        self.init(
            red: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: 1
        )
    }
}
