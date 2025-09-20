//
//  StartRecordingIntent.swift
//  BisonNotes AI
//
//  Created for Action Button integration
//

import AppIntents
import Foundation

struct StartRecordingIntent: AppIntent {
    static var title: LocalizedStringResource = "Start Recording"
    static var description = IntentDescription("Start recording an audio note with BisonNotes AI")
    
    // Configure the intent to open the app
    static var openAppWhenRun: Bool = true
    
    // Make this intent available for shortcuts and action button
    static var isDiscoverable: Bool = true
    
    func perform() async throws -> some IntentResult {
        // Post a notification that will be handled by the app when it opens
        NotificationCenter.default.post(
            name: NSNotification.Name("StartRecordingFromIntent"),
            object: nil
        )
        
        return .result()
    }
}