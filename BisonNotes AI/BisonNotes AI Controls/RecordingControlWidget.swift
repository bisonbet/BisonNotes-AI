//
//  RecordingControlWidget.swift
//  BisonNotes AI Controls
//
//  Control Center widget for Action Button integration
//

import WidgetKit
import AppIntents
import SwiftUI

@available(iOS 18.0, *)
struct RecordingControlWidget: ControlWidget {
    static let kind: String = "com.bisonnotesai.controls.recording"

    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: Self.kind) {
            ControlWidgetButton(action: StartRecordingIntent()) {
                Label {
                    Text("Record")
                } icon: {
                    Image(systemName: "mic.fill")
                }
            }
        }
        .displayName("Start Recording")
        .description("Start recording with BisonNotes AI")
    }
}
