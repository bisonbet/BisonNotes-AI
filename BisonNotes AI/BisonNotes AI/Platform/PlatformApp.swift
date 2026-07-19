//
//  PlatformApp.swift
//  BisonNotes AI
//
//  Cross-platform facade over the UIApplication capabilities the app uses.
//  iOS/Catalyst are UIKit-backed today; native macOS implementations arrive in
//  Phase 2 of docs/macos-migration-plan.md (NSWorkspace, ProcessInfo activities,
//  NSApplication lifecycle notifications).
//
//  Views should prefer @Environment(\.openURL) over PlatformApp.open.
//

import Foundation
#if canImport(UIKit)
import UIKit
#else
import AppKit
#endif

// MARK: - App-level services

enum PlatformApp {
    /// Open a URL in the default browser/handler. For use from managers;
    /// views should use @Environment(\.openURL).
    static func open(_ url: URL) {
        #if canImport(UIKit)
        UIApplication.shared.open(url)
        #else
        NSWorkspace.shared.open(url)
        #endif
    }

    static func canOpen(_ url: URL) -> Bool {
        #if canImport(UIKit)
        return UIApplication.shared.canOpenURL(url)
        #else
        return true
        #endif
    }

    static var isActive: Bool {
        #if canImport(UIKit)
        return UIApplication.shared.applicationState == .active
        #else
        return true
        #endif
    }

    static var isInBackground: Bool {
        #if canImport(UIKit)
        return UIApplication.shared.applicationState == .background
        #else
        return false
        #endif
    }

    static var isProtectedDataAvailable: Bool {
        #if canImport(UIKit)
        return UIApplication.shared.isProtectedDataAvailable
        #else
        return true
        #endif
    }
}

// MARK: - Pasteboard

enum PlatformPasteboard {
    /// The general pasteboard's plain-text contents.
    static var string: String? {
        get {
            #if canImport(UIKit)
            return UIPasteboard.general.string
            #else
            return NSPasteboard.general.string(forType: .string)
            #endif
        }
        set {
            #if canImport(UIKit)
            UIPasteboard.general.string = newValue
            #else
            NSPasteboard.general.clearContents()
            if let newValue {
                NSPasteboard.general.setString(newValue, forType: .string)
            }
            #endif
        }
    }
}

// MARK: - Alerts

/// Imperatively presents a simple alert from non-SwiftUI contexts (error paths
/// in async tasks). On iOS it presents a UIAlertController from the key window's
/// root controller; on macOS it runs an NSAlert modally.
enum PlatformAlert {
    struct Action {
        let title: String
        let isCancel: Bool
        let handler: (() -> Void)?

        init(title: String, isCancel: Bool = false, handler: (() -> Void)? = nil) {
            self.title = title
            self.isCancel = isCancel
            self.handler = handler
        }
    }

    @MainActor
    static func present(title: String, message: String, actions: [Action] = [Action(title: "OK")]) {
        #if canImport(UIKit)
        let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
        for action in actions {
            alert.addAction(UIAlertAction(
                title: action.title,
                style: action.isCancel ? .cancel : .default
            ) { _ in action.handler?() })
        }
        if let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
           let rootViewController = windowScene.windows.first?.rootViewController {
            rootViewController.present(alert, animated: true)
        }
        #else
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        for action in actions {
            alert.addButton(withTitle: action.title)
        }
        let response = alert.runModal()
        let index = response.rawValue - NSApplication.ModalResponse.alertFirstButtonReturn.rawValue
        if index >= 0, index < actions.count {
            actions[index].handler?()
        }
        #endif
    }
}

#if os(macOS)
// MARK: - Native Mac sharing

/// Owns the AppKit sharing picker for manager-driven and SwiftUI export flows.
/// Retaining the picker here keeps its delegate alive until a service is chosen
/// or the popover is dismissed.
@MainActor
final class PlatformSharingPresenter: NSObject, NSSharingServicePickerDelegate {
    static let shared = PlatformSharingPresenter()

    private var picker: NSSharingServicePicker?
    private var subject: String?
    private var onDismiss: (() -> Void)?

    @discardableResult
    func present(
        items: [Any],
        subject: String? = nil,
        onPresented: () -> Void = {},
        onDismiss: @escaping () -> Void = {}
    ) -> Bool {
        guard picker == nil, !items.isEmpty, let anchorView = Self.anchorView else {
            return false
        }

        self.subject = subject
        self.onDismiss = onDismiss
        let picker = NSSharingServicePicker(items: items)
        picker.delegate = self
        self.picker = picker

        let anchorRect = NSRect(
            x: anchorView.bounds.midX,
            y: anchorView.bounds.midY,
            width: 1,
            height: 1
        )
        picker.show(relativeTo: anchorRect, of: anchorView, preferredEdge: .minY)
        onPresented()
        return true
    }

    func sharingServicePicker(
        _ sharingServicePicker: NSSharingServicePicker,
        didChoose service: NSSharingService?
    ) {
        service?.subject = subject
        picker = nil
        subject = nil
        let completion = onDismiss
        onDismiss = nil
        completion?()
    }

