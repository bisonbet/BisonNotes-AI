//
//  OnDeviceAIDownloadMonitor.swift
//  BisonNotes AI
//
//  Global monitor for on-device AI model downloads
//

import Foundation
import Combine
import UserNotifications

@MainActor
class OnDeviceAIDownloadMonitor: ObservableObject {
    static let shared = OnDeviceAIDownloadMonitor()
    
    @Published var showingCompletionAlert = false
    @Published var completionMessage = ""
    
    private var cancellables = Set<AnyCancellable>()
    private var hasShownCompletion = false
    private let fluidAudioManager = FluidAudioManager.shared
    private let onDeviceLLMManager = OnDeviceLLMDownloadManager.shared

    private init() {
        setupMonitoring()
    }

    private func setupMonitoring() {
        // Monitor Parakeet (FluidAudio) download completion
        fluidAudioManager.$isModelReady
            .removeDuplicates()
            .dropFirst()
            .sink { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.checkBothDownloadsComplete()
                }
            }
            .store(in: &cancellables)

        // Monitor On-Device LLM download completion
        onDeviceLLMManager.$isModelReady
            .removeDuplicates()
            .dropFirst()
            .sink { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.checkBothDownloadsComplete()
                }
            }
            .store(in: &cancellables)
    }

    func checkBothDownloadsComplete() {
        guard !hasShownCompletion else { return }

        let parakeetReady = fluidAudioManager.isModelReady
        let onDeviceLLMReady = onDeviceLLMManager.isModelReady

        if parakeetReady && onDeviceLLMReady {
            hasShownCompletion = true
            completionMessage = "Both models have been downloaded successfully! You can now use on-device AI for transcription and summaries."
            showingCompletionAlert = true

            Task {
                await sendNotification(
                    title: "Models Ready",
                    body: "On-device AI models have finished downloading. You can now use on-device transcription and summaries."
                )
            }
        }
    }
    
    func reset() {
        hasShownCompletion = false
    }
    
    private func sendNotification(title: String, body: String) async {
        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()
        
        // Request permission if not yet determined
        if settings.authorizationStatus == .notDetermined {
            do {
                _ = try await center.requestAuthorization(options: [.alert, .badge, .sound])
            } catch {
                print("❌ Error requesting notification permission: \(error)")
                return
            }
        } else if settings.authorizationStatus != .authorized {
            print("📱 Notification not sent - permission denied")
            return
        }
        
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        
        let request = UNNotificationRequest(
            identifier: UUID().uuidString,
            content: content,
            trigger: nil // Immediate delivery
        )
        
        do {
            try await center.add(request)
            print("📱 Sent notification: \(title)")
        } catch {
            print("❌ Failed to send notification: \(error)")
        }
    }
}
