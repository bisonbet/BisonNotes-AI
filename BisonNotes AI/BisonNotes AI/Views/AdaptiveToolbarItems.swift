//
//  AdaptiveToolbarItems.swift
//  BisonNotes AI
//
//  Sheet toolbar buttons that iPhone Duo can place in its vertical bar.
//
//  The vertical bar only takes items that have a symbol; a text-only "Done" or
//  "Cancel" stays in a horizontal bar and costs the outer display a row of
//  content. On iOS 26 and later these use the system close, cancel and confirm
//  roles with a symbol, keeping the old word as the accessibility label (UI
//  tests and VoiceOver still find "Done"). Earlier iOS and macOS keep the text
//  buttons they always had.
//

import SwiftUI

/// Dismisses a sheet that has nothing to save.
struct SheetDoneButton: View {
    var title: LocalizedStringKey = "Done"
    let action: () -> Void

    var body: some View {
        #if os(iOS)
        if #available(iOS 26.0, *) {
            Button(role: .close, action: action) {
                Label(title, systemImage: "xmark")
            }
        } else {
            Button(title, action: action)
        }
        #else
        Button(title, action: action)
        #endif
    }
}

/// Abandons the edit a sheet was making.
struct SheetCancelButton: View {
    var title: LocalizedStringKey = "Cancel"
    let action: () -> Void

    var body: some View {
        #if os(iOS)
        if #available(iOS 26.0, *) {
            Button(role: .cancel, action: action) {
                Label(title, systemImage: "xmark")
            }
        } else {
            Button(title, role: .cancel, action: action)
        }
        #else
        Button(title, role: .cancel, action: action)
        #endif
    }
}

/// Commits the edit a sheet was making ("Save", "Apply").
struct SheetConfirmButton: View {
    let title: LocalizedStringKey
    let action: () -> Void

    var body: some View {
        #if os(iOS)
        if #available(iOS 26.0, *) {
            Button(role: .confirm, action: action) {
                Label(title, systemImage: "checkmark")
            }
        } else {
            Button(title, action: action)
        }
        #else
        Button(title, action: action)
        #endif
    }
}
