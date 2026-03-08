import SwiftUI

struct FluidAudioSettingsView: View {
    @AppStorage(FluidAudioModelInfo.SettingsKeys.enableFluidAudio) private var enableFluidAudio = false
    @AppStorage(FluidAudioModelInfo.SettingsKeys.selectedModelVersion) private var selectedModelVersion = FluidAudioModelInfo.ModelVersion.v3.rawValue

    @ObservedObject private var manager = FluidAudioManager.shared

    var body: some View {
        Form {
            Section("Engine") {
                Toggle("Enable FluidAudio (Parakeet)", isOn: $enableFluidAudio)

                Picker("Model", selection: $selectedModelVersion) {
                    ForEach(FluidAudioModelInfo.ModelVersion.allCases, id: \.self) { version in
                        VStack(alignment: .leading) {
                            Text(version.displayName)
                            Text(version.description)
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        .tag(version.rawValue)
                    }
                }
                .onChange(of: selectedModelVersion) { _, _ in
                    manager.invalidateForVersionChange()
                }
            }

            if enableFluidAudio {
                Section("Model Status") {
                    HStack {
                        Text("Status")
                        Spacer()
                        Text(manager.isModelReady ? "Ready" : "Not Downloaded")
                            .foregroundColor(manager.isModelReady ? .green : .secondary)
                    }

                    if manager.isDownloading {
                        ProgressView(value: manager.downloadProgress)
                            .progressViewStyle(.linear)
                    }

                    if !manager.currentStatus.isEmpty {
                        Text(manager.currentStatus)
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }

                    if manager.isDownloading {
                        Button("Cancel Download", role: .destructive) {
                            manager.cancelDownload()
                        }
                    } else {
                        Button("Download / Prepare Model") {
                            Task {
                                do {
                                    try await manager.downloadAndPrepareModel()
                                } catch {
                                    manager.currentStatus = "Failed: \(error.localizedDescription)"
                                }
                            }
                        }
                    }

                    if manager.isModelReady {
                        Button("Delete Model", role: .destructive) {
                            manager.deleteModel()
                        }
                    }
                }
            }

            Section {
                Text("FluidAudio runs NVIDIA Parakeet models fully on-device using CoreML/ANE acceleration. This option keeps audio local and does not remove your existing transcription engines.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .navigationTitle("Parakeet Settings")
    }
}
