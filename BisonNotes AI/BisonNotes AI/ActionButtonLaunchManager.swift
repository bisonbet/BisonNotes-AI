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

    private static let shouldStartRecordingKey = "actionButtonShouldStartRecording"
    static func requestRecordingStart() {
        guard let defaults = UserDefaults(suiteName: appGroupIdentifier) else { return }
        defaults.set(true, forKey: shouldStartRecordingKey)
        defaults.synchronize()
    }

    static func consumeRecordingRequest() -> Bool {
        guard let defaults = UserDefaults(suiteName: appGroupIdentifier) else { return false }
        let shouldStartRecording = defaults.bool(forKey: shouldStartRecordingKey)

        if shouldStartRecording {
            defaults.set(false, forKey: shouldStartRecordingKey)
        }

        return shouldStartRecording
    }
}
