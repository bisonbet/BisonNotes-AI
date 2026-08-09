import SwiftUI

struct FluidAudioSettingsView: View {
    @AppStorage(FluidAudioModelInfo.SettingsKeys.enableFluidAudio) private var enableFluidAudio = false
    @AppStorage(FluidAudioModelInfo.SettingsKeys.selectedModelVersion)
    private var selectedModelVersion = FluidAudioModelInfo.ModelVersion.v2.rawValue
    @AppStorage(FluidAudioModelInfo.SettingsKeys.localSpeakerLabelsEnabled)
    private var localSpeakerLabelsEnabled = FluidAudioModelInfo.LocalSpeakerLabels.defaultEnabled
    @AppStorage(FluidAudioModelInfo.SettingsKeys.selectedLocalSpeakerLabelMethod)
    private var selectedLocalSpeakerMethodRaw = FluidAudioModelInfo.LocalSpeakerLabels.defaultMethodRawValue

    @ObservedObject private var manager = FluidAudioManager.shared
    @Environment(\.dismiss) private var dismiss
    @State private var localSpeakerStatus: LocalDiarizationModelStatus?
    @State private var localSpeakerProgress: LocalDiarizationProgress?
    @State private var localSpeakerError: String?
    @State private var localSpeakerStatusTask: Task<Void, Never>?
    @State private var localSpeakerPreparationTask: Task<Void, Never>?

    private var selectedLocalSpeakerMethod: LocalDiarizationMethod {
        let normalized = FluidAudioModelInfo.LocalSpeakerLabels.normalizedMethodRawValue(
            selectedLocalSpeakerMethodRaw
        )
        return LocalDiarizationMethod(rawValue: normalized) ?? .offlineVBx
    }

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

                nativeSettingsCard(title: "Engine", systemImage: "waveform", tint: .orange) {
                    Toggle(isOn: $enableFluidAudio) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text("Enable FluidAudio")
                                .fontWeight(.semibold)
                            Text("Uses Parakeet for private, on-device transcription.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .toggleStyle(.switch)

                    Divider()

                    HStack(alignment: .center, spacing: 20) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text("Parakeet Model")
                                .fontWeight(.semibold)
                            Text("Choose the Parakeet model used for transcription.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }

                        Spacer(minLength: 24)

                        Picker("Parakeet Model", selection: $selectedModelVersion) {
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
                    nativeSettingsCard(title: "Parakeet Model Status", systemImage: "shippingbox", tint: .blue) {
                        parakeetModelStatus
                    }
                }

                nativeSettingsCard(title: "Local Speaker Labels", systemImage: "person.2.wave.2", tint: .purple) {
                    localSpeakerLabelsControls
                }

                localPrivacyNotice
            }
            .frame(maxWidth: 680)
            .frame(maxWidth: .infinity, alignment: .top)
            .padding(28)
        }
        .background(Color(.systemGroupedBackground))
        .onAppear(perform: normalizeAndRefreshLocalSpeakerSettings)
        .onDisappear(perform: cancelLocalSpeakerTasks)
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

                Picker("Parakeet Model", selection: $selectedModelVersion) {
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
                Section("Parakeet Model Status") {
                    parakeetModelStatus
                }
            }

            Section("Local Speaker Labels") {
                localSpeakerLabelsControls
            }

            Section {
                localPrivacyNotice
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
        .onAppear(perform: normalizeAndRefreshLocalSpeakerSettings)
        .onDisappear(perform: cancelLocalSpeakerTasks)
    }

}

private extension FluidAudioSettingsView {
    @ViewBuilder
    private var parakeetModelStatus: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(manager.isModelReady ? "Ready to Transcribe" : "Parakeet Model Not Downloaded")
                    .fontWeight(.semibold)
                Text(manager.isModelReady
                     ? "The selected Parakeet model is available."
                     : "Download the Parakeet model before using on-device transcription.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Text(manager.isModelReady ? "Ready" : "Not Ready")
                .font(.caption.weight(.semibold))
                .accessibilityIdentifier(BisonNotesAccessibilityID.localSpeakerModelStatus + ".parakeet")
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
                Button("Cancel Parakeet Download", role: .destructive) {
                    manager.cancelDownload()
                }
            } else {
                Button("Download / Prepare Parakeet Model") {
                    prepareParakeetModel()
                }
                .disabled(manager.isModelReady)
            }

