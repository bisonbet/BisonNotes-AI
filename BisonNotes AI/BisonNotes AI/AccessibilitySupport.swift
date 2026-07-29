//
//  AccessibilitySupport.swift
//  BisonNotes AI
//

import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

enum AccessibilitySupport {
    static let seekStep: TimeInterval = 15

    struct RecordingRowContext {
        let date: String
        let duration: String
        let fileSize: String
        let isArchived: Bool
        let hasLocalAudio: Bool
        let isCloudSyncDisabled: Bool
        let hasTranscript: Bool
        let hasSummary: Bool
        let hasLocation: Bool
    }

    static func duration(_ interval: TimeInterval) -> String {
        let totalSeconds = Int(max(interval, 0).rounded())
        let hours = totalSeconds / 3_600
        let minutes = (totalSeconds % 3_600) / 60
        let seconds = totalSeconds % 60

        var components: [String] = []
        if hours > 0 {
            components.append("\(hours) \(hours == 1 ? "hour" : "hours")")
        }
        if minutes > 0 {
            components.append("\(minutes) \(minutes == 1 ? "minute" : "minutes")")
        }
        if seconds > 0 || components.isEmpty {
            components.append("\(seconds) \(seconds == 1 ? "second" : "seconds")")
        }
        return components.joined(separator: ", ")
    }

    static func playbackValue(currentTime: TimeInterval, totalDuration: TimeInterval) -> String {
        let current = min(max(currentTime, 0), max(totalDuration, 0))
        let remaining = max(totalDuration - current, 0)
        return "\(duration(current)) elapsed, \(duration(remaining)) remaining"
    }

    static func recordingTimerValue(recordingTime: TimeInterval, isPaused: Bool) -> String {
        let status = isPaused ? "Paused" : "Recording"
        return "\(status), \(duration(recordingTime))"
    }

    static func wordCountText(_ count: Int) -> String {
        "\(count) \(count == 1 ? "word" : "words")"
    }

    static func itemCount(_ count: Int, singular: String, plural: String? = nil) -> String {
        "\(count) \(count == 1 ? singular : (plural ?? singular + "s"))"
    }

    static func recordingRowLabel(name: String) -> String {
        "Recording, \(name)"
    }

    static func recordingRowValue(_ context: RecordingRowContext) -> String {
        var parts = [context.date, context.duration, context.fileSize]
        if context.isArchived {
            parts.append(context.hasLocalAudio ? "Archived, local audio available" : "Archived, audio offloaded")
        } else {
            parts.append(context.hasLocalAudio ? "Audio available" : "Audio unavailable")
        }
        parts.append(context.isCloudSyncDisabled ? "Kept on this device" : "Eligible for iCloud sync")
        parts.append(context.hasTranscript ? "Transcript available" : "No transcript")
        parts.append(context.hasSummary ? "Summary available" : "No summary")
        if context.hasLocation {
            parts.append("Location available")
        }
        return parts.joined(separator: ", ")
    }

    static func transcriptRowLabel(name: String, source: String) -> String {
        "\(source) transcript, \(name)"
    }

    static func transcriptRowValue(date: String, wordCount: Int?, hasSummary: Bool) -> String {
        var parts = [date]
        if let wordCount {
            parts.append(wordCountText(wordCount))
        }
        parts.append(hasSummary ? "Summary available" : "No summary")
        return parts.joined(separator: ", ")
    }

    static func summaryRowLabel(name: String) -> String {
        "Summary, \(name)"
    }

    static func summaryRowValue(date: String, taskCount: Int, reminderCount: Int, hasSummary: Bool) -> String {
        [
            date,
            hasSummary ? "Summary available" : "Summary not generated",
            itemCount(taskCount, singular: "task"),
            itemCount(reminderCount, singular: "reminder")
        ].joined(separator: ", ")
    }

    static func statusValue(isOn: Bool) -> String {
        isOn ? "On" : "Off"
    }

    static func announce(_ message: String) {
        #if canImport(UIKit)
        UIAccessibility.post(notification: .announcement, argument: message)
        #endif
    }
}

private struct AccessibilityCardModifier: ViewModifier {
    let label: String
    let value: String?
    let hint: String?

    func body(content: Content) -> some View {
        content
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(label)
            .accessibilityValue(value ?? "")
            .accessibilityHint(hint ?? "")
    }
}

extension View {
    func accessibilityCard(label: String, value: String? = nil, hint: String? = nil) -> some View {
        modifier(AccessibilityCardModifier(label: label, value: value, hint: hint))
    }

    func accessibilityModalProgress(label: String, value: String? = nil) -> some View {
        accessibilityElement(children: .combine)
            .accessibilityLabel(label)
            .accessibilityValue(value ?? "")
            .accessibilityAddTraits(.isModal)
    }
}
