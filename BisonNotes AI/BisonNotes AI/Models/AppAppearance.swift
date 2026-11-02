//
//  AppAppearance.swift
//  BisonNotes AI
//
//  The app follows the system appearance unless the user turns on Always Dark.
//  The choice must never depend on size class: iPhone Duo crosses the compact /
//  regular boundary every time it opens or closes, and a size-class-keyed scheme
//  flipped the whole app between dark and light on every fold.
//

import SwiftUI

enum AppAppearance {
    static let alwaysDarkKey = "alwaysDarkAppearance"

    /// nil follows the system appearance.
    static func preferredColorScheme(alwaysDark: Bool) -> ColorScheme? {
        alwaysDark ? .dark : nil
    }
}
