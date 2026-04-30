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

    @AppStorage("selectedTranscriptionEngine") private var selectedTranscriptionEngine: String = "On Device"
    @AppStorage("SelectedAIEngine") private var selectedAIEngine: String = "On-Device AI"
    @AppStorage("WatchIntegrationEnabled") private var watchIntegrationEnabled: Bool = true
    @AppStorage("WatchAutoSync") private var watchAutoSync: Bool = true
    @AppStorage("WatchBatteryAware") private var watchBatteryAware: Bool = true
    @AppStorage("iCloudBackupIncludeAudioFiles") private var iCloudBackupIncludeAudioFiles: Bool = false
    @AppStorage("iCloudBackupIncludeSettings") private var iCloudBackupIncludeSettings: Bool = true
    @AppStorage("iCloudBackupIncludeSensitiveSettings") private var iCloudBackupIncludeSensitiveSettings: Bool = true
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
        // NavigationStack { Form } is the only sheet pattern that scrolls reliably
        // on Mac Catalyst — Form is UITableView-backed, ScrollView is not. See
        // feedback_mac_catalyst_scrollview.md for the diagnostic that confirmed this.
        NavigationStack {
            Form {
                preferencesSection
                aiEngineSection
                transcriptionSection
                microphoneSection
                locationSection
                iCloudSyncSection
                comedyModeSection
                experimentalSection
                debugTroubleshootingSection
                aboutSection
            }
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
        .onChange(of: enableExperimentalModels) { oldValue, newValue in
            OnDeviceLLMDownloadManager.shared.refreshModelStatus()

            if !newValue {
                UserDefaults.standard.set(false, forKey: MLXSwiftSettingsKeys.enabled)

                let currentModelId = UserDefaults.standard.string(forKey: OnDeviceLLMModelInfo.SettingsKeys.selectedModelId) ?? ""
                if !OnDeviceLLMModelInfo.availableModels.contains(where: { $0.id == currentModelId }) {
                    if let firstAvailable = OnDeviceLLMModelInfo.availableModels.first {
                        UserDefaults.standard.set(firstAvailable.id, forKey: OnDeviceLLMModelInfo.SettingsKeys.selectedModelId)
                    }
                }

                let onDeviceHasModels = !OnDeviceLLMModelInfo.availableModels.isEmpty
                let fallbackEngine: String
                if onDeviceHasModels {
                    fallbackEngine = AIEngineType.onDeviceLLM.rawValue
                } else {
                    fallbackEngine = AIEngineType.appleNative.rawValue
                }

                if selectedAIEngine == AIEngineType.mlxSwift.rawValue {
                    selectedAIEngine = fallbackEngine
                    SummaryManager.shared.setEngine(fallbackEngine)
                }

                if selectedAIEngine == AIEngineType.onDeviceLLM.rawValue && !onDeviceHasModels {
                    selectedAIEngine = fallbackEngine
                    SummaryManager.shared.setEngine(fallbackEngine)
                }
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
                        Text("Preparing logs…")
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
        } header: {
            HStack {
                Text("Microphone Selection")
                Spacer()
                Button {
                    Task { await recorderVM.fetchInputs() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
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
            Toggle("Enable iCloud Sync", isOn: $iCloudManager.isEnabled)

            if iCloudManager.isEnabled {
                Toggle("Include audio files in backup", isOn: $iCloudBackupIncludeAudioFiles)
                Toggle("Include app settings", isOn: $iCloudBackupIncludeSettings)
                Toggle("Include API keys (encrypted)", isOn: $iCloudBackupIncludeSensitiveSettings)
                    .disabled(!iCloudBackupIncludeSettings)

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
            Toggle("Experimental summary models & MLX AI engine", isOn: $enableExperimentalModels)
        } footer: {
            Text("Allow experimental local summary models and show the MLX Swift AI engine in AI settings. These models are unreliable and may produce empty summaries. For devices with <6GB RAM, this enables on-device AI with only LFM 2.5 available.")
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
                settingsText = result.includedSensitiveSettings ? "settings + encrypted keys" : "settings"
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
                settingsText = result.includedSensitiveSettings ? "settings + encrypted keys" : "settings"
            } else {
                settingsText = "no settings"
            }

            await MainActor.run {
                cloudBackupActionMessage =
                    "Restore complete: \(result.recordingsRestored) recordings, \(result.transcriptsRestored) transcripts, \(result.summariesRestored) summaries, \(result.audioFilesRestored) audio files, \(settingsText)."
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
