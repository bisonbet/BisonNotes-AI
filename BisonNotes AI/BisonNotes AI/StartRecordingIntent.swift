//
//  StartRecordingIntent.swift
//  BisonNotes AI
//
//  Created for Action Button integration
//

import AppIntents
import Foundation

struct StartRecordingIntent: AppIntent {
    static let title: LocalizedStringResource = "Start Recording"
    static let description = IntentDescription("Start recording an audio note with BisonNotes AI")

    // Configure the intent to open the app
    static let openAppWhenRun = true

    // Make this intent available for shortcuts and action button
    static let isDiscoverable = true

    // Optimize for Control Center usage
    static let authenticationPolicy: IntentAuthenticationPolicy = .alwaysAllowed

    func perform() async throws -> some IntentResult {
        ActionButtonLaunchManager.requestRecordingStart()

        return .result()
    }
}
