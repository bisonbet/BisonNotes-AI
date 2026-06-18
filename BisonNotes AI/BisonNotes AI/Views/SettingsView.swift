//
//  SettingsView.swift
//  Audio Journal
//
//  Created by Tim Champ on 7/28/25.
//

import SwiftUI
import AVFoundation
import CoreLocation

struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject var recorderVM: AudioRecorderViewModel
    @EnvironmentObject var appCoordinator: AppDataCoordinator
    @StateObject private var regenerationManager: SummaryRegenerationManager
    @StateObject private var errorHandler = ErrorHandler()
    @ObservedObject private var iCloudManager = iCloudStorageManager.shared
    @StateObject private var importManager = FileImportManager()
    @State private var showingTranscriptionSettings = false
    @State private var showingAISettings = false
    @State private var showingClearSummariesAlert = false
    @State private var showingBackgroundProcessing = false
    @State private var showingDataMigration = false
    @State private var showingPreferences = false
    @State private var showingAcknowledgements = false
    @State private var showingTroubleshootingWarning = false
    @State private var logExportError: String?
    @State private var isPreparingLogs = false
    @State private var showingICloudComplianceNotice = false
    @State private var showingCloudReview = false

    @AppStorage("selectedTranscriptionEngine") private var selectedTranscriptionEngine: String = "On Device"
    @AppStorage("SelectedAIEngine") private var selectedAIEngine: String = "On-Device AI"
    @AppStorage("WatchIntegrationEnabled") private var watchIntegrationEnabled: Bool = true
    @AppStorage("WatchAutoSync") private var watchAutoSync: Bool = true
    @AppStorage("WatchBatteryAware") private var watchBatteryAware: Bool = true
    @AppStorage("iCloudBackupIncludeAudioFiles") private var iCloudBackupIncludeAudioFiles: Bool = false
    @AppStorage("iCloudBackupIncludeSettings") private var iCloudBackupIncludeSettings: Bool = true
    @AppStorage("iCloudBackupIncludeSensitiveSettings") private var iCloudBackupIncludeSensitiveSettings: Bool = false
    @AppStorage(OnDeviceLLMModelInfo.SettingsKeys.enableExperimentalModels) private var enableExperimentalModels = false
    @AppStorage(ComedyMode.SettingsKeys.enabled) private var comedyModeEnabled = false
    @AppStorage(ComedyMode.SettingsKeys.style) private var comedyModeStyle = "snarky"
    @State private var isRunningCloudBackupAction = false
    @State private var cloudBackupActionMessage = ""
    @State private var cloudBackupActionIsError = false

    init() {
        // Initialize regeneration manager with the coordinator's registry manager
        self._regenerationManager = StateObject(wrappedValue: SummaryRegenerationManager(
            summaryManager: SummaryManager.shared,
            transcriptManager: TranscriptManager.shared,
            appCoordinator: AppDataCoordinator()
        ))
    }

    var body: some View {
        NavigationStack {
            settingsContent
                .navigationTitle("Settings")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .navigationBarTrailing) {
                        Button("Done") { dismiss() }
                    }
                }
        }
        .alert("Regeneration Complete", isPresented: $regenerationManager.showingRegenerationAlert) {
            Button("OK") {
                regenerationManager.showingRegenerationAlert = false
            }
        } message: {
            Text("Regeneration completed successfully")
        }
        .alert("iCloud Sync Notice", isPresented: $showingICloudComplianceNotice) {
            Button("Cancel", role: .cancel) { }
            Button("Enable iCloud Sync") {
                iCloudManager.isEnabled = true
            }
        } message: {
            Text("BisonNotes AI and uploads to iCloud are not HIPAA-compliant. When iCloud Sync is enabled, eligible recordings, transcripts, summaries, and selected settings may be uploaded to your private iCloud account. To exclude an item from BisonNotes iCloud sync and backup, mark it Keep on This Device from its recording row or audio player.")
        }
        .sheet(isPresented: $showingCloudReview) {
            CloudReviewItemsView(includeAudioFiles: iCloudBackupIncludeAudioFiles)
                .environmentObject(appCoordinator)
        }
        .onAppear {
            refreshEngineStatuses()
            Task {
                await recorderVM.fetchInputs()
            }
        }
        .onChange(of: selectedAIEngine) { _, newEngine in
            SummaryManager.shared.setEngine(newEngine)
            AppLog.shared.log("SettingsView: Updated AI engine to '\(newEngine)'", level: .debug, category: .general)
        }
        .onChange(of: enableExperimentalModels) { _, newValue in
            // This toggle only gates legacy On-Device AI (llama) experimental
            // models and unlocks the legacy engine on <6GB devices. MLX is
            // unrelated and must not be touched here.
            OnDeviceLLMDownloadManager.shared.refreshModelStatus()

            guard !newValue else { return }

            // If the currently selected legacy model is no longer in the
            // available set (e.g. it was experimental-only), reset to the
            // first available legacy model.
            let currentModelId = UserDefaults.standard.string(forKey: OnDeviceLLMModelInfo.SettingsKeys.selectedModelId) ?? ""
            if !OnDeviceLLMModelInfo.availableModels.contains(where: { $0.id == currentModelId }),
               let firstAvailable = OnDeviceLLMModelInfo.availableModels.first {
                UserDefaults.standard.set(firstAvailable.id, forKey: OnDeviceLLMModelInfo.SettingsKeys.selectedModelId)
            }

            // If the user is on the legacy engine but the device no longer
            // has any legacy models available, fall through to Apple Native.
            let onDeviceHasModels = !OnDeviceLLMModelInfo.availableModels.isEmpty
            if selectedAIEngine == AIEngineType.onDeviceLLM.rawValue && !onDeviceHasModels {
                selectedAIEngine = AIEngineType.appleNative.rawValue
                SummaryManager.shared.setEngine(AIEngineType.appleNative.rawValue)
            }
        }
        .sheet(isPresented: $showingAISettings) {
            AISettingsView()
                .environmentObject(recorderVM)
        }
        .sheet(isPresented: $showingTranscriptionSettings) {
            TranscriptionSettingsView()
        }
        .sheet(isPresented: $showingBackgroundProcessing) {
            BackgroundProcessingView()
        }
        .sheet(isPresented: $showingDataMigration) {
            DataMigrationView()
                .environmentObject(appCoordinator)
        }
        .sheet(isPresented: $showingPreferences) {
            PreferencesView()
        }
        .sheet(isPresented: $showingAcknowledgements) {
            AcknowledgementsView()
        }
        .overlay {
            if isPreparingLogs {
                ZStack {
                    Color.black.opacity(0.25)
                        .ignoresSafeArea()

                    VStack(spacing: 12) {
                        ProgressView()
                            .progressViewStyle(.circular)
                        Text("Preparing logs...")
                            .font(.headline)
                            .foregroundColor(.primary)
                    }
                    .padding(.horizontal, 28)
                    .padding(.vertical, 20)
                    .background(
                        RoundedRectangle(cornerRadius: 14)
                            .fill(Color(.systemBackground))
                            .shadow(color: Color.black.opacity(0.15), radius: 10, x: 0, y: 2)
                    )
                }
                .transition(.opacity)
            }
        }
    }

    @ViewBuilder
    private var settingsContent: some View {
        modernSettingsScroll
    }

    private var modernSettingsScroll: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                modernHeader
                modernConfigurationSection
                modernRecordingSection
                moderniCloudSection
                modernBehaviorSection
                modernMaintenanceSection
            }
            .padding(.horizontal, 20)
            .padding(.top, 18)
            .padding(.bottom, 36)
            .frame(maxWidth: 700)
            .frame(maxWidth: .infinity)
        }
        .scrollIndicators(.hidden)
        .background(Color(.systemGroupedBackground))
    }

    private var modernHeader: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Additional Settings")
                .font(.largeTitle.weight(.bold))
                .foregroundColor(.primary)

            Text("Configure processing, privacy, sync, and diagnostics.")
                .font(.subheadline)
                .foregroundColor(.secondary)
        }
    }

    private var modernConfigurationSection: some View {
        ModernSettingsCard(title: "Configuration", systemImage: "slider.horizontal.3", tint: .accentColor) {
            ModernSettingsNavigationRow(
                title: "Display Preferences",
                subtitle: "Time format and display options",
                systemImage: "clock",
                tint: .indigo,
                action: { showingPreferences = true }
            )

            ModernSettingsNavigationRow(
                title: "AI Engines",
                subtitle: selectedAIEngine,
                systemImage: "sparkles",
                tint: .blue,
                trailing: {
                    ModernStatusPill(text: "Available", tint: .green)
                },
                action: { showingAISettings = true }
            )

            ModernSettingsNavigationRow(
                title: "Transcription",
                subtitle: TranscriptionEngine(rawValue: selectedTranscriptionEngine)?.rawValue ?? "On Device",
                systemImage: "text.bubble",
                tint: .orange,
                action: { showingTranscriptionSettings = true }
            )
        }
    }

    private var modernRecordingSection: some View {
        ModernSettingsCard(title: "Recording", systemImage: "mic", tint: .green) {
            #if targetEnvironment(macCatalyst)
            ModernInlineStatus(
                title: "Using Mac system microphone",
                subtitle: "BisonNotes uses the current macOS Sound input. Change it in System Settings if needed.",
                systemImage: "mic.fill",
                tint: .green
            )
            #else
            if recorderVM.availableInputs.isEmpty {
                ModernInlineStatus(
                    title: "No microphones found",
                    subtitle: "Pull to refresh or reconnect your input device.",
                    systemImage: "exclamationmark.triangle",
                    tint: .orange
                )
            } else {
                ForEach(recorderVM.availableInputs, id: \.uid) { input in
                    Button {
                        recorderVM.selectedInput = input
                        recorderVM.setPreferredInput()
                    } label: {
                        ModernSelectableRow(
                            title: input.portName,
                            subtitle: input.portType.rawValue,
                            systemImage: "mic.fill",
                            tint: .green,
                            isSelected: recorderVM.selectedInput?.uid == input.uid
                        )
                    }
                    .buttonStyle(.plain)
                }
            }

            Button {
                Task { await recorderVM.fetchInputs() }
            } label: {
                Label("Refresh Microphones", systemImage: "arrow.clockwise")
                    .font(.caption.weight(.semibold))
            }
            .buttonStyle(.bordered)

            Divider()
            #endif

            Toggle(isOn: Binding(
                get: { recorderVM.isLocationTrackingEnabled },
                set: { recorderVM.toggleLocationTracking($0) }
            )) {
                ModernSettingsLabel(
                    title: "Location Services",
                    subtitle: "Capture location data with recordings",
                    systemImage: "location.fill",
                    tint: .blue
                )
            }

            if recorderVM.isLocationTrackingEnabled {
                ModernInlineStatus(
                    title: locationStatusText,
                    subtitle: nil,
                    systemImage: locationStatusIcon,
                    tint: locationStatusColor
                )
            }
        }
    }

    private var moderniCloudSection: some View {
        ModernSettingsCard(
            title: "iCloud Sync",
            systemImage: "icloud",
            tint: .blue,
            trailing: {
                ModernStatusPill(text: iCloudManager.isEnabled ? "Enabled" : "Disabled", tint: iCloudManager.isEnabled ? .green : .secondary)
            }
        ) {
            Toggle("Enable iCloud Sync", isOn: iCloudSyncToggleBinding)

            if iCloudManager.isEnabled {
                Toggle("Include audio files in backup", isOn: $iCloudBackupIncludeAudioFiles)
                Toggle("Include app settings", isOn: $iCloudBackupIncludeSettings)
                Toggle("Include sensitive settings", isOn: $iCloudBackupIncludeSensitiveSettings)
                    .disabled(!iCloudBackupIncludeSettings)

                Text("API keys and AWS credentials stay in Keychain and are never included in iCloud settings backups. Leave sensitive settings off unless you explicitly want eligible future sensitive preferences copied to iCloud.")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                if iCloudManager.isAutomaticReconcileRunning {
                    ModernInlineStatus(
                        title: "Syncing with iCloud...",
                        subtitle: "Applying eligible changes and cleanup across devices",
                        systemImage: "arrow.triangle.2.circlepath",
                        tint: .blue,
                        showsProgress: true
                    )
                } else if let message = iCloudManager.lastMaintenanceMessage {
                    Text(message)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                HStack(spacing: 10) {
                    Button {
                        Task { await backupAllDataToiCloud() }
                    } label: {
                        Label("Backup", systemImage: "icloud.and.arrow.up")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .disabled(isRunningCloudBackupAction)

                    Button {
                        Task { await restoreAllDataFromiCloud() }
                    } label: {
                        Label("Restore", systemImage: "arrow.down.doc")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .tint(.green)
                    .disabled(isRunningCloudBackupAction)
                }

                Button {
                    showingCloudReview = true
                } label: {
                    Label("Review iCloud Items", systemImage: "tray.full")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .disabled(isRunningCloudBackupAction)

                if isRunningCloudBackupAction {
                    ModernInlineStatus(
                        title: "Working...",
                        subtitle: nil,
                        systemImage: "arrow.triangle.2.circlepath",
                        tint: .secondary,
                        showsProgress: true
                    )
                }

                if !cloudBackupActionMessage.isEmpty {
                    Text(cloudBackupActionMessage)
                        .font(.caption)
                        .foregroundColor(cloudBackupActionIsError ? .red : .secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } else {
                Button {
                    checkForiCloudData()
                } label: {
                    Label("Check for iCloud Data", systemImage: "icloud.and.arrow.down")
                }
                .buttonStyle(.bordered)
            }

            if !iCloudManager.pendingConflicts.isEmpty {
                ForEach(iCloudManager.pendingConflicts, id: \.summaryId) { conflict in
                    VStack(alignment: .leading, spacing: 8) {
                        Text(conflict.localSummary.recordingName)
                            .font(.caption.weight(.semibold))
                        Text("Modified on different devices")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                        HStack {
                            Button("Use Local") {
                                Task { try? await iCloudManager.resolveConflict(conflict, useLocal: true) }
                            }
                            .buttonStyle(.bordered)
                            Button("Use Cloud") {
                                Task { try? await iCloudManager.resolveConflict(conflict, useLocal: false) }
                            }
                            .buttonStyle(.bordered)
                            .tint(.green)
                        }
                    }
                    .padding(12)
                    .background(Color(.tertiarySystemGroupedBackground))
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                }
            }

            if let error = iCloudManager.lastError {
                Text("Error: \(error)")
                    .font(.caption)
                    .foregroundColor(.red)
            }
        }
    }

    private var modernBehaviorSection: some View {
        ModernSettingsCard(title: "App Behavior", systemImage: "wand.and.stars", tint: .purple) {
            Toggle("Comedy Mode", isOn: $comedyModeEnabled)

            if comedyModeEnabled {
                Picker("Style", selection: $comedyModeStyle) {
                    Text("Snarky - dry wit & sarcasm").tag("snarky")
                    Text("Funny - goofy & absurd").tag("funny")
                }
                .pickerStyle(.segmented)
            }

            Text("Make AI summaries entertaining with a comedic twist. All information is preserved.")
                .font(.caption)
                .foregroundColor(.secondary)

            Divider()

            Toggle("Experimental features", isOn: $enableExperimentalModels)
            Text("Exposes experimental on-device models. Experimental models are less reliable and may produce empty summaries.")
                .font(.caption)
                .foregroundColor(.secondary)
        }
    }

    private var modernMaintenanceSection: some View {
        ModernSettingsCard(title: "Maintenance", systemImage: "wrench.and.screwdriver", tint: .gray) {
            HStack {
                ModernSettingsLabel(
                    title: "Total Recordings Storage",
                    subtitle: "Space used by audio recordings",
                    systemImage: "externaldrive",
                    tint: .teal
                )
                Spacer()
                Text(totalRecordingsStorageString)
                    .font(.subheadline.weight(.semibold))
                    .foregroundColor(.secondary)
            }

            ModernSettingsNavigationRow(
                title: "Background Processing",
                subtitle: "Manage transcription and summarization jobs",
                systemImage: "gearshape.2",
                tint: .blue,
                action: { showingBackgroundProcessing = true }
            )

            Button {
                exportDiagnosticLogs()
            } label: {
                HStack(spacing: 14) {
                    ModernIcon(systemName: "envelope", tint: .orange)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Export Diagnostic Logs")
                            .font(.subheadline.weight(.semibold))
                            .foregroundColor(.primary)
                        Text("Email logs to developer for troubleshooting")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    Spacer()
                    if isPreparingLogs {
                        ProgressView().scaleEffect(0.8)
                    }
                }
            }
            .buttonStyle(.plain)
            .disabled(isPreparingLogs)

            if let logExportError {
                Text("Error: \(logExportError)")
                    .font(.caption)
                    .foregroundColor(.red)
            }

            ModernSettingsNavigationRow(
                title: "Acknowledgements",
                subtitle: "Open-source projects and licenses",
                systemImage: "hand.raised.fill",
                tint: .indigo,
                action: { showingAcknowledgements = true }
            )

            Button(role: .destructive) {
                showingTroubleshootingWarning = true
            } label: {
                Label("Advanced Troubleshooting", systemImage: "wrench.and.screwdriver")
                    .font(.subheadline.weight(.semibold))
            }
            .alert("Warning", isPresented: $showingTroubleshootingWarning) {
                Button("Cancel", role: .cancel) { }
                Button("OK") {
                    showingDataMigration = true
                }
            } message: {
                Text("These tools can delete data. Use with caution.")
            }
        }
    }

    private var preferencesSection: some View {
        Section("Preferences") {
            Button {
                showingPreferences = true
            } label: {
                HStack {
                    Image(systemName: "slider.horizontal.3")
                        .foregroundColor(.indigo)
                        .frame(width: 28)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Display Preferences")
                            .foregroundColor(.primary)
                        Text("Time format and display options")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
    }

    private var microphoneSection: some View {
        Section {
            #if targetEnvironment(macCatalyst)
            HStack {
                Image(systemName: "mic.fill")
                    .foregroundColor(.green)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Using Mac system microphone")
                    Text("Change the input device in macOS System Settings.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            #else
            if recorderVM.availableInputs.isEmpty {
                HStack {
                    Image(systemName: "exclamationmark.triangle")
                        .foregroundColor(.orange)
                    Text("No microphones found.")
                        .foregroundColor(.secondary)
                }
            } else {
                ForEach(recorderVM.availableInputs, id: \.uid) { input in
                    Button {
                        recorderVM.selectedInput = input
                        recorderVM.setPreferredInput()
                    } label: {
                        HStack {
                            Image(systemName: recorderVM.selectedInput?.uid == input.uid ? "largecircle.fill.circle" : "circle")
                                .foregroundColor(recorderVM.selectedInput?.uid == input.uid ? .blue : .gray)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(input.portName)
                                    .foregroundColor(.primary)
                                Text(input.portType.rawValue)
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                            Spacer()
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            #endif
        } header: {
            HStack {
                Text("Microphone Selection")
                Spacer()
                #if !targetEnvironment(macCatalyst)
                Button {
                    Task { await recorderVM.fetchInputs() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                #endif
            }
        }
    }


    private var aiEngineSection: some View {
        Section("AI Processing") {
            HStack {
                Text("Current Engine")
                Spacer()
                Text(selectedAIEngine)
                    .foregroundColor(.secondary)
            }
            HStack {
                Text("Status")
                Spacer()
                HStack(spacing: 4) {
                    Circle()
                        .fill(.green)
                        .frame(width: 8, height: 8)
                    Text("Available")
                        .foregroundColor(.secondary)
                }
            }
            Button {
                showingAISettings = true
            } label: {
                HStack {
                    Text("Configure AI Engines")
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
    }

    private var transcriptionSection: some View {
        Section("Transcription Engine") {
            HStack {
                Text("Current Engine")
                Spacer()
                Text(TranscriptionEngine(rawValue: selectedTranscriptionEngine)?.rawValue ?? "On Device")
                    .foregroundColor(.secondary)
            }
            Button {
                showingTranscriptionSettings = true
            } label: {
                HStack {
                    Text("Configure Transcription")
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
    }



    private var locationSection: some View {
        Section {
            Toggle("Location Services", isOn: Binding(
                get: { recorderVM.isLocationTrackingEnabled },
                set: { recorderVM.toggleLocationTracking($0) }
            ))
            if recorderVM.isLocationTrackingEnabled {
                HStack {
                    Image(systemName: locationStatusIcon)
                        .foregroundColor(locationStatusColor)
                    Text(locationStatusText)
                        .font(.caption)
                        .foregroundColor(locationStatusColor)
                }
            }
        } footer: {
            Text("Capture location data with recordings")
        }
    }

    private var iCloudSyncSection: some View {
        Section {
            Toggle("Enable iCloud Sync", isOn: iCloudSyncToggleBinding)

            if iCloudManager.isEnabled {
                Toggle("Include audio files in backup", isOn: $iCloudBackupIncludeAudioFiles)
                Toggle("Include app settings", isOn: $iCloudBackupIncludeSettings)
                Toggle("Include sensitive settings", isOn: $iCloudBackupIncludeSensitiveSettings)
                    .disabled(!iCloudBackupIncludeSettings)
                Text("API keys and AWS credentials stay in Keychain and are never included in iCloud settings backups. Leave sensitive settings off unless you explicitly want eligible future sensitive preferences copied to iCloud.")
                    .font(.caption)
                    .foregroundColor(.secondary)

                if iCloudManager.isAutomaticReconcileRunning {
                    HStack {
                        ProgressView()
                            .progressViewStyle(.circular)
                            .scaleEffect(0.8)
                        Text("Syncing with iCloud...")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                } else if let message = iCloudManager.lastMaintenanceMessage {
                    Text(message)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                Button {
                    Task { await backupAllDataToiCloud() }
                } label: {
                    Label("Backup Now", systemImage: "icloud.and.arrow.up")
                }
                .disabled(isRunningCloudBackupAction)

                Button {
                    Task { await restoreAllDataFromiCloud() }
                } label: {
                    Label("Restore From iCloud", systemImage: "arrow.down.doc")
                        .foregroundColor(.green)
                }
                .disabled(isRunningCloudBackupAction)

                Button {
                    showingCloudReview = true
                } label: {
                    Label("Review iCloud Items", systemImage: "tray.full")
                }
                .disabled(isRunningCloudBackupAction)

                if isRunningCloudBackupAction {
                    HStack {
                        ProgressView()
                            .progressViewStyle(.circular)
                            .scaleEffect(0.8)
                        Text("Working…")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }

                if !cloudBackupActionMessage.isEmpty {
                    Text(cloudBackupActionMessage)
                        .font(.caption)
                        .foregroundColor(cloudBackupActionIsError ? .red : .secondary)
                }
            }

            if !iCloudManager.pendingConflicts.isEmpty {
                ForEach(iCloudManager.pendingConflicts, id: \.summaryId) { conflict in
                    VStack(alignment: .leading, spacing: 6) {
                        Text(conflict.localSummary.recordingName)
                            .font(.caption)
                        Text("Modified on different devices")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                        HStack {
                            Button("Use Local") {
                                Task { try? await iCloudManager.resolveConflict(conflict, useLocal: true) }
                            }
                            .buttonStyle(.bordered)
                            Button("Use Cloud") {
                                Task { try? await iCloudManager.resolveConflict(conflict, useLocal: false) }
                            }
                            .buttonStyle(.bordered)
                            .tint(.green)
                        }
                    }
                }
            }

            if let error = iCloudManager.lastError {
                Text("Error: \(error)")
                    .font(.caption)
                    .foregroundColor(.red)
            }

            if !iCloudManager.isEnabled {
                Button {
                    Task {
                        do {
                            let cloudSummaries = try await iCloudManager.fetchSummariesFromiCloud(forRecovery: true)

                            let localSummaries = appCoordinator.coreDataManager.getAllSummaries()
                            let localSummaryIds = Set(localSummaries.compactMap { $0.id })
                            let cloudOnlySummaries = cloudSummaries.filter { !localSummaryIds.contains($0.id) }

                            if !cloudOnlySummaries.isEmpty {
                                await MainActor.run {
                                    let alert = UIAlertController(
                                        title: "iCloud Data Found",
                                        message: "We found \(cloudOnlySummaries.count) summaries in your iCloud that aren't on this device. Would you like to download them?",
                                        preferredStyle: .alert
                                    )
                                    alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
                                    alert.addAction(UIAlertAction(title: "Download", style: .default) { _ in
                                        Task {
                                            do {
                                                let count = try await iCloudManager.downloadSummariesFromCloud(appCoordinator: appCoordinator, forRecovery: true)
                                                AppLog.shared.log("Downloaded \(count) summaries from iCloud", category: .general)
                                            } catch {
                                                AppLog.shared.log("Failed to download summaries: \(error)", level: .error, category: .general)
                                            }
                                        }
                                    })
                                    if let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
                                       let rootViewController = windowScene.windows.first?.rootViewController {
                                        rootViewController.present(alert, animated: true)
                                    }
                                }
                            } else {
                                await MainActor.run {
                                    let alert = UIAlertController(
                                        title: "No iCloud Data",
                                        message: "No summaries were found in your iCloud account.",
                                        preferredStyle: .alert
                                    )
                                    alert.addAction(UIAlertAction(title: "OK", style: .default))
                                    if let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
                                       let rootViewController = windowScene.windows.first?.rootViewController {
                                        rootViewController.present(alert, animated: true)
                                    }
                                }
                            }
                        } catch {
                            AppLog.shared.log("Failed to check for iCloud data: \(error)", level: .error, category: .general)
                            await MainActor.run {
                                let alert = UIAlertController(
                                    title: "Check Failed",
                                    message: "Could not check for iCloud data: \(error.localizedDescription)",
                                    preferredStyle: .alert
                                )
                                alert.addAction(UIAlertAction(title: "OK", style: .default))
                                if let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
                                   let rootViewController = windowScene.windows.first?.rootViewController {
                                    rootViewController.present(alert, animated: true)
                                }
                            }
                        }
                    }
                } label: {
                    Label("Check for iCloud Data", systemImage: "icloud.and.arrow.down")
                }
            }
        } header: {
            HStack {
                Text("iCloud Sync")
                Spacer()
                HStack(spacing: 4) {
                    Circle()
                        .fill(iCloudManager.isEnabled ? Color.green : Color.gray)
                        .frame(width: 8, height: 8)
                    Text(iCloudManager.isEnabled ? "Enabled" : "Disabled")
                        .font(.caption)
                }
            }
        } footer: {
            Text("Sync summaries, transcripts, and settings across your devices")
        }
    }

    private var iCloudSyncToggleBinding: Binding<Bool> {
        Binding(
            get: { iCloudManager.isEnabled },
            set: { newValue in
                if newValue {
                    showingICloudComplianceNotice = true
                } else {
                    iCloudManager.isEnabled = false
                }
            }
        )
    }

    private var comedyModeSection: some View {
        Section {
            Toggle("Comedy Mode", isOn: $comedyModeEnabled)
            if comedyModeEnabled {
                Picker("Style", selection: $comedyModeStyle) {
                    Text("Snarky — dry wit & sarcasm").tag("snarky")
                    Text("Funny — goofy & absurd").tag("funny")
                }
            }
        } footer: {
            Text("Make AI summaries entertaining with a comedic twist. All information is preserved — just delivered with flair.")
        }
    }

    private var experimentalSection: some View {
        Section {
            Toggle("Experimental features", isOn: $enableExperimentalModels)
        } footer: {
            Text("Exposes experimental models in the On Device AI (Legacy) engine and the smaller Ternary Bonsai 1.7B model in the On Device AI engine. Experimental models are less reliable and may produce empty summaries.")
        }
    }

    private var debugTroubleshootingSection: some View {
        Section("Debug & Troubleshooting") {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Total Recordings Storage")
                    Text("Space used by audio recordings")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                Spacer()
                Text(totalRecordingsStorageString)
                    .foregroundColor(.secondary)
            }

            Button {
                showingBackgroundProcessing = true
            } label: {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Background Processing")
                            .foregroundColor(.primary)
                        Text("Manage transcription and summarization jobs")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Button {
                logExportError = nil
                withAnimation(.easeInOut(duration: 0.2)) { isPreparingLogs = true }

                Task {
                    do {
                        let url = try await Task.detached(priority: .userInitiated) {
                            try await LogExporter.exportLogs()
                        }.value

                        await MainActor.run {
                            LogEmailPresenter.shared.presentLogEmail(
                                logFileURL: url,
                                onPresented: {
                                    withAnimation(.easeInOut(duration: 0.2)) { isPreparingLogs = false }
                                }
                            ) {
                                withAnimation(.easeInOut(duration: 0.2)) { isPreparingLogs = false }
                            }
                        }
                    } catch {
                        await MainActor.run {
                            withAnimation(.easeInOut(duration: 0.2)) { isPreparingLogs = false }
                            logExportError = error.localizedDescription
                        }
                    }
                }
            } label: {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Export Diagnostic Logs")
                            .foregroundColor(.primary)
                        Text("Email logs to developer for troubleshooting")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    Spacer()
                    if isPreparingLogs {
                        ProgressView().scaleEffect(0.8)
                    } else {
                        Image(systemName: "envelope")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(isPreparingLogs)

            if let logExportError {
                Text("Error: \(logExportError)")
                    .font(.caption)
                    .foregroundColor(.red)
            }
        }
    }

    private var aboutSection: some View {
        Section("About") {
            Button {
                showingAcknowledgements = true
            } label: {
                HStack {
                    Image(systemName: "hand.raised.fill")
                        .foregroundColor(.indigo)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Acknowledgements")
                            .foregroundColor(.primary)
                        Text("Open-source projects and licenses")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Button(role: .destructive) {
                showingTroubleshootingWarning = true
            } label: {
                Label("Advanced Troubleshooting", systemImage: "wrench.and.screwdriver")
            }
            .alert("Warning", isPresented: $showingTroubleshootingWarning) {
                Button("Cancel", role: .cancel) { }
                Button("OK") {
                    showingDataMigration = true
                }
            } message: {
                Text("These tools can delete data. Use with caution.")
            }
        }
    }

    private var databaseMaintenanceSection: some View {
        EmptyView()
    }

    // MARK: - Location Status Helpers

    private var locationStatusIcon: String {
        switch recorderVM.locationManager.locationStatus {
        case .authorizedWhenInUse, .authorizedAlways:
            return "location.fill"
        case .denied, .restricted:
            return "location.slash"
        case .notDetermined:
            return "location"
        @unknown default:
            return "location"
        }
    }

    private var locationStatusColor: Color {
        switch recorderVM.locationManager.locationStatus {
        case .authorizedWhenInUse, .authorizedAlways:
            return .green
        case .denied, .restricted:
            return .red
        case .notDetermined:
            return .orange
        @unknown default:
            return .gray
        }
    }

    private var locationStatusText: String {
        switch recorderVM.locationManager.locationStatus {
        case .authorizedWhenInUse, .authorizedAlways:
            return "Location access granted"
        case .denied, .restricted:
            return "Location access denied - Enable in Settings"
        case .notDetermined:
            return "Location permission not requested"
        @unknown default:
            return "Unknown location status"
        }
    }

    private func microphoneTypeDescription(for portType: AVAudioSession.Port) -> String {
        switch portType {
        case .builtInMic:
            return "Built-in Microphone"
        case .headsetMic:
            return "Headset Microphone"
        case .bluetoothHFP:
            return "Bluetooth Hands-Free"
        case .bluetoothA2DP:
            return "Bluetooth Audio"
        case .bluetoothLE:
            return "Bluetooth Low Energy"
        case .usbAudio:
            return "USB Audio Device"
        case .carAudio:
            return "Car Audio System"
        case .airPlay:
            return "AirPlay Device"
        case .lineIn:
            return "Line Input"
        default:
            return portType.rawValue.capitalized
        }
    }

    private func clearAllSummaries() {
        // This function is no longer needed as summaries are managed by the coordinator
    }


    // MARK: - iCloud Sync Functions

    private func syncAllSummaries() async {
        do {
            try await iCloudManager.syncAllSummaries()
        } catch {
            AppLog.shared.log("Sync error: \(error)", level: .error, category: .general)
            await MainActor.run {
                errorHandler.handle(AppError.from(error, context: "iCloud Sync"), context: "Sync", showToUser: true)
            }
        }
    }

    private func backupAllDataToiCloud() async {
        await MainActor.run {
            isRunningCloudBackupAction = true
            cloudBackupActionMessage = ""
            cloudBackupActionIsError = false
        }

        let options = CloudBackupOptions(
            includeAudioFiles: iCloudBackupIncludeAudioFiles,
            includeSettings: iCloudBackupIncludeSettings,
            includeSensitiveSettings: iCloudBackupIncludeSettings && iCloudBackupIncludeSensitiveSettings
        )

        do {
            let result = try await iCloudManager.backupAllDataToiCloud(
                appCoordinator: appCoordinator,
                options: options
            )

            if result.wasSkippedNoChanges {
                await MainActor.run {
                    cloudBackupActionMessage = "Backup skipped: no local changes since the last successful backup."
                    cloudBackupActionIsError = false
                    isRunningCloudBackupAction = false
                }
                return
            }

            let settingsText: String
            if result.settingsBackedUp {
                settingsText = result.includedSensitiveSettings ? "settings + sensitive settings" : "settings"
            } else {
                settingsText = "no settings"
            }

            await MainActor.run {
                let unchangedAudioText = iCloudBackupIncludeAudioFiles
                    ? ", \(result.audioFilesSkippedUnchanged) audio unchanged"
                    : ""
                cloudBackupActionMessage =
                    "Backup complete: \(result.recordingsBackedUp) recordings, \(result.transcriptsBackedUp) transcripts, \(result.summariesBackedUp) summaries, \(result.audioFilesBackedUp) audio uploaded\(unchangedAudioText), \(settingsText)."
                cloudBackupActionIsError = false
                isRunningCloudBackupAction = false
            }
        } catch {
            await MainActor.run {
                cloudBackupActionMessage = "Backup failed: \(error.localizedDescription)"
                cloudBackupActionIsError = true
                isRunningCloudBackupAction = false
            }
        }
    }

    private func restoreAllDataFromiCloud() async {
        await MainActor.run {
            isRunningCloudBackupAction = true
            cloudBackupActionMessage = ""
            cloudBackupActionIsError = false
        }

        do {
            let result = try await iCloudManager.restoreAllDataFromiCloud(
                appCoordinator: appCoordinator,
                includeAudioFiles: iCloudBackupIncludeAudioFiles,
                restoreSettings: iCloudBackupIncludeSettings
            )
            appCoordinator.syncRecordingURLs()

            let settingsText: String
            if result.settingsRestored {
                settingsText = result.includedSensitiveSettings ? "settings + sensitive settings" : "settings"
            } else {
                settingsText = "no settings"
            }

            await MainActor.run {
                let reviewText = result.itemsHeldForReview > 0
                    ? ", \(result.itemsHeldForReview) held for review"
                    : ""
                cloudBackupActionMessage =
                    "Restore complete: \(result.recordingsRestored) recordings, \(result.transcriptsRestored) transcripts, \(result.summariesRestored) summaries, \(result.audioFilesRestored) audio files, \(settingsText)\(reviewText)."
                cloudBackupActionIsError = false
                isRunningCloudBackupAction = false
            }
        } catch {
            await MainActor.run {
                cloudBackupActionMessage = "Restore failed: \(error.localizedDescription)"
                cloudBackupActionIsError = true
                isRunningCloudBackupAction = false
            }
        }
    }

    private func checkForiCloudData() {
        Task {
            do {
                let cloudSummaries = try await iCloudManager.fetchSummariesFromiCloud(forRecovery: true)

                let localSummaries = appCoordinator.coreDataManager.getAllSummaries()
                let localSummaryIds = Set(localSummaries.compactMap { $0.id })
                let cloudOnlySummaries = cloudSummaries.filter { !localSummaryIds.contains($0.id) }

                if !cloudOnlySummaries.isEmpty {
                    await MainActor.run {
                        let alert = UIAlertController(
                            title: "iCloud Data Found",
                            message: "We found \(cloudOnlySummaries.count) summaries in your iCloud that aren't on this device. Would you like to download them?",
                            preferredStyle: .alert
                        )
                        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
                        alert.addAction(UIAlertAction(title: "Download", style: .default) { _ in
                            Task {
                                do {
                                    let count = try await iCloudManager.downloadSummariesFromCloud(appCoordinator: appCoordinator, forRecovery: true)
                                    AppLog.shared.log("Downloaded \(count) summaries from iCloud", category: .general)
                                } catch {
                                    AppLog.shared.log("Failed to download summaries: \(error)", level: .error, category: .general)
                                }
                            }
                        })
                        if let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
                           let rootViewController = windowScene.windows.first?.rootViewController {
                            rootViewController.present(alert, animated: true)
                        }
                    }
                } else {
                    await MainActor.run {
                        let alert = UIAlertController(
                            title: "No iCloud Data",
                            message: "No summaries were found in your iCloud account.",
                            preferredStyle: .alert
                        )
                        alert.addAction(UIAlertAction(title: "OK", style: .default))
                        if let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
                           let rootViewController = windowScene.windows.first?.rootViewController {
                            rootViewController.present(alert, animated: true)
                        }
                    }
                }
            } catch {
                AppLog.shared.log("Failed to check for iCloud data: \(error)", level: .error, category: .general)
                await MainActor.run {
                    let alert = UIAlertController(
                        title: "Check Failed",
                        message: "Could not check for iCloud data: \(error.localizedDescription)",
                        preferredStyle: .alert
                    )
                    alert.addAction(UIAlertAction(title: "OK", style: .default))
                    if let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
                       let rootViewController = windowScene.windows.first?.rootViewController {
                        rootViewController.present(alert, animated: true)
                    }
                }
            }
        }
    }

    private func exportDiagnosticLogs() {
        logExportError = nil
        withAnimation(.easeInOut(duration: 0.2)) { isPreparingLogs = true }

        Task {
            do {
                let url = try await Task.detached(priority: .userInitiated) {
                    try await LogExporter.exportLogs()
                }.value

                await MainActor.run {
                    LogEmailPresenter.shared.presentLogEmail(
                        logFileURL: url,
                        onPresented: {
                            withAnimation(.easeInOut(duration: 0.2)) { isPreparingLogs = false }
                        }
                    ) {
                        withAnimation(.easeInOut(duration: 0.2)) { isPreparingLogs = false }
                    }
                }
            } catch {
                await MainActor.run {
                    withAnimation(.easeInOut(duration: 0.2)) { isPreparingLogs = false }
                    logExportError = error.localizedDescription
                }
            }
        }
    }

    private func refreshEngineStatuses() {
        // Set the engine to the currently selected one from settings
        regenerationManager.setEngine(selectedAIEngine)
    }

    private var totalRecordingsStorageString: String {
        let recordingsWithData = appCoordinator.getAllRecordingsWithData()
        var totalSize: Int64 = 0

        for entry in recordingsWithData {
            // Skip imported transcripts
            if entry.recording.audioQuality == "imported" {
                continue
            }

            guard let url = appCoordinator.getAbsoluteURL(for: entry.recording),
                  FileManager.default.fileExists(atPath: url.path) else {
                continue
            }

            if let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
               let size = attributes[.size] as? Int64 {
                totalSize += size
            }
        }

        return ByteCountFormatter.string(fromByteCount: totalSize, countStyle: .file)
    }

}

// MARK: - Supporting Structures

private struct CloudReviewItemsView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var appCoordinator: AppDataCoordinator
    @ObservedObject private var iCloudManager = iCloudStorageManager.shared

    let includeAudioFiles: Bool

    @State private var actionMessage = ""
    @State private var actionIsError = false
    @State private var workingItemId: String?
    @State private var itemPendingDelete: CloudReviewItem?

    var body: some View {
        NavigationStack {
            List {
                if iCloudManager.isScanningCloudReviewItems {
                    HStack {
                        ProgressView()
                        Text("Scanning iCloud...")
                            .foregroundColor(.secondary)
                    }
                }

                if !actionMessage.isEmpty {
                    Text(actionMessage)
                        .font(.caption)
                        .foregroundColor(actionIsError ? .red : .secondary)
                }

                if let error = iCloudManager.cloudReviewError {
                    Text(error)
                        .font(.caption)
                        .foregroundColor(.red)
                }

                if iCloudManager.pendingCloudReviewItems.isEmpty,
                   !iCloudManager.isScanningCloudReviewItems {
                    Text("No iCloud review items found.")
                        .foregroundColor(.secondary)
                }

                ForEach(iCloudManager.pendingCloudReviewItems) { item in
                    VStack(alignment: .leading, spacing: 10) {
                        HStack(alignment: .top) {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(item.title)
                                    .font(.headline)
                                Text(item.contentsDescription.capitalized)
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                                if let date = item.date {
                                    Text(date.formatted(date: .abbreviated, time: .shortened))
                                        .font(.caption2)
                                        .foregroundColor(.secondary)
                                }
                            }
                            Spacer()
                            if workingItemId == item.id {
                                ProgressView()
                            }
                        }

                        HStack {
                            Button {
                                Task { await restore(item) }
                            } label: {
                                Label("Restore", systemImage: "arrow.down.doc")
                            }
                            .buttonStyle(.borderedProminent)
                            .disabled(workingItemId != nil || iCloudManager.isScanningCloudReviewItems)

                            Button(role: .destructive) {
                                itemPendingDelete = item
                            } label: {
                                Label("Delete from iCloud", systemImage: "trash")
                            }
                            .buttonStyle(.bordered)
                            .disabled(workingItemId != nil || iCloudManager.isScanningCloudReviewItems)
                        }
                    }
                    .padding(.vertical, 6)
                }
            }
            .navigationTitle("iCloud Items Review")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Done") { dismiss() }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button {
                        Task { await refresh() }
                    } label: {
                        Label("Refresh", systemImage: "arrow.clockwise")
                    }
                    .disabled(iCloudManager.isScanningCloudReviewItems || workingItemId != nil)
                }
            }
            .confirmationDialog(
                "Delete this item from iCloud?",
                isPresented: Binding(
                    get: { itemPendingDelete != nil },
                    set: { if !$0 { itemPendingDelete = nil } }
                ),
                titleVisibility: .visible
            ) {
                Button("Delete from iCloud", role: .destructive) {
                    if let item = itemPendingDelete {
                        Task { await delete(item) }
                    }
                }
                Button("Cancel", role: .cancel) {
                    itemPendingDelete = nil
                }
            } message: {
                Text("This removes app-created iCloud sync records for the selected item. It does not delete anything already stored locally on this device.")
            }
            .task {
                await refresh()
            }
        }
    }

    private func refresh() async {
        await iCloudManager.refreshCloudReviewItems(appCoordinator: appCoordinator)
    }

    private func restore(_ item: CloudReviewItem) async {
        await MainActor.run {
            workingItemId = item.id
            actionMessage = ""
            actionIsError = false
        }

        do {
            let result = try await iCloudManager.restoreCloudReviewItem(
                item,
                appCoordinator: appCoordinator,
                includeAudioFiles: includeAudioFiles
            )
            appCoordinator.syncRecordingURLs()
            await MainActor.run {
                actionMessage = "Restored \(result.recordingsRestored) recordings, \(result.transcriptsRestored) transcripts, \(result.summariesRestored) summaries."
                actionIsError = false
                workingItemId = nil
            }
        } catch {
            await MainActor.run {
                actionMessage = "Restore failed: \(error.localizedDescription)"
                actionIsError = true
                workingItemId = nil
            }
        }
    }

    private func delete(_ item: CloudReviewItem) async {
        await MainActor.run {
            workingItemId = item.id
            actionMessage = ""
            actionIsError = false
            itemPendingDelete = nil
        }

        do {
            let deletedCount = try await iCloudManager.deleteCloudReviewItem(item)
            await MainActor.run {
                actionMessage = "Deleted \(deletedCount) iCloud records."
                actionIsError = false
                workingItemId = nil
            }
        } catch {
            await MainActor.run {
                actionMessage = "Delete failed: \(error.localizedDescription)"
                actionIsError = true
                workingItemId = nil
            }
        }
    }
}

private struct ModernSettingsCard<Content: View, Trailing: View>: View {
    let title: String
    let systemImage: String
    let tint: Color
    @ViewBuilder let trailing: Trailing
    @ViewBuilder let content: Content

    init(
        title: String,
        systemImage: String,
        tint: Color,
        @ViewBuilder trailing: () -> Trailing,
        @ViewBuilder content: () -> Content
    ) {
        self.title = title
        self.systemImage = systemImage
        self.tint = tint
        self.trailing = trailing()
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 10) {
                ModernIcon(systemName: systemImage, tint: tint, size: 30, cornerRadius: 9)

                Text(title)
                    .font(.headline)
                    .foregroundColor(.primary)

                Spacer()

                trailing
            }

            content
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 18))
    }
}

private extension ModernSettingsCard where Trailing == EmptyView {
    init(
        title: String,
        systemImage: String,
        tint: Color,
        @ViewBuilder content: () -> Content
    ) {
        self.init(
            title: title,
            systemImage: systemImage,
            tint: tint,
            trailing: { EmptyView() },
            content: content
        )
    }
}

private struct ModernSettingsNavigationRow<Trailing: View>: View {
    let title: String
    let subtitle: String
    let systemImage: String
    let tint: Color
    @ViewBuilder let trailing: Trailing
    let action: () -> Void

    init(
        title: String,
        subtitle: String,
        systemImage: String,
        tint: Color,
        @ViewBuilder trailing: () -> Trailing,
        action: @escaping () -> Void
    ) {
        self.title = title
        self.subtitle = subtitle
        self.systemImage = systemImage
        self.tint = tint
        self.trailing = trailing()
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 14) {
                ModernIcon(systemName: systemImage, tint: tint)

                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(.subheadline.weight(.semibold))
                        .foregroundColor(.primary)

                    Text(subtitle)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 8)

                trailing

                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundColor(.secondary)
            }
            .padding(14)
            .background(Color(.tertiarySystemGroupedBackground))
            .clipShape(RoundedRectangle(cornerRadius: 15))
        }
        .buttonStyle(.plain)
    }
}

private extension ModernSettingsNavigationRow where Trailing == EmptyView {
    init(
        title: String,
        subtitle: String,
        systemImage: String,
        tint: Color,
        action: @escaping () -> Void
    ) {
        self.init(
            title: title,
            subtitle: subtitle,
            systemImage: systemImage,
            tint: tint,
            trailing: { EmptyView() },
            action: action
        )
    }
}

private struct ModernSelectableRow: View {
    let title: String
    let subtitle: String
    let systemImage: String
    let tint: Color
    let isSelected: Bool

    var body: some View {
        HStack(spacing: 14) {
            ModernIcon(systemName: systemImage, tint: tint)

            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundColor(.primary)

                Text(subtitle)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Spacer()

            Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                .font(.title3)
                .foregroundColor(isSelected ? tint : .secondary)
        }
        .padding(14)
        .background(isSelected ? tint.opacity(0.12) : Color(.tertiarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 15))
    }
}

private struct ModernSettingsLabel: View {
    let title: String
    let subtitle: String
    let systemImage: String
    let tint: Color

    var body: some View {
        HStack(spacing: 14) {
            ModernIcon(systemName: systemImage, tint: tint)

            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundColor(.primary)

                Text(subtitle)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
    }
}

private struct ModernInlineStatus: View {
    let title: String
    let subtitle: String?
    let systemImage: String
    let tint: Color
    var showsProgress = false

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            if showsProgress {
                ProgressView()
                    .scaleEffect(0.8)
                    .padding(.top, 1)
            } else {
                Image(systemName: systemImage)
                    .font(.caption.weight(.semibold))
                    .foregroundColor(tint)
                    .padding(.top, 2)
            }

            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.caption.weight(.semibold))
                    .foregroundColor(tint)
                if let subtitle {
                    Text(subtitle)
                        .font(.caption2)
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(tint.opacity(0.1))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }
}

private struct ModernStatusPill: View {
    let text: String
    let tint: Color

    var body: some View {
        Text(text)
            .font(.caption2.weight(.bold))
            .foregroundColor(tint)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(tint.opacity(0.14))
            .clipShape(Capsule())
    }
}

private struct ModernIcon: View {
    let systemName: String
    let tint: Color
    var size: CGFloat = 38
    var cornerRadius: CGFloat = 11

    var body: some View {
        Image(systemName: systemName)
            .font(.system(size: 17, weight: .semibold))
            .foregroundColor(tint)
            .frame(width: size, height: size)
            .background(tint.opacity(0.14))
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
    }
}

struct DebugButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.caption)
            .foregroundColor(.primary)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color(.systemGray6))
                    .opacity(configuration.isPressed ? 0.8 : 1.0)
            )
            .scaleEffect(configuration.isPressed ? 0.98 : 1.0)
            .animation(.easeInOut(duration: 0.1), value: configuration.isPressed)
    }
}
