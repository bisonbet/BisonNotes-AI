//
//  RecordingControlWidget.swift
//  BisonNotes AI Controls
//
//  Control Center widget for Action Button integration
//

import WidgetKit
import AppIntents
import SwiftUI
import Foundation

// Simple test intent that doesn't depend on external code
#if os(iOS)

private enum ControlCenterBridge {
    static let appGroupIdentifier = "group.bisonnotesai.shared"
    private static let actionKey = "actionButtonShouldStartRecording"

    static func requestRecordingStart() {
        guard let defaults = UserDefaults(suiteName: appGroupIdentifier) else {
            print("⚠️ ControlCenterBridge: Missing shared defaults")
            return
        }
        defaults.set(true, forKey: actionKey)
        defaults.synchronize()
    }
}

@available(iOS 18.0, *)
struct SimpleRecordIntent: AppIntent {
    static var title: LocalizedStringResource = "Start Recording"
    static var description = IntentDescription("Start recording")
    static var openAppWhenRun: Bool = true
    static var authenticationPolicy: IntentAuthenticationPolicy = .alwaysAllowed

    func perform() async throws -> some IntentResult {
        print("🎤 Simple record intent triggered from Control Center")
        ControlCenterBridge.requestRecordingStart()
        return .result(dialog: IntentDialog("Starting recording with BisonNotes AI"))
    }
}
#endif

@available(iOS 18.0, *)
struct RecordingControlWidget: ControlWidget {
    static let kind: String = "com.bisonnotesai.controls.recording"

    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: Self.kind) {
            #if os(iOS)
            ControlWidgetButton(action: SimpleRecordIntent()) {
                Image(systemName: "mic.fill")
                    .foregroundStyle(.red)
            }
            #endif
        }
        .displayName("Start Recording")
        .description("Start recording with BisonNotes AI")
    }
}
