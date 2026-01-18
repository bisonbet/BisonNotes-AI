//
//  OnDeviceAIDownloadView.swift
//  BisonNotes AI
//
//  Download confirmation view for on-device AI setup - downloads happen in background
//

import SwiftUI

struct OnDeviceAIDownloadView: View {
    @Environment(\.dismiss) private var dismiss
    @Binding var isPresented: Bool
    let onCancel: () -> Void
    
    @ObservedObject private var whisperKitManager = WhisperKitManager.shared
    @ObservedObject private var onDeviceLLMManager = OnDeviceLLMDownloadManager.shared
    
    // Model info
    private let whisperKitModel = WhisperKitModelInfo.small
    private let onDeviceLLMModel = OnDeviceLLMModelInfo.granite4Micro
    
    private var totalDownloadSize: String {
        let totalBytes = whisperKitModel.downloadSizeBytes + onDeviceLLMModel.downloadSizeBytes
        let totalGB = Double(totalBytes) / 1_000_000_000.0
        return String(format: "%.2f GB", totalGB)
    }
    
    var body: some View {
        NavigationView {
            ScrollView {
                VStack(spacing: 24) {
                    confirmationView
                }
                .padding(.horizontal, 24)
                .padding(.top, 24)
                .padding(.bottom, 40) // Extra bottom padding for safe scrolling
            }
            .navigationTitle("Download Models")
            .navigationBarTitleDisplayMode(.inline)
        }
        .onAppear {
            // Set models BEFORE any other code accesses them to prevent migration warnings
            // Set WhisperKit to use small model
            UserDefaults.standard.set(whisperKitModel.id, forKey: WhisperKitModelInfo.SettingsKeys.selectedModelId)
            
            // Set On-Device LLM to use Granite Micro (recommended for 6GB+ devices)
            // Do this BEFORE any access to selectedModel to prevent migration loops
            UserDefaults.standard.set(onDeviceLLMModel.id, forKey: OnDeviceLLMModelInfo.SettingsKeys.selectedModelId)
            
            // Select the model in the manager directly to avoid accessing selectedModel property
            // This prevents the migration check from running
            onDeviceLLMManager.selectModel(onDeviceLLMModel)
            
            // Don't call refreshModelStatus() here - it accesses selectedModel which triggers migration
            // We'll check status only when starting downloads
        }
    }
    
    // MARK: - Confirmation View
    
