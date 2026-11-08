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

    // Deliberate: recording can start without unlocking the device, from the
    // Action Button, Control Center or Siri on the lock screen. Quick capture
    // is the point of those entry points, as with the system's own voice
    // recorder, and the intent itself only starts capture. The trade-off is
    // that someone holding the locked device can start the microphone, so this
    // was reviewed and kept on purpose (security review 2026-11-08, finding
    // #2); see "Deliberate security decisions" in CLAUDE.md before changing it.
    static let authenticationPolicy: IntentAuthenticationPolicy = .alwaysAllowed

    func perform() async throws -> some IntentResult {
        ActionButtonLaunchManager.requestRecordingStart()

        return .result()
    }
}
