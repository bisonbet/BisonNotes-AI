import SwiftUI

extension Color {
    /// Background for filled primary-action buttons.
    ///
    /// Explicit rather than `Color.accentColor`: white text on the system accent
    /// measures roughly 3.6:1 in light mode and less in dark, which the
    /// accessibility audit reports as "Contrast nearly passed" — below the 4.5:1
    /// WCAG AA threshold for body-sized text. This blue measures about 7.5:1
    /// against white in both appearances.
    static let bisonPrimaryAction = Color(red: 0.0, green: 0.32, blue: 0.68)
}
