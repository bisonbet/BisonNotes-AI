//
//  PlatformColors.swift
//  BisonNotes AI
//
//  UIKit system-color names mapped to AppKit dynamic colors so shared SwiftUI
//  code can keep writing Color(.systemGroupedBackground) etc. on native macOS.
//  The systemGray4-6 values are the UIKit light-mode constants with dark-mode
//  variants supplied via dynamic providers.
//

#if os(macOS)
import SwiftUI
import AppKit

extension NSColor {
    static var systemBackground: NSColor { .windowBackgroundColor }
    static var systemGroupedBackground: NSColor { .windowBackgroundColor }
    static var secondarySystemGroupedBackground: NSColor { .controlBackgroundColor }
    static var tertiarySystemGroupedBackground: NSColor { .underPageBackgroundColor }
    static var separator: NSColor { .separatorColor }

    static var systemGray4: NSColor { dynamicGray(light: 0xD1D1D6, dark: 0x3A3A3C) }
    static var systemGray5: NSColor { dynamicGray(light: 0xE5E5EA, dark: 0x2C2C2E) }
    static var systemGray6: NSColor { dynamicGray(light: 0xF2F2F7, dark: 0x1C1C1E) }

    private static func dynamicGray(light: Int, dark: Int) -> NSColor {
        NSColor(name: nil) { appearance in
            let rgb = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
            return NSColor(
                srgbRed: CGFloat((rgb >> 16) & 0xFF) / 255.0,
                green: CGFloat((rgb >> 8) & 0xFF) / 255.0,
                blue: CGFloat(rgb & 0xFF) / 255.0,
                alpha: 1.0
            )
        }
    }
}

extension Color {
    /// Mirrors UIKit's unlabeled Color(_: UIColor) initializer so shared code
    /// using implicit-member color names compiles against NSColor on macOS.
    init(_ nsColor: NSColor) {
        self.init(nsColor: nsColor)
    }
}
#endif
