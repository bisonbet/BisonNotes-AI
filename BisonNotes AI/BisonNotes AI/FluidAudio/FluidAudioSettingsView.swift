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
    @State private var localSpeakerOperationID = UUID()

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
                        .frame(maxWidth: .infinity, alignment: .leading)

                        Picker("Parakeet Model", selection: $selectedModelVersion) {
                            ForEach(FluidAudioModelInfo.ModelVersion.allCases, id: \.self) { version in
                                Text(version.displayName)
                                    .tag(version.rawValue)
                            }
                        }
                        .labelsHidden()
                        .frame(minWidth: 180, idealWidth: 210, maxWidth: 240)
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

                nativeSettingsCard(
                    title: "Speaker Labels (After Recording)",
                    systemImage: "person.2.wave.2",
                    tint: .purple
                ) {
                    localSpeakerLabelsControls
                }
                .accessibilityIdentifier(BisonNotesAccessibilityID.localSpeakerLabelsSection)

                localPrivacyNotice
            }
            .frame(maxWidth: 680)
            .frame(maxWidth: .infinity, alignment: .top)
            .padding(28)
        }
        .background(Color(.systemGroupedBackground))
        .onAppear(perform: normalizeAndRefreshLocalSpeakerSettings)
        .onDisappear(perform: stopLocalSpeakerObservationTasks)
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
                .accessibilityAddTraits(.isHeader)
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

            Section {
                localSpeakerLabelsControls
            } header: {
                Text("Speaker Labels (After Recording)")
                    .accessibilityAddTraits(.isHeader)
                    .accessibilityIdentifier(BisonNotesAccessibilityID.localSpeakerLabelsSection)
            }

            Section {
                localPrivacyNotice
            }
        }
        .scrollContentBackground(.hidden)
        .background(Color(.systemGroupedBackground))
        .navigationTitle("On Device Transcription")
#if !os(macOS)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Done") {
                    dismiss()
                }
            }
        }
