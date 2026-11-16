import XCTest
import SwiftUI
import UIKit
@testable import BisonNotes_AI

@MainActor
final class ActionColorContrastTests: XCTestCase {
    func testActionForegroundAcrossAppearancesAndContrastSettings() throws {
        let foreground = try XCTUnwrap(UIColor(named: "AccentColor"))
        for appearance in [UIUserInterfaceStyle.light, .dark] {
            for contrast in [UIAccessibilityContrast.normal, .high] {
                let traits = UITraitCollection {
                    $0.userInterfaceStyle = appearance
                    $0.accessibilityContrast = contrast
                }
                for background in [UIColor.systemBackground, .secondarySystemGroupedBackground,
                                   .tertiarySystemGroupedBackground] {
                    XCTAssertGreaterThanOrEqual(
                        try ratio(foreground, background, traits: traits), 4.5,
                        "Action foreground must remain readable: \(appearance), \(contrast)"
                    )
                }
                XCTAssertGreaterThanOrEqual(
                    try ratio(.systemRed, .tertiarySystemGroupedBackground, traits: traits), 3,
                    "Destructive icons need non-text contrast"
                )
            }
        }
    }

    func testActionForegroundOnTintedSurfaces() throws {
        let foreground = try XCTUnwrap(UIColor(named: "AccentColor"))
        for appearance in [UIUserInterfaceStyle.light, .dark] {
            for contrast in [UIAccessibilityContrast.normal, .high] {
                let traits = UITraitCollection {
                    $0.userInterfaceStyle = appearance
                    $0.accessibilityContrast = contrast
                }
                for background in [UIColor.systemBackground, .secondarySystemGroupedBackground,
                                   .tertiarySystemGroupedBackground] {
                    for opacity in [CGFloat(0.10), 0.12, 0.14, 0.18] {
                        let surface = try composite(foreground, over: background, opacity: opacity, traits: traits)
                        XCTAssertGreaterThanOrEqual(try ratio(foreground, surface, traits: traits), 4.5)
                    }
                }
            }
        }
    }

    private func composite(_ tint: UIColor, over background: UIColor,
                           opacity: CGFloat, traits: UITraitCollection) throws -> UIColor {
        var tintRed: CGFloat = 0, tintGreen: CGFloat = 0, tintBlue: CGFloat = 0, tintAlpha: CGFloat = 0
        var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
        XCTAssertTrue(tint.resolvedColor(with: traits).getRed(
            &tintRed, green: &tintGreen, blue: &tintBlue, alpha: &tintAlpha
        ))
        XCTAssertTrue(background.resolvedColor(with: traits).getRed(&red, green: &green, blue: &blue, alpha: &alpha))
        return UIColor(red: tintRed * opacity + red * (1 - opacity),
                       green: tintGreen * opacity + green * (1 - opacity),
                       blue: tintBlue * opacity + blue * (1 - opacity), alpha: 1)
    }

    func testPrimaryFillKeepsWhiteLabelsReadable() throws {
        XCTAssertGreaterThanOrEqual(
            try ratio(.white, UIColor(Color.bisonPrimaryAction), traits: UITraitCollection()), 7
        )
    }

    private func ratio(_ first: UIColor, _ second: UIColor, traits: UITraitCollection) throws -> Double {
        let light = try luminance(first.resolvedColor(with: traits))
        let dark = try luminance(second.resolvedColor(with: traits))
        return (max(light, dark) + 0.05) / (min(light, dark) + 0.05)
    }

    private func luminance(_ color: UIColor) throws -> Double {
        var red: CGFloat = 0
        var green: CGFloat = 0
        var blue: CGFloat = 0
        var alpha: CGFloat = 0
        XCTAssertTrue(color.getRed(&red, green: &green, blue: &blue, alpha: &alpha))
        func linear(_ value: CGFloat) -> Double {
            let value = Double(value)
            return value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linear(red) + 0.7152 * linear(green) + 0.0722 * linear(blue)
    }
}