    private var confirmationView: some View {
        VStack(spacing: 24) {
            VStack(spacing: 12) {
                Image(systemName: "arrow.down.circle.fill")
                    .font(.system(size: 60))
                    .foregroundColor(.blue)
                
                Text("Download Required Models")
                    .font(.title2)
                    .fontWeight(.bold)
                
                Text("To use on-device AI, we need to download two models to your device. Downloads will continue in the background.")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            
            VStack(spacing: 16) {
                // WhisperKit model info
                modelInfoCard(
                    name: "Fast Transcription",
                    description: "WhisperKit Small Model",
                    size: formatSize(whisperKitModel.downloadSizeBytes),
                    icon: "waveform"
                )
                
                // On-Device LLM model info
                modelInfoCard(
                    name: "Granite Micro",
                    description: "Recommended AI Summary Model",
                    size: formatSize(onDeviceLLMModel.downloadSizeBytes),
                    icon: "brain"
                )
            }
            
            VStack(spacing: 12) {
                HStack {
                    Image(systemName: "wifi")
                        .foregroundColor(.blue)
                    Text("Total Download Size: \(totalDownloadSize)")
                        .font(.headline)
                }
                
                Text("⚠️ Recommended: Use Wi-Fi for faster download")
                    .font(.caption)
                    .foregroundColor(.orange)
                    .padding()
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(
                        RoundedRectangle(cornerRadius: 8)
                            .fill(Color.orange.opacity(0.1))
                    )
                
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Image(systemName: "arrow.down.circle")
                            .foregroundColor(.blue)
                        Text("Downloads will continue in the background")
                            .font(.subheadline)
                            .fontWeight(.medium)
                    }
                    
                    Text("You can close this screen and use the app. You'll receive a notification when both models are ready.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding()
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color.blue.opacity(0.1))
                )
            }
            
            VStack(spacing: 12) {
                Button(action: startBackgroundDownloads) {
                    HStack {
                        Image(systemName: "arrow.down.circle.fill")
                        Text("Start Download")
                            .fontWeight(.semibold)
                    }
                    .frame(maxWidth: .infinity)
                    .padding()
                    .background(Color.blue)
                    .foregroundColor(.white)
                    .cornerRadius(12)
                }
                
                Button(action: {
                    onCancel()
                    isPresented = false
                }) {
                    Text("Cancel")
                        .frame(maxWidth: .infinity)
                        .padding()
                        .background(Color(.systemGray5))
                        .foregroundColor(.primary)
                        .cornerRadius(12)
                }
            }
            .padding(.top, 8)
        }
    }
    
    // MARK: - Helper Views
    
    private func modelInfoCard(name: String, description: String, size: String, icon: String) -> some View {
        HStack(spacing: 16) {
            Image(systemName: icon)
                .font(.title2)
                .foregroundColor(.blue)
                .frame(width: 40)
            
            VStack(alignment: .leading, spacing: 4) {
                Text(name)
                    .font(.headline)
                Text(description)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            
            Spacer()
            
            Text(size)
                .font(.subheadline)
                .fontWeight(.medium)
        }
        .padding()
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color(.systemGray6))
        )
    }
    
    // MARK: - Actions
    
    private func startBackgroundDownloads() {
        // Ensure models are set before starting downloads
        UserDefaults.standard.set(whisperKitModel.id, forKey: WhisperKitModelInfo.SettingsKeys.selectedModelId)
        UserDefaults.standard.set(onDeviceLLMModel.id, forKey: OnDeviceLLMModelInfo.SettingsKeys.selectedModelId)
        
        // Select the On-Device LLM model explicitly (this doesn't trigger migration)
        onDeviceLLMManager.selectModel(onDeviceLLMModel)
        
        // Check WhisperKit status without triggering migration
        // Just check if the model file exists directly
        let whisperKitReady = whisperKitManager.isModelReady
        
        // Check On-Device LLM status - use the manager's selectedModel which we just set
        let onDeviceLLMReady = onDeviceLLMManager.isModelReady || onDeviceLLMModel.isDownloaded
        
        // Start WhisperKit download if not already downloaded
        if !whisperKitReady {
            Task {
                do {
                    print("[OnDeviceAIDownload] Starting WhisperKit download...")
                    try await whisperKitManager.downloadModel()
                    print("[OnDeviceAIDownload] WhisperKit download completed")
                } catch {
                    print("[OnDeviceAIDownload] WhisperKit download error: \(error)")
                }
            }
        } else {
            print("[OnDeviceAIDownload] WhisperKit model already downloaded")
        }
        
        // Start On-Device LLM download if not already downloaded
        if !onDeviceLLMReady {
            print("[OnDeviceAIDownload] Starting On-Device LLM download...")
            onDeviceLLMManager.startDownload(for: onDeviceLLMModel)
        } else {
            print("[OnDeviceAIDownload] On-Device LLM model already downloaded")
        }
        
        // Close the view - downloads will continue in background
        isPresented = false
    }
    
    
    private func formatSize(_ bytes: Int64) -> String {
        let sizeInGB = Double(bytes) / 1_000_000_000.0
        if sizeInGB >= 1.0 {
            return String(format: "%.2f GB", sizeInGB)
        } else {
            let sizeInMB = Double(bytes) / 1_000_000.0
            return String(format: "%.0f MB", sizeInMB)
        }
    }
}
