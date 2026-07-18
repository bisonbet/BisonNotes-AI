//
//  PlatformViewShims.swift
//  BisonNotes AI
//
//  No-op / remapped implementations of iOS-only SwiftUI API so shared views
//  compile unchanged on native macOS. Toolbar placements map to their closest
//  macOS equivalents; keyboard- and navigation-bar-specific modifiers are
//  meaningless on macOS and become no-ops.
//

#if os(macOS)
import SwiftUI

extension ToolbarItemPlacement {
    static var navigationBarLeading: ToolbarItemPlacement { .navigation }
    static var navigationBarTrailing: ToolbarItemPlacement { .primaryAction }
    static var topBarLeading: ToolbarItemPlacement { .navigation }
    static var topBarTrailing: ToolbarItemPlacement { .primaryAction }
}

/// Stand-in for PageTabViewStyle.IndexDisplayMode (iOS-only). macOS has no
/// paged TabView, so `.page(...)` maps to the default style.
struct PlatformPageIndexDisplayMode {
    static let automatic = PlatformPageIndexDisplayMode()
    static let always = PlatformPageIndexDisplayMode()
    static let never = PlatformPageIndexDisplayMode()
}

extension TabViewStyle where Self == DefaultTabViewStyle {
    static func page(indexDisplayMode: PlatformPageIndexDisplayMode = .automatic) -> DefaultTabViewStyle {
        .automatic
    }
}

/// WheelDatePickerStyle is iOS-only; map `.wheel` to the macOS default field style.
extension DatePickerStyle where Self == DefaultDatePickerStyle {
    static var wheel: DefaultDatePickerStyle { DefaultDatePickerStyle() }
}

enum PlatformTitleDisplayMode {
    case automatic, inline, large
}

enum PlatformAutocapitalizationType {
    case none, words, sentences, allCharacters
}

enum PlatformKeyboardType {
    // swiftlint:disable:next identifier_name
    case `default`, URL, numberPad, decimalPad, emailAddress, asciiCapable, numbersAndPunctuation
}

enum PlatformTextInputAutocapitalization {
    case never, words, sentences, characters
}

extension PickerStyle where Self == MenuPickerStyle {
    /// iOS-only picker styles map to a menu picker on macOS.
    static var navigationLink: MenuPickerStyle { MenuPickerStyle() }
    static var wheel: MenuPickerStyle { MenuPickerStyle() }
}

extension View {
    /// macOS has no full-screen covers; present as a regular sheet.
    func fullScreenCover<Content: View>(
        isPresented: Binding<Bool>,
        onDismiss: (() -> Void)? = nil,
        @ViewBuilder content: @escaping () -> Content
    ) -> some View {
        sheet(isPresented: isPresented, onDismiss: onDismiss, content: content)
    }

    func navigationBarTitleDisplayMode(_ mode: PlatformTitleDisplayMode) -> some View { self }
    func autocapitalization(_ type: PlatformAutocapitalizationType) -> some View { self }
    func keyboardType(_ type: PlatformKeyboardType) -> some View { self }
    func navigationBarHidden(_ hidden: Bool) -> some View { self }
    func textInputAutocapitalization(_ autocapitalization: PlatformTextInputAutocapitalization?) -> some View { self }
}
#endif