    private static var anchorView: NSView? {
        NSApp.keyWindow?.contentView
            ?? NSApp.mainWindow?.contentView
            ?? NSApp.windows.first(where: { $0.isVisible })?.contentView
    }
}
#endif

// MARK: - Device

enum PlatformDevice {
    /// True on any Mac: native macOS, Mac Catalyst, or iOS-app-on-Mac.
    /// Battery APIs are unreliable/absent in all three cases.
    static var isRunningOnMac: Bool {
        #if os(macOS) || targetEnvironment(macCatalyst)
        return true
        #else
        return ProcessInfo.processInfo.isiOSAppOnMac
        #endif
    }

    /// A stable per-install identifier. On iOS this is identifierForVendor;
    /// on macOS (no such API) we persist a generated UUID in UserDefaults.
    static var vendorIdentifier: String {
        #if canImport(UIKit)
        return UIDevice.current.identifierForVendor?.uuidString ?? UUID().uuidString
        #else
        let key = "PlatformDeviceVendorIdentifier"
        if let existing = UserDefaults.standard.string(forKey: key) {
            return existing
        }
        let generated = UUID().uuidString
        UserDefaults.standard.set(generated, forKey: key)
        return generated
        #endif
    }
}

// MARK: - Lifecycle notifications

/// Platform-neutral names for app lifecycle notifications.
/// Phase 2 maps these to NSApplication.* on native macOS.
enum PlatformLifecycle {
    #if canImport(UIKit)
    static let didFinishLaunchingNotification = UIApplication.didFinishLaunchingNotification
    static let didBecomeActiveNotification = UIApplication.didBecomeActiveNotification
    static let willResignActiveNotification = UIApplication.willResignActiveNotification
    static let didEnterBackgroundNotification = UIApplication.didEnterBackgroundNotification
    static let willEnterForegroundNotification = UIApplication.willEnterForegroundNotification
    static let willTerminateNotification = UIApplication.willTerminateNotification
    static let didReceiveMemoryWarningNotification = UIApplication.didReceiveMemoryWarningNotification
    #else
    static let didFinishLaunchingNotification = NSApplication.didFinishLaunchingNotification
    static let didBecomeActiveNotification = NSApplication.didBecomeActiveNotification
    static let willResignActiveNotification = NSApplication.willResignActiveNotification
    // macOS apps are not backgrounded; hide/unhide is the closest user-visible analog.
    static let didEnterBackgroundNotification = NSApplication.didHideNotification
    static let willEnterForegroundNotification = NSApplication.willUnhideNotification
    static let willTerminateNotification = NSApplication.willTerminateNotification
    // No macOS analog — never posted; observers simply stay idle.
    static let didReceiveMemoryWarningNotification = Notification.Name("BisonNotesPlatformMemoryWarning")
    #endif
}

// MARK: - Background task assertions

/// A platform assertion for user-initiated work that must continue when the app
/// is not frontmost. iOS uses a finite UIKit background task. Mac uses a
/// ProcessInfo activity to prevent App Nap while still allowing idle system sleep.
enum PlatformBackgroundTask {
    #if canImport(UIKit) && !targetEnvironment(macCatalyst)
    typealias ID = UIBackgroundTaskIdentifier
    static let invalidID: ID = .invalid

    static func begin(name: String, expirationHandler: (() -> Void)? = nil) -> ID {
        UIApplication.shared.beginBackgroundTask(withName: name, expirationHandler: expirationHandler)
    }

    static func end(_ id: ID) {
        UIApplication.shared.endBackgroundTask(id)
    }

    static var remainingTime: TimeInterval {
        UIApplication.shared.backgroundTimeRemaining
    }
    #else
    // Mac apps do not receive iOS expiration time. A ProcessInfo activity keeps
    // transcription and summarization responsive when the app is hidden.
    struct ID: Equatable {
        let rawValue: Int
        static let invalid = ID(rawValue: 0)
    }
    static let invalidID: ID = .invalid
    private static let activityRegistry = ActivityRegistry()

    static func begin(name: String, expirationHandler: (() -> Void)? = nil) -> ID {
        ID(rawValue: activityRegistry.begin(name: name))
    }

    static func end(_ id: ID) {
        guard id != .invalid else { return }
        activityRegistry.end(id: id.rawValue)
    }

    static var remainingTime: TimeInterval {
        .greatestFiniteMagnitude
    }

    private final class ActivityRegistry: @unchecked Sendable {
        private let lock = NSLock()
        private var nextID = 1
        private var activities: [Int: any NSObjectProtocol] = [:]

        func begin(name: String) -> Int {
            let activity = ProcessInfo.processInfo.beginActivity(
                options: .userInitiatedAllowingIdleSystemSleep,
                reason: name
            )
            lock.lock()
            defer { lock.unlock() }
            let id = nextID
            nextID += 1
            activities[id] = activity
            return id
        }

        func end(id: Int) {
            lock.lock()
            let activity = activities.removeValue(forKey: id)
            lock.unlock()
            if let activity {
                ProcessInfo.processInfo.endActivity(activity)
            }
        }
    }
    #endif
}
