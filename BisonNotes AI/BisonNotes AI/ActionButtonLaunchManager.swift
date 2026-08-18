//
//  ActionButtonLaunchManager.swift
//  BisonNotes AI
//
//  Created to coordinate Action Button launches between the App Intents
//  extension and the main application.
//

import Foundation

enum ActionButtonLaunchManager {
    static let appGroupIdentifier = "group.bisonnotesai.shared"
    static let darwinNotificationName = "com.bisonnotesai.startRecordingRequested"
    static let localNotificationName = Notification.Name("ActionButtonRecordingRequested")

    private static let shouldStartRecordingKey = "actionButtonShouldStartRecording"

    static func requestRecordingStart() {
#if !os(macOS)
        guard let defaults = UserDefaults(suiteName: appGroupIdentifier) else { return }
        requestRecordingStart(defaults: defaults, postNotification: postDarwinNotification)
#endif
    }

    static func requestRecordingStart(
        defaults: UserDefaults,
        postNotification: () -> Void
    ) {
        defaults.set(true, forKey: shouldStartRecordingKey)
        _ = defaults.synchronize()

        // AppIntent can activate the host app before perform() finishes. Notify
        // after persisting the request so an already-active app gets a second,
        // race-free opportunity to consume it.
        postNotification()
    }

    static func consumeRecordingRequest() -> Bool {
#if os(macOS)
        return false
#else
        guard let defaults = UserDefaults(suiteName: appGroupIdentifier) else {
            return false
        }
        return consumeRecordingRequest(defaults: defaults)
#endif
    }

    static func consumeRecordingRequest(defaults: UserDefaults) -> Bool {
        let shouldStartRecording = defaults.bool(forKey: shouldStartRecordingKey)

        if shouldStartRecording {
            defaults.set(false, forKey: shouldStartRecordingKey)
            _ = defaults.synchronize()
        }

        return shouldStartRecording
    }

    /// Covers the AppIntent ordering where the system activates the app before
    /// the widget process has persisted its recording request.
    static func startObservingRecordingRequests() {
#if os(macOS)
        return
#else
        let name = darwinNotificationName as CFString
        CFNotificationCenterAddObserver(
            CFNotificationCenterGetDarwinNotifyCenter(),
            nil,
            { _, _, _, _, _ in
                DispatchQueue.main.async {
                    NotificationCenter.default.post(
                        name: ActionButtonLaunchManager.localNotificationName,
                        object: nil
                    )
                }
            },
            name,
            nil,
            .deliverImmediately
        )
#endif
    }

    private static func postDarwinNotification() {
        let name = darwinNotificationName as CFString
        CFNotificationCenterPostNotification(
            CFNotificationCenterGetDarwinNotifyCenter(),
            CFNotificationName(name),
            nil,
            nil,
            true
        )
    }
}
