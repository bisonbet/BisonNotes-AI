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

    @ObservedObject private var fluidAudioManager = FluidAudioManager.shared
    @ObservedObject private var mlxManager = MLXSwiftDownloadManager.shared

    // Model info
    private let parakeetVersion = FluidAudioModelInfo.selectedModelVersion
    private let mlxModel: MLXModelOption = MLXModelOption.available.first { $0.id == MLXSwiftSettingsKeys.defaultModelId }
        ?? MLXModelOption.available[0]

    private var totalDownloadSize: String {
        let totalBytes = parakeetVersion.downloadSizeBytes + mlxModel.downloadSizeBytes
        let totalGB = Double(totalBytes) / 1_000_000_000.0
        return String(format: "%.2f GB", totalGB)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 24) {
                    confirmationView
                }
                .padding(.horizontal, 24)
                .padding(.top, 24)
                .padding(.bottom, 40)
            }
            .navigationTitle("Download Models")
            .navigationBarTitleDisplayMode(.inline)
        }
        #if targetEnvironment(macCatalyst)
        .frame(minWidth: 520, minHeight: 640)
        #endif
        .onAppear {
            // Ensure MLX is configured to use the 4B model before checking download state.
            UserDefaults.standard.set(mlxModel.id, forKey: MLXSwiftSettingsKeys.modelId)
            mlxManager.refreshModelStatus()
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
                // Parakeet transcription model info
                modelInfoCard(
                    name: "Fast Transcription",
                    description: "Parakeet \(parakeetVersion.displayName)",
                    size: formatSize(parakeetVersion.downloadSizeBytes),
                    icon: "waveform"
                )

                // MLX on-device AI model info
                modelInfoCard(
                    name: mlxModel.displayName,
                    description: "On-Device AI Summary Model",
                    size: formatSize(mlxModel.downloadSizeBytes),
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
        // Ensure MLX is pointed at the 4B model before starting downloads.
        UserDefaults.standard.set(mlxModel.id, forKey: MLXSwiftSettingsKeys.modelId)
        mlxManager.refreshModelStatus()

        let parakeetReady = fluidAudioManager.isModelReady
        let mlxReady = mlxManager.isModelDownloaded

        if !parakeetReady {
            Task {
                do {
                    AppLog.shared.summarization("OnDeviceAIDownload: Starting Parakeet download...", level: .debug)
                    try await fluidAudioManager.downloadAndPrepareModel()
                    AppLog.shared.summarization("OnDeviceAIDownload: Parakeet download completed")
                } catch {
                    AppLog.shared.summarization("OnDeviceAIDownload: Parakeet download error: \(error)", level: .error)
                }
            }
        } else {
            AppLog.shared.summarization("OnDeviceAIDownload: Parakeet model already downloaded", level: .debug)
        }

        if !mlxReady {
            AppLog.shared.summarization("OnDeviceAIDownload: Starting MLX \(mlxModel.displayName) download...", level: .debug)
            mlxManager.startDownload()
        } else {
            AppLog.shared.summarization("OnDeviceAIDownload: MLX model already downloaded", level: .debug)
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
