import SwiftUI

struct FluidAudioSettingsView: View {
    @AppStorage(FluidAudioModelInfo.SettingsKeys.enableFluidAudio) private var enableFluidAudio = false
    @AppStorage(FluidAudioModelInfo.SettingsKeys.selectedModelVersion) private var selectedModelVersion = FluidAudioModelInfo.ModelVersion.v2.rawValue

    @ObservedObject private var manager = FluidAudioManager.shared
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        #if os(macOS)
        nativeMacContent
        #else
        standardContent
        #endif
    }

    #if os(macOS)
    private var nativeMacContent: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("On-Device Transcription")
                        .font(.largeTitle.bold())
                    Text("Run Parakeet locally using Apple silicon acceleration.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                nativeSettingsCard(
                    title: "Engine",
                    systemImage: "waveform",
                    tint: .orange
                ) {
                    Toggle(isOn: $enableFluidAudio) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text("Enable FluidAudio")
                                .fontWeight(.semibold)
                            Text("Uses NVIDIA Parakeet for private, on-device transcription.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .toggleStyle(.switch)

                    Divider()

                    HStack(alignment: .center, spacing: 20) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text("Model")
                                .fontWeight(.semibold)
                            Text("Choose the Parakeet model used for transcription.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }

                        Spacer(minLength: 24)

                        Picker("Model", selection: $selectedModelVersion) {
                            ForEach(FluidAudioModelInfo.ModelVersion.allCases, id: \.self) { version in
                                Text(version.displayName)
                                    .tag(version.rawValue)
                            }
                        }
                        .labelsHidden()
                        .frame(width: 240)
                        .onChange(of: selectedModelVersion) { _, _ in
                            manager.invalidateForVersionChange()
                        }
                    }
                }

                if enableFluidAudio {
                    nativeSettingsCard(
                        title: "Model Status",
                        systemImage: "shippingbox",
                        tint: .blue
                    ) {
                        HStack(spacing: 12) {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(manager.isModelReady ? "Ready to Transcribe" : "Model Not Downloaded")
                                    .fontWeight(.semibold)
                                Text(manager.isModelReady
                                     ? "The selected model is available on this Mac."
                                     : "Download the model before using on-device transcription.")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }

                            Spacer()

                            Label(
                                manager.isModelReady ? "Ready" : "Not Ready",
                                systemImage: manager.isModelReady
                                    ? "checkmark.circle.fill"
                                    : "arrow.down.circle"
                            )
                            .font(.caption.weight(.semibold))
                            .foregroundColor(manager.isModelReady ? .green : .secondary)
                        }

                        if manager.isDownloading {
                            ProgressView(value: manager.downloadProgress)
                                .progressViewStyle(.linear)
                        }

                        if !manager.currentStatus.isEmpty {
                            Text(manager.currentStatus)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }

                        HStack(spacing: 10) {
                            if manager.isDownloading {
                                Button("Cancel Download", role: .destructive) {
                                    manager.cancelDownload()
                                }
                            } else {
                                Button("Download / Prepare Model") {
                                    prepareModel()
                                }
                                .disabled(manager.isModelReady)
                            }

                            if manager.isModelReady {
                                Button("Delete Model", role: .destructive) {
                                    manager.deleteModel()
                                }
                            }
                        }
                    }
                }

                Label {
                    Text(
                        "Audio stays on this Mac. Enabling FluidAudio does not remove "
                            + "or reconfigure your other transcription engines."
                    )
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } icon: {
                    Image(systemName: "lock.shield.fill")
                        .foregroundStyle(.green)
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 12))
            }
            .frame(maxWidth: 680)
            .frame(maxWidth: .infinity, alignment: .top)
            .padding(28)
        }
        .background(Color(.systemGroupedBackground))
    }

    private func nativeSettingsCard<Content: View>(
        title: String,
        systemImage: String,
        tint: Color,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            Label(title, systemImage: systemImage)
                .font(.headline)
                .foregroundStyle(tint)

            content()
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 14))
    }
    #endif

    private var standardContent: some View {
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
                            prepareModel()
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
        .scrollContentBackground(.hidden)
        .background(Color(.systemGroupedBackground))
        .navigationTitle("On Device Transcription")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Done") {
                    dismiss()
                }
            }
        }
    }

    private func prepareModel() {
        Task {
            do {
                try await manager.downloadAndPrepareModel()
            } catch {
                manager.currentStatus = "Failed: \(error.localizedDescription)"
            }
        }
    }
}
