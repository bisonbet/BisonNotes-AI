import SwiftUI

struct FluidAudioSettingsView: View {
    @AppStorage(FluidAudioModelInfo.SettingsKeys.enableFluidAudio) private var enableFluidAudio = false
    @AppStorage(FluidAudioModelInfo.SettingsKeys.selectedModelVersion) private var selectedModelVersion = FluidAudioModelInfo.ModelVersion.v3.rawValue

    @StateObject private var manager = FluidAudioManager.shared

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
            }

            Section("Model Status") {
                HStack {
                    Text("Status")
                    Spacer()
                    Text(manager.isModelReady ? "Ready" : "Not Downloaded")
                        .foregroundColor(manager.isModelReady ? .green : .secondary)
                }

                if !manager.currentStatus.isEmpty {
                    Text(manager.currentStatus)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                Button(manager.isDownloading ? "Downloading..." : "Download / Prepare Model") {
                    Task {
                        do {
                            try await manager.downloadAndPrepareModel()
                        } catch {
                            manager.currentStatus = "Failed: \(error.localizedDescription)"
                        }
                    }
                }
                .disabled(manager.isDownloading)
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
