import SwiftUI

extension Color {
    /// Foreground for links and control tint; adapts to appearance and Increase Contrast.
    static let bisonActionForeground = Color("AccentColor")

    /// Opaque fill behind white labels, providing about 7.5:1 contrast.
    /// Keep separate from the adaptive foreground accent: its dark-mode variant
    /// is intentionally light and cannot provide enough contrast with white text.
    static let bisonPrimaryAction = Color(red: 0.0, green: 0.32, blue: 0.68)
}
