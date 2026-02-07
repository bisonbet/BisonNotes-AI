//
//  AppDelegate.swift
//  BisonNotes AI
//
//  Created by Claude Code
//  Phase 6: Notification Action Handling
//

import UIKit
import UserNotifications

class AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {

    // Reference to AudioRecorderViewModel for handling resume actions
    // This will be set by the main app
    static weak var recorderViewModel: AudioRecorderViewModel?

    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey : Any]? = nil) -> Bool {
        // Set notification delegate
        UNUserNotificationCenter.current().delegate = self
        NSLog("✅ AppDelegate initialized - notification delegate set")

        return true
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

        print("📱 Received notification action: category=\(categoryIdentifier), action=\(actionIdentifier)")

        if categoryIdentifier == "RESUME_RECORDING" {
            Task { @MainActor in
                guard let recorderVM = AppDelegate.recorderViewModel else {
                    print("❌ AudioRecorderViewModel not available")
                    completionHandler()
                    return
                }

                if actionIdentifier == "RESUME_ACTION" {
                    print("✅ User chose to resume recording")

                    // Extract recording URL from notification user info
                    if let urlString = response.notification.request.content.userInfo["recordingURL"] as? String,
                       let url = URL(string: urlString) {
                        // Resume recording
                        recorderVM.recordingState = .recording
                        await recorderVM.resumeRecordingAfterInterruption(url: url)
                    } else {
                        print("❌ No recording URL found in notification")
                    }

                } else if actionIdentifier == "DISCARD_ACTION" {
                    print("🛑 User chose to stop recording")

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