            if manager.isModelReady {
                Button("Delete Parakeet Model", role: .destructive) {
                    manager.deleteModel()
                }
            }
        }
    }

    @ViewBuilder
    private var localSpeakerLabelsControls: some View {
        Toggle("Local Speaker Labels", isOn: $localSpeakerLabelsEnabled)
            .accessibilityIdentifier(BisonNotesAccessibilityID.localSpeakerLabelsToggle)
            .accessibilityHint(
                "Applies after completed Parakeet recordings, imports, or re-runs. "
                    + "It does not affect Live Transcription."
            )
            .onChange(of: localSpeakerLabelsEnabled) { _, enabled in
                localSpeakerLabelsChanged(enabled)
            }

        Text(
            "Labels are applied after a completed Parakeet transcription. "
                + "Audio stays local after the one-time model download; Live Transcription is unchanged."
        )
            .font(.caption)
            .foregroundStyle(.secondary)
            .accessibilityIdentifier(BisonNotesAccessibilityID.localSpeakerLabelsHelp)

        if localSpeakerLabelsEnabled {
            Picker("Speaker labeling method", selection: Binding(
                get: { selectedLocalSpeakerMethod.rawValue },
                set: { setLocalSpeakerMethod($0) }
            )) {
                localMethodRow(.offlineVBx)
                    .tag(LocalDiarizationMethod.offlineVBx.rawValue)
                localMethodRow(.experimentalLSEEND)
                    .tag(LocalDiarizationMethod.experimentalLSEEND.rawValue)
            }
            .pickerStyle(.inline)
            .onChange(of: selectedLocalSpeakerMethod) { _, _ in
                refreshLocalSpeakerModelStatus()
            }

            Text(localSpeakerMethodDescription)
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack {
                Text(localSpeakerStatusText)
                    .font(.subheadline.weight(.semibold))
                    .accessibilityIdentifier(BisonNotesAccessibilityID.localSpeakerModelStatus)
                Spacer()
            }

            if let progress = localSpeakerProgress?.fractionCompleted {
                ProgressView(value: progress)
                    .progressViewStyle(.linear)
                    .accessibilityIdentifier(BisonNotesAccessibilityID.localSpeakerModelProgress)
                    .accessibilityValue("\(Int(progress * 100)) percent")
            } else if localSpeakerStatus?.state == .preparing {
                ProgressView()
                    .accessibilityIdentifier(BisonNotesAccessibilityID.localSpeakerModelProgress)
                    .accessibilityLabel("Preparing speaker model")
            }

            if let localSpeakerError {
                Text(localSpeakerError)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("Speaker model error: \(localSpeakerError)")
            }

            HStack(spacing: 10) {
                if localSpeakerStatus?.state == .preparing {
                    Button("Cancel Speaker Model Download", role: .destructive) {
                        cancelLocalSpeakerModelPreparation()
                    }
                    .accessibilityIdentifier(BisonNotesAccessibilityID.localSpeakerCancelModelButton)
                } else if localSpeakerStatus?.isReady == true {
                    Button("Delete Speaker Model", role: .destructive) {
                        deleteLocalSpeakerModel()
                    }
                    .accessibilityIdentifier(BisonNotesAccessibilityID.localSpeakerDeleteModelButton)
                } else {
                    Button("Download / Prepare Speaker Model") {
                        prepareLocalSpeakerModel()
                    }
                    .accessibilityIdentifier(BisonNotesAccessibilityID.localSpeakerPrepareModelButton)
                }
            }
        }
    }

    private func localMethodRow(_ method: LocalDiarizationMethod) -> some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(method.displayName)
                HStack(spacing: 6) {
                    if method == .offlineVBx {
                        Text("Recommended")
                            .font(.caption2.weight(.semibold))
                            .accessibilityIdentifier(BisonNotesAccessibilityID.localSpeakerRecommendedBadge)
                    } else {
                        Text("Experimental")
                            .font(.caption2.weight(.semibold))
                            .accessibilityIdentifier(BisonNotesAccessibilityID.localSpeakerExperimentalBadge)
                    }
                    Text(method == .experimentalLSEEND ? "Up to 10 speakers" : "Speaker count estimated")
                        .font(.caption2)
                }
            }
        }
        .accessibilityIdentifier(
            method == .offlineVBx
                ? BisonNotesAccessibilityID.localSpeakerMethodOfflineVBx
                : BisonNotesAccessibilityID.localSpeakerMethodLSEEND
        )
    }

    private var localSpeakerMethodDescription: String {
        switch selectedLocalSpeakerMethod {
        case .offlineVBx:
            return "Recommended for normal use. Offline VBx estimates the number of speakers "
                + "and does not impose a two- or three-speaker cap."
        case .experimentalLSEEND:
            return "Experimental DIHARD3 model for up to 10 speakers. It processes complete files "
                + "up to one hour and may over-segment or produce less-stable labels."
        }
    }

    private var localSpeakerStatusText: String {
        guard let status = localSpeakerStatus else { return "Checking speaker model status..." }
        switch status.state {
        case .downloadRequired:
            return "Download Required"
        case .preparing:
            return "Preparing \(status.method.displayName)..."
        case .ready:
            return "\(status.method.displayName) Ready"
        case .failed:
            return "Speaker Model Preparation Failed"
        case .cancelled:
            return "Speaker Model Preparation Cancelled"
        }
    }

    private var localPrivacyNotice: some View {
        Label {
            Text(
                "Audio remains on this device. Speaker labels run only after completed Parakeet work "
                    + "and do not change your other transcription engines."
            )
                .font(.caption)
                .foregroundStyle(.secondary)
        } icon: {
            Image(systemName: "lock.shield.fill")
                .foregroundStyle(.green)
        }
    }

    private func normalizeAndRefreshLocalSpeakerSettings() {
        let normalized = FluidAudioModelInfo.LocalSpeakerLabels.normalizedMethodRawValue(
            selectedLocalSpeakerMethodRaw
        )
        if selectedLocalSpeakerMethodRaw != normalized {
            selectedLocalSpeakerMethodRaw = normalized
        }
        if localSpeakerLabelsEnabled {
            refreshLocalSpeakerModelStatus()
        }
    }

    private func setLocalSpeakerMethod(_ rawValue: String) {
        let previousMethod = selectedLocalSpeakerMethod
        let normalized = FluidAudioModelInfo.LocalSpeakerLabels.normalizedMethodRawValue(rawValue)
        guard normalized != selectedLocalSpeakerMethodRaw else {
            refreshLocalSpeakerModelStatus()
            return
        }

        selectedLocalSpeakerMethodRaw = normalized
        localSpeakerPreparationTask?.cancel()
        localSpeakerProgress = nil
        localSpeakerError = nil
        localSpeakerStatus = nil
        Task { @MainActor in
            await LocalDiarizationManager.shared.cancelModelPreparation(for: previousMethod)
            await LocalDiarizationManager.shared.unloadModel(for: previousMethod)
            guard !Task.isCancelled else { return }
            refreshLocalSpeakerModelStatus()
        }
    }

    private func localSpeakerLabelsChanged(_ enabled: Bool) {
        let method = selectedLocalSpeakerMethod
        localSpeakerPreparationTask?.cancel()
        localSpeakerProgress = nil
        localSpeakerError = nil
        Task { @MainActor in
            await LocalDiarizationManager.shared.cancelModelPreparation(for: method)
            await LocalDiarizationManager.shared.unloadModel(for: method)
        }
        if enabled {
            refreshLocalSpeakerModelStatus()
        } else {
            localSpeakerStatus = nil
        }
    }

    private func refreshLocalSpeakerModelStatus() {
        localSpeakerStatusTask?.cancel()
        let method = selectedLocalSpeakerMethod
        localSpeakerStatusTask = Task { @MainActor in
            let status = await LocalDiarizationManager.shared.modelStatus(for: method)
            guard !Task.isCancelled else { return }
            localSpeakerStatus = status
        }
    }

    private func prepareLocalSpeakerModel() {
        localSpeakerPreparationTask?.cancel()
        let method = selectedLocalSpeakerMethod
        localSpeakerError = nil
        localSpeakerStatus = LocalDiarizationModelStatus(method: method, state: .preparing)
        localSpeakerProgress = LocalDiarizationProgress(method: method, phase: .preparing)
        localSpeakerPreparationTask = Task { @MainActor in
            do {
                try await LocalDiarizationManager.shared.prepareModel(for: method) { progress in
                    Task { @MainActor in
                        localSpeakerProgress = progress
                    }
                }
                refreshLocalSpeakerModelStatus()
            } catch is CancellationError {
                refreshLocalSpeakerModelStatus()
            } catch {
                localSpeakerError = error.localizedDescription
                refreshLocalSpeakerModelStatus()
            }
        }
    }

    private func cancelLocalSpeakerModelPreparation() {
        let method = selectedLocalSpeakerMethod
        localSpeakerPreparationTask?.cancel()
        Task { @MainActor in
            await LocalDiarizationManager.shared.cancelModelPreparation(for: method)
            refreshLocalSpeakerModelStatus()
        }
    }

    private func deleteLocalSpeakerModel() {
        let method = selectedLocalSpeakerMethod
        localSpeakerError = nil
        Task { @MainActor in
            do {
                try await LocalDiarizationManager.shared.deleteModel(for: method)
                refreshLocalSpeakerModelStatus()
            } catch {
                localSpeakerError = error.localizedDescription
            }
        }
    }

    private func prepareParakeetModel() {
        Task { @MainActor in
            do {
                try await manager.downloadAndPrepareModel()
            } catch {
                manager.currentStatus = "Failed: \(error.localizedDescription)"
            }
        }
    }

    private func cancelLocalSpeakerTasks() {
        localSpeakerStatusTask?.cancel()
        localSpeakerPreparationTask?.cancel()
        let method = selectedLocalSpeakerMethod
        Task {
            await LocalDiarizationManager.shared.cancelModelPreparation(for: method)
        }
    }
}
