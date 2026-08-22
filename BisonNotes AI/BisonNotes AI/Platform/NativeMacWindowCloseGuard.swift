//
//  NativeMacWindowCloseGuard.swift
//  BisonNotes AI
//

#if os(macOS)
import AppKit
import SwiftUI

/// Installs a close decision only on the containing window. The existing
/// delegate is consulted first and restored when this view leaves the window,
/// so document close protection cannot change unrelated Mac windows.
struct NativeMacWindowCloseGuard: NSViewRepresentable {
    let allowsClose: () -> Bool
    let onCloseBlocked: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(allowsClose: allowsClose, onCloseBlocked: onCloseBlocked)
    }

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        view.setContentHuggingPriority(.defaultLow, for: .horizontal)
        view.setContentHuggingPriority(.defaultLow, for: .vertical)
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.allowsClose = allowsClose
        context.coordinator.onCloseBlocked = onCloseBlocked
        context.coordinator.attachIfNeeded(to: nsView.window)

        if nsView.window == nil {
            DispatchQueue.main.async { [weak coordinator = context.coordinator, weak nsView] in
                coordinator?.attachIfNeeded(to: nsView?.window)
            }
        }
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        coordinator.detach()
    }

    final class Coordinator: NSObject, NSWindowDelegate {
        var allowsClose: () -> Bool
        var onCloseBlocked: () -> Void

        private weak var attachedWindow: NSWindow?
        private weak var previousDelegate: NSWindowDelegate?

        init(allowsClose: @escaping () -> Bool, onCloseBlocked: @escaping () -> Void) {
            self.allowsClose = allowsClose
            self.onCloseBlocked = onCloseBlocked
        }

        @MainActor
        func attachIfNeeded(to window: NSWindow?) {
            guard let window, attachedWindow !== window else { return }

            detach()
            attachedWindow = window
            previousDelegate = window.delegate === self ? nil : window.delegate
            window.delegate = self
        }

        @MainActor
        func detach() {
            guard let window = attachedWindow else { return }
            if window.delegate === self {
                window.delegate = previousDelegate
            }
            attachedWindow = nil
            previousDelegate = nil
        }

        func windowShouldClose(_ sender: NSWindow) -> Bool {
            if let previousDelegate,
               previousDelegate !== self,
               previousDelegate.windowShouldClose?(sender) == false {
                return false
            }

            guard allowsClose() else {
                onCloseBlocked()
                return false
            }
            return true
        }
    }
}
#endif
