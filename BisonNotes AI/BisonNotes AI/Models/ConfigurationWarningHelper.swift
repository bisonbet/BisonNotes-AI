//
//  ConfigurationWarningHelper.swift
//  Audio Journal
//
//  Helper for showing configuration warnings when engines are not configured
//

import Foundation
import SwiftUI

struct ConfigurationWarning {
    let title: String
    let message: String
    let type: ConfigurationWarningType
}

enum ConfigurationWarningType {
    case transcription
    case aiSummarization
}

class ConfigurationWarningHelper {

    /// Check if transcription engine is configured
    static func isTranscriptionEngineConfigured() -> Bool {
        let engine = UserDefaults.standard.string(forKey: "selectedTranscriptionEngine") ?? "Apple Intelligence (Limited)"
        return engine != "Not Configured"
    }

    /// Check if AI engine is configured
    static func isAIEngineConfigured() -> Bool {
        let engine = UserDefaults.standard.string(forKey: "SelectedAIEngine") ?? "Enhanced Apple Intelligence"
        return engine != "Not Configured"
    }

    /// Get configuration warning for transcription
    static func getTranscriptionWarning() -> ConfigurationWarning {
        return ConfigurationWarning(
            title: "Transcription Not Configured",
            message: "No transcription engine has been configured. Please go to Settings to configure a transcription engine.",
            type: .transcription
        )
    }

    /// Get configuration warning for AI summarization
    static func getAISummarizationWarning() -> ConfigurationWarning {
        return ConfigurationWarning(
            title: "AI Engine Not Configured",
            message: "No AI summarization engine has been configured. Please go to Settings to configure an AI engine.",
            type: .aiSummarization
        )
    }
}

/// SwiftUI View Modifier for configuration warnings
struct ConfigurationWarningModifier: ViewModifier {
    @Binding var showingTranscriptionWarning: Bool
    @Binding var showingAIWarning: Bool
    let onSettingsRequested: () -> Void

    func body(content: Content) -> some View {
        content
            .alert("Transcription Not Configured", isPresented: $showingTranscriptionWarning) {
                Button("Cancel", role: .cancel) { }
                Button("Settings") {
                    onSettingsRequested()
                }
            } message: {
                Text("No transcription engine has been configured. Please go to Settings to configure a transcription engine.")
            }
            .alert("AI Engine Not Configured", isPresented: $showingAIWarning) {
                Button("Cancel", role: .cancel) { }
                Button("Settings") {
                    onSettingsRequested()
                }
            } message: {
                Text("No AI summarization engine has been configured. Please go to Settings to configure an AI engine.")
            }
    }
}

extension View {
    func configurationWarnings(
        showingTranscriptionWarning: Binding<Bool>,
        showingAIWarning: Binding<Bool>,
        onSettingsRequested: @escaping () -> Void
    ) -> some View {
        modifier(ConfigurationWarningModifier(
            showingTranscriptionWarning: showingTranscriptionWarning,
            showingAIWarning: showingAIWarning,
            onSettingsRequested: onSettingsRequested
        ))
    }
}