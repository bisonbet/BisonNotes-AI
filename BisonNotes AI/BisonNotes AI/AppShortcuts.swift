//
//  AppShortcuts.swift
//  BisonNotes AI
//
//  Created for Action Button and Siri Shortcuts integration
//

import AppIntents

struct AppShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: StartRecordingIntent(),
            phrases: [
                "Start recording with \(.applicationName)",
                "Record audio note with \(.applicationName)",
                "Begin recording in \(.applicationName)",
                "Start new recording with \(.applicationName)"
            ],
            shortTitle: "Start Recording",
            systemImageName: "mic.fill"
        )
    }
}