#endif
        .onAppear(perform: normalizeAndRefreshLocalSpeakerSettings)
        .onDisappear(perform: stopLocalSpeakerObservationTasks)
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

        ViewThatFits(in: .horizontal) {
            HStack(spacing: 10) {
                parakeetModelActions
            }

            VStack(alignment: .leading, spacing: 10) {
                parakeetModelActions
            }
        }
    }

    @ViewBuilder
    private var parakeetModelActions: some View {
        Group {
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
            .accessibilityLabel("Local Speaker Labels")
            .accessibilityHint(
                "Adds labels after completed Parakeet recordings, imports, and re-runs only. "
                    + "Does not affect Live Transcription."
            )
            .onChange(of: localSpeakerLabelsEnabled) { _, enabled in
                localSpeakerLabelsChanged(enabled)
            }

        Text(
            "Speaker labels apply only after completed Parakeet recordings, imports, and re-runs. "
                + "They do not affect Live Transcription. Audio stays local after the explicit one-time model download."
        )
            .font(.caption)
            .foregroundStyle(.secondary)
            .accessibilityIdentifier(BisonNotesAccessibilityID.localSpeakerLabelsHelp)

        if localSpeakerLabelsEnabled {
            VStack(alignment: .leading, spacing: 8) {
                Text("Speaker labeling method")
                    .font(.subheadline.weight(.semibold))
                    .accessibilityAddTraits(.isHeader)

                localMethodButton(.offlineVBx)
                localMethodButton(.experimentalLSEEND)
            }

            Text(localSpeakerMethodDescription)
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack {
                Text(localSpeakerStatusText)
                    .font(.subheadline.weight(.semibold))
                    .accessibilityIdentifier(BisonNotesAccessibilityID.localSpeakerModelStatus)
                    .accessibilityLabel("\(selectedLocalSpeakerMethod.displayName) speaker model status")
                    .accessibilityValue(localSpeakerStatusText)
                Spacer()
            }

            if let progress = selectedLocalSpeakerProgress?.fractionCompleted {
                ProgressView(value: progress)
                    .progressViewStyle(.linear)
                    .accessibilityIdentifier(BisonNotesAccessibilityID.localSpeakerModelProgress)
                    .accessibilityLabel(
                        "\(selectedLocalSpeakerMethod.displayName) speaker model download progress"
                    )
                    .accessibilityValue("\(Int(progress * 100)) percent")
            } else if selectedLocalSpeakerProgress != nil || localSpeakerStatus?.state == .preparing {
                ProgressView()
                    .accessibilityIdentifier(BisonNotesAccessibilityID.localSpeakerModelProgress)
                    .accessibilityLabel(
                        "Preparing \(selectedLocalSpeakerMethod.displayName) speaker model"
                    )
                    .accessibilityValue("In progress")
            }

            if let localSpeakerErrorText {
                Text(localSpeakerErrorText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier(BisonNotesAccessibilityID.localSpeakerModelError)
                    .accessibilityLabel("\(selectedLocalSpeakerMethod.displayName) speaker model error")
                    .accessibilityValue(localSpeakerErrorText)
                    .accessibilityHint(
                        "Try again. If the problem continues, delete and download this speaker model again."
                    )
            }

            ViewThatFits(in: .horizontal) {
                HStack(spacing: 10) {
                    localSpeakerActionButton
                }

                VStack(alignment: .leading, spacing: 10) {
                    localSpeakerActionButton
                }
            }
        }
    }

    @ViewBuilder
    private var localSpeakerActionButton: some View {
        if localSpeakerStatus?.state == .preparing {
            Button("Cancel Download", role: .destructive) {
                cancelLocalSpeakerModelPreparation()
            }
            .accessibilityIdentifier(BisonNotesAccessibilityID.localSpeakerCancelModelButton)
            .accessibilityLabel("Cancel Download")
            .accessibilityHint(
                "Cancels the \(selectedLocalSpeakerMethod.displayName) speaker model download."
            )
        } else if localSpeakerStatus?.isReady == true {
            Button("Delete Speaker Model", role: .destructive) {
                deleteLocalSpeakerModel()
            }
            .accessibilityIdentifier(BisonNotesAccessibilityID.localSpeakerDeleteModelButton)
            .accessibilityLabel("Delete Speaker Model")
            .accessibilityHint(
                "Deletes only the downloaded \(selectedLocalSpeakerMethod.displayName) speaker model."
            )
        } else {
            Button("Download Speaker Model") {
                prepareLocalSpeakerModel()
            }
            .accessibilityIdentifier(BisonNotesAccessibilityID.localSpeakerPrepareModelButton)
            .accessibilityLabel("Download Speaker Model")
            .accessibilityHint(
                "Explicitly downloads the selected \(selectedLocalSpeakerMethod.displayName) speaker model."
            )
        }
    }

    private func localMethodButton(_ method: LocalDiarizationMethod) -> some View {
        Button {
            setLocalSpeakerMethod(method.rawValue)
        } label: {
            HStack(alignment: .top, spacing: 12) {
                localMethodLabel(method)

                Spacer(minLength: 8)

                Image(
                    systemName: selectedLocalSpeakerMethod == method
                        ? "checkmark.circle.fill"
                        : "circle"
                )
                .foregroundStyle(
                    selectedLocalSpeakerMethod == method ? Color.accentColor : .secondary
                )
                .accessibilityHidden(true)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityIdentifier(
            method == .offlineVBx
                ? BisonNotesAccessibilityID.localSpeakerMethodOfflineVBx
                : BisonNotesAccessibilityID.localSpeakerMethodLSEEND
        )
        .accessibilityLabel(localSpeakerMethodAccessibilityLabel(method))
        .accessibilityValue(selectedLocalSpeakerMethod == method ? "Selected" : "Not selected")
        .accessibilityHint(
            "Selects \(method.displayName). Selection alone does not download a speaker model."
        )
    }

    private func localMethodLabel(_ method: LocalDiarizationMethod) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(method.displayName)
                .font(.body)
            localMethodMetadata(method)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func localMethodMetadata(_ method: LocalDiarizationMethod) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            localMethodBadge(method)
            localMethodSpeakerCount(method)
        }
    }

    private func localMethodBadge(_ method: LocalDiarizationMethod) -> some View {
        Text(method == .offlineVBx ? "Recommended" : "Experimental")
            .font(.subheadline.weight(.semibold))
            .fixedSize(horizontal: false, vertical: true)
    }

    private func localMethodSpeakerCount(_ method: LocalDiarizationMethod) -> some View {
        Text(
            method == .experimentalLSEEND
                ? "up to 10 speakers"
                : "speaker count estimated"
        )
        .font(.subheadline)
        .fixedSize(horizontal: false, vertical: true)
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

    private func localSpeakerMethodAccessibilityLabel(_ method: LocalDiarizationMethod) -> String {
        switch method {
        case .offlineVBx:
            return "Offline VBx, Recommended, speaker count estimated"
        case .experimentalLSEEND:
            return "LS-EEND, Experimental, up to 10 speakers"
        }
    }

    private var selectedLocalSpeakerProgress: LocalDiarizationProgress? {
        guard localSpeakerProgress?.method == selectedLocalSpeakerMethod else { return nil }
        return localSpeakerProgress
    }

    private var localSpeakerErrorText: String? {
        if let localSpeakerError {
            return localSpeakerError
        }
        guard let status = localSpeakerStatus, status.state == .failed else { return nil }
        return "\(status.method.displayName): Speaker model preparation failed."
    }

    private var localSpeakerStatusText: String {
        guard let status = localSpeakerStatus else {
            return "\(selectedLocalSpeakerMethod.displayName): Checking speaker model status..."
        }
        switch status.state {
        case .downloadRequired:
            return "\(status.method.displayName): Download Required"
        case .preparing:
            return "\(status.method.displayName): Preparing"
        case .ready:
            return "\(status.method.displayName): Ready"
        case .failed:
            return "\(status.method.displayName): Preparation Failed"
        case .cancelled:
            return "\(status.method.displayName): Download Cancelled"
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
        clearLocalSpeakerTransientState()
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
        invalidateLocalSpeakerOperation()
        localSpeakerStatus = nil
        Task { @MainActor in
            await cancelAndUnloadLocalSpeakerModel(previousMethod)
            guard localSpeakerLabelsEnabled,
                  selectedLocalSpeakerMethod.rawValue == normalized else { return }
            refreshLocalSpeakerModelStatus()
        }
    }

    private func localSpeakerLabelsChanged(_ enabled: Bool) {
        let method = selectedLocalSpeakerMethod
        invalidateLocalSpeakerOperation()
        if enabled {
            refreshLocalSpeakerModelStatus()
        } else {
            localSpeakerStatus = nil
            Task { @MainActor in
                await cancelAndUnloadLocalSpeakerModel(method)
            }
        }
    }

    private func refreshLocalSpeakerModelStatus() {
        localSpeakerStatusTask?.cancel()
        let method = selectedLocalSpeakerMethod
        localSpeakerStatusTask = Task { @MainActor in
            let status = await resolvedLocalSpeakerModelStatus(for: method)
            guard !Task.isCancelled,
                  localSpeakerLabelsEnabled,
                  selectedLocalSpeakerMethod == method else { return }
            localSpeakerStatus = status
            if status.state != .preparing {
                localSpeakerProgress = nil
            }
            if status.state != .failed {
                localSpeakerError = nil
            }
        }
    }

    private func prepareLocalSpeakerModel() {
        let method = selectedLocalSpeakerMethod
        invalidateLocalSpeakerOperation()
        let operationID = UUID()
        localSpeakerOperationID = operationID
        localSpeakerError = nil
        localSpeakerStatus = LocalDiarizationModelStatus(method: method, state: .preparing)
        localSpeakerProgress = LocalDiarizationProgress(method: method, phase: .preparing)

        if applyUITestSpeakerModelPreparation(for: method) {
            return
        }

        localSpeakerPreparationTask = Task { @MainActor in
            do {
                try await LocalDiarizationManager.shared.prepareModel(for: method) { progress in
                    Task { @MainActor in
                        guard localSpeakerOperationID == operationID,
                              localSpeakerLabelsEnabled,
                              selectedLocalSpeakerMethod == method else { return }
                        localSpeakerProgress = progress
                    }
                }
                guard localSpeakerOperationID == operationID,
                      localSpeakerLabelsEnabled,
                      selectedLocalSpeakerMethod == method else { return }
                localSpeakerProgress = nil
                localSpeakerError = nil
                refreshLocalSpeakerModelStatus()
            } catch is CancellationError {
                guard localSpeakerOperationID == operationID,
                      selectedLocalSpeakerMethod == method else { return }
                localSpeakerProgress = nil
                localSpeakerError = nil
                localSpeakerStatus = LocalDiarizationModelStatus(method: method, state: .cancelled)
            } catch {
                guard localSpeakerOperationID == operationID,
                      localSpeakerLabelsEnabled,
                      selectedLocalSpeakerMethod == method else { return }
                localSpeakerProgress = nil
                localSpeakerStatus = LocalDiarizationModelStatus(method: method, state: .failed)
                localSpeakerError = "\(method.displayName): Speaker model preparation failed."
            }
        }
    }

    private func cancelLocalSpeakerModelPreparation() {
        let method = selectedLocalSpeakerMethod
        invalidateLocalSpeakerOperation()
        localSpeakerStatus = LocalDiarizationModelStatus(method: method, state: .cancelled)
        Task { @MainActor in
            await cancelLocalSpeakerModelPreparationIfNeeded(method)
        }
    }

    private func deleteLocalSpeakerModel() {
        let method = selectedLocalSpeakerMethod
        invalidateLocalSpeakerOperation()
        if applyUITestSpeakerModelDeletion(for: method) {
            return
        }

        Task { @MainActor in
            do {
                try await LocalDiarizationManager.shared.deleteModel(for: method)
                guard localSpeakerLabelsEnabled,
                      selectedLocalSpeakerMethod == method else { return }
                localSpeakerProgress = nil
                localSpeakerError = nil
                localSpeakerStatus = LocalDiarizationModelStatus(
                    method: method,
                    state: .downloadRequired
                )
            } catch {
                guard localSpeakerLabelsEnabled,
                      selectedLocalSpeakerMethod == method else { return }
                localSpeakerProgress = nil
                localSpeakerStatus = LocalDiarizationModelStatus(method: method, state: .failed)
                localSpeakerError = "\(method.displayName): Speaker model deletion failed."
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

    private func stopLocalSpeakerObservationTasks() {
        localSpeakerStatusTask?.cancel()
    }

    private func clearLocalSpeakerTransientState() {
        localSpeakerProgress = nil
        localSpeakerError = nil
    }

    private func invalidateLocalSpeakerOperation() {
        localSpeakerStatusTask?.cancel()
        localSpeakerPreparationTask?.cancel()
        localSpeakerOperationID = UUID()
        clearLocalSpeakerTransientState()
    }

    private func resolvedLocalSpeakerModelStatus(
        for method: LocalDiarizationMethod
    ) async -> LocalDiarizationModelStatus {
        #if DEBUG
        if let status = BisonNotesUITestSupport.localSpeakerModelStatusOverride(for: method) {
            return status
        }
        #endif
        return await LocalDiarizationManager.shared.modelStatus(for: method)
    }

    @MainActor
    private func cancelAndUnloadLocalSpeakerModel(_ method: LocalDiarizationMethod) async {
        #if DEBUG
        guard !BisonNotesUITestSupport.usesLocalSpeakerModelStatusOverride else { return }
        #endif
        await LocalDiarizationManager.shared.cancelModelPreparation(for: method)
        await LocalDiarizationManager.shared.unloadModel(for: method)
    }

    private func cancelLocalSpeakerModelPreparationIfNeeded(
        _ method: LocalDiarizationMethod
    ) async {
        #if DEBUG
        guard !BisonNotesUITestSupport.usesLocalSpeakerModelStatusOverride else { return }
        #endif
        await LocalDiarizationManager.shared.cancelModelPreparation(for: method)
    }

    private func applyUITestSpeakerModelPreparation(
        for method: LocalDiarizationMethod
    ) -> Bool {
        #if DEBUG
        guard BisonNotesUITestSupport.usesLocalSpeakerModelStatusOverride else { return false }
        localSpeakerProgress = nil
        if BisonNotesUITestSupport.shouldFailLocalSpeakerModelPreparation {
            localSpeakerStatus = LocalDiarizationModelStatus(method: method, state: .failed)
            localSpeakerError = "\(method.displayName): Speaker model preparation failed."
        } else {
            localSpeakerStatus = LocalDiarizationModelStatus(method: method, state: .ready)
            localSpeakerError = nil
        }
        return true
        #else
        return false
        #endif
    }

    private func applyUITestSpeakerModelDeletion(
        for method: LocalDiarizationMethod
    ) -> Bool {
        #if DEBUG
        guard BisonNotesUITestSupport.usesLocalSpeakerModelStatusOverride else { return false }
        localSpeakerProgress = nil
        localSpeakerError = nil
        localSpeakerStatus = LocalDiarizationModelStatus(method: method, state: .downloadRequired)
        return true
        #else
        return false
        #endif
    }
}
