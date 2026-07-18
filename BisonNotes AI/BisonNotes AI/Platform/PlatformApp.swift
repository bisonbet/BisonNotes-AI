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
#endif

// MARK: - App-level services

enum PlatformApp {
    /// Open a URL in the default browser/handler. For use from managers;
    /// views should use @Environment(\.openURL).
    static func open(_ url: URL) {
        #if canImport(UIKit)
        UIApplication.shared.open(url)
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
    #endif
}

// MARK: - Background task assertions

/// UIKit background-task assertions ("finish this work after backgrounding").
/// On native macOS (Phase 2) these become no-ops or ProcessInfo activities —
/// macOS apps keep running in the background.
enum PlatformBackgroundTask {
    #if canImport(UIKit)
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
    #endif
}
