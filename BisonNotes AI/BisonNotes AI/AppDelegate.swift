//
//  AppDelegate.swift
//  BisonNotes AI
//
//  Created by Claude Code
//  Phase 6: Notification Action Handling
//

import UIKit
import UserNotifications
import MetricKit

class AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate, MXMetricManagerSubscriber {

    // Reference to AudioRecorderViewModel for handling resume actions
    // This will be set by the main app
    static weak var recorderViewModel: AudioRecorderViewModel?

    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey : Any]? = nil) -> Bool {
        // Set notification delegate
        UNUserNotificationCenter.current().delegate = self

        // Subscribe to MetricKit crash/hang diagnostics
        MXMetricManager.shared.add(self)

        // Mark launch for crash detection
        AppLog.shared.markLaunch()

        NSLog("✅ AppDelegate initialized - notification delegate set")

        return true
    }

    // MARK: - MetricKit

    func didReceive(_ payloads: [MXDiagnosticPayload]) {
        // Apple delivers these on the next launch after a crash/hang (within 24h).
        // Persist the JSON so LogExporter can include it.
        guard !payloads.isEmpty else { return }
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let fileURL = dir.appendingPathComponent("metrickit_diagnostics.json")

        var allDiagnostics: [[String: Any]] = []
        // Load existing diagnostics if present
        if let existingData = try? Data(contentsOf: fileURL),
           let existing = try? JSONSerialization.jsonObject(with: existingData) as? [[String: Any]] {
            allDiagnostics = existing
        }

        for payload in payloads {
            if let json = try? JSONSerialization.jsonObject(with: payload.jsonRepresentation()) as? [String: Any] {
                allDiagnostics.append(json)
            }
        }

        // Keep only the last 5 diagnostic payloads
        if allDiagnostics.count > 5 {
            allDiagnostics = Array(allDiagnostics.suffix(5))
        }

        if let data = try? JSONSerialization.data(withJSONObject: allDiagnostics, options: .prettyPrinted) {
            try? data.write(to: fileURL, options: .atomic)
        }

        AppLog.shared.info("Received \(payloads.count) MetricKit diagnostic payload(s)", category: .general)
    }

    /// Clears the app icon badge. Call this when the app becomes active so the badge
    /// is removed only when the user actually opens the app (not on background launches).
    /// Uses UNUserNotificationCenter.setBadgeCount — the correct API for iOS 17+.
    func clearAppBadge(reason: String) {
        // Do NOT call removeAllDeliveredNotifications() here: actionable notifications
        // such as RESUME_RECORDING may still be waiting for a user response.
        Task {
            do {
                try await UNUserNotificationCenter.current().setBadgeCount(0)
                NSLog("✅ Cleared app icon badge on app \(reason)")
            } catch {
                NSLog("⚠️ setBadgeCount failed on \(reason): \(error)")
            }
        }
    }

    // NOTE: application(_:open:url:options:) is intentionally NOT implemented.
    // In scene-based SwiftUI apps, iOS delivers file URLs through the scene delegate,
    // which SwiftUI translates to .onOpenURL on the WindowGroup. Implementing the
    // AppDelegate method can intercept the URL and prevent .onOpenURL from firing.

    // MARK: - UNUserNotificationCenterDelegate

    /// Handle notification actions (Resume/Stop recording after call)
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {

        let categoryIdentifier = response.notification.request.content.categoryIdentifier
        let actionIdentifier = response.actionIdentifier

        AppLog.shared.general("Received notification action: category=\(categoryIdentifier), action=\(actionIdentifier)")

        if categoryIdentifier == "RESUME_RECORDING" {
            Task { @MainActor in
                guard let recorderVM = AppDelegate.recorderViewModel else {
                    AppLog.shared.general("AudioRecorderViewModel not available for notification action", level: .error)
                    completionHandler()
                    return
                }

                if actionIdentifier == "RESUME_ACTION" {
                    AppLog.shared.general("User chose to resume recording")

                    // Extract recording URL from notification user info
                    if let urlString = response.notification.request.content.userInfo["recordingURL"] as? String,
                       let url = URL(string: urlString) {
                        // Resume recording
                        recorderVM.recordingState = .recording
                        await recorderVM.resumeRecordingAfterInterruption(url: url)
                    } else {
                        AppLog.shared.general("No recording URL found in notification", level: .error)
                    }

                } else if actionIdentifier == "DISCARD_ACTION" {
                    AppLog.shared.general("User chose to stop recording")

                    // Stop recording gracefully
                    recorderVM.handleInterruptedRecording(reason: "User chose to stop after long call")
                }

                completionHandler()
            }
        } else {
            completionHandler()
        }
    }

    /// Handle notifications while app is in foreground
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        // Show notification even when app is in foreground
        if #available(iOS 14.0, *) {
            completionHandler([.banner, .sound, .badge])
        } else {
            completionHandler([.alert, .sound, .badge])
        }
    }
}
