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
    @EnvironmentObject var recorderVM: AudioRecorderViewModel
    @EnvironmentObject var appCoordinator: AppDataCoordinator
    @StateObject private var regenerationManager: SummaryRegenerationManager
    @StateObject private var errorHandler = ErrorHandler()
    @ObservedObject private var iCloudManager: iCloudStorageManager
    @StateObject private var importManager = FileImportManager()
    @State private var showingEngineChangePrompt = false
    @State private var previousEngine = ""
    @State private var showingTranscriptionSettings = false
    @State private var showingAISettings = false
    @State private var showingClearSummariesAlert = false
    @State private var showingBackgroundProcessing = false
    @State private var showingDataMigration = false
    @State private var showingPreferences = false
    @State private var showingTroubleshootingWarning = false

    @AppStorage("SelectedAIEngine") private var selectedAIEngine: String = "On-Device AI"
    @AppStorage("WatchIntegrationEnabled") private var watchIntegrationEnabled: Bool = true
    @AppStorage("WatchAutoSync") private var watchAutoSync: Bool = true
    @AppStorage("WatchBatteryAware") private var watchBatteryAware: Bool = true
    @AppStorage(OnDeviceLLMModelInfo.SettingsKeys.enableExperimentalModels) private var enableExperimentalModels = false
    
    init() {
        // Initialize regeneration manager with the coordinator's registry manager
        self._regenerationManager = StateObject(wrappedValue: SummaryRegenerationManager(
            summaryManager: SummaryManager.shared,
            transcriptManager: TranscriptManager.shared,
            appCoordinator: AppDataCoordinator()
        ))
        self.iCloudManager = iCloudStorageManager()
    }
    
    var body: some View {
        ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    headerSection
                    preferencesSection
                    aiEngineSection
                    transcriptionSection
                    microphoneSection
                    advancedSection
                    debugSection
                    databaseMaintenanceSection

                    
                    Spacer(minLength: 40)
                }
            }
        .alert("Regeneration Complete", isPresented: $regenerationManager.showingRegenerationAlert) {
            Button("OK") {
                regenerationManager.showingRegenerationAlert = false
            }
        } message: {
            Text("Regeneration completed successfully") // Use default message since regenerationAlertMessage doesn't exist
        }
        .alert("Engine Change", isPresented: $showingEngineChangePrompt) {
            Button("Cancel") {
                showingEngineChangePrompt = false
            }
            Button("Regenerate") {
                Task {
                    regenerationManager.setEngine(selectedAIEngine)
                    await regenerationManager.regenerateAllSummaries()
                }
                showingEngineChangePrompt = false
            }
        } message: {
            Text("You've switched from \(previousEngine) to \(selectedAIEngine). Would you like to regenerate your existing summaries with the new AI engine?")
        }
        .onAppear {
            refreshEngineStatuses()
            // Fetch available microphone inputs
            Task {
                await recorderVM.fetchInputs()
            }
        }
        .onChange(of: selectedAIEngine) { _, newEngine in
            // Immediately update the SummaryManager when user changes AI engine selection
            SummaryManager.shared.setEngine(newEngine)
            print("🔄 SettingsView: Updated AI engine to '\(newEngine)'")
        }
        .onChange(of: enableExperimentalModels) { oldValue, newValue in
            // Refresh model list when experimental models toggle changes
            OnDeviceLLMDownloadManager.shared.refreshModelStatus()
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
    }
    
    private var headerSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Settings")
                    .font(.largeTitle)
                    .fontWeight(.bold)
                    .foregroundColor(.primary)
                
                Spacer()
            }
            .padding(.top, 20)
            .padding(.horizontal, 24)
            
            Text("Advanced settings for comprehensive configuration")
                .font(.subheadline)
                .foregroundColor(.secondary)
                .padding(.horizontal, 24)
        }
    }
    
    private var preferencesSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Preferences")
                .font(.headline)
                .foregroundColor(.primary)
                .padding(.horizontal, 24)
            
            Button(action: {
                showingPreferences = true
            }) {
                HStack {
                    Image(systemName: "slider.horizontal.3")
                        .font(.title2)
                        .foregroundColor(.indigo)
                        .frame(width: 32)
                    
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Display Preferences")
                            .font(.body)
                            .fontWeight(.medium)
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
                .padding(.horizontal, 24)
                .padding(.vertical, 12)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color.indigo.opacity(0.1))
                )
            }
            .buttonStyle(PlainButtonStyle())
            .padding(.horizontal, 24)
        }
    }
    
    private var microphoneSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Microphone Selection")
                    .font(.headline)
                    .foregroundColor(.primary)
                Spacer()
                Button(action: {
                    Task {
                        await recorderVM.fetchInputs()
                    }
                }) {
                    Image(systemName: "arrow.clockwise")
                        .font(.title3)
                        .foregroundColor(.accentColor)
                }
            }
            .padding(.horizontal, 24)
            
            if recorderVM.availableInputs.isEmpty {
                HStack {
                    Image(systemName: "exclamationmark.triangle")
                        .foregroundColor(.orange)
                    Text("No microphones found.")
                        .foregroundColor(.secondary)
                }
                .padding(.horizontal, 24)
            } else {
                microphonePicker
            }
        }
    }
    
    private var microphonePicker: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(recorderVM.availableInputs, id: \.uid) { input in
                HStack {
                    Button(action: {
                        recorderVM.selectedInput = input
                        recorderVM.setPreferredInput()
                    }) {
                        HStack {
                            Image(systemName: recorderVM.selectedInput?.uid == input.uid ? "largecircle.fill.circle" : "circle")
                                .foregroundColor(recorderVM.selectedInput?.uid == input.uid ? .blue : .gray)
                                .font(.title2)
                            
                            VStack(alignment: .leading, spacing: 2) {
                                Text(input.portName)
                                    .font(.body)
                                    .fontWeight(.medium)
                                    .foregroundColor(.primary)
                                
                                Text(input.portType.rawValue)
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                            
                            Spacer()
                        }
                    }
                    .buttonStyle(PlainButtonStyle())
                }
                .padding(.horizontal, 24)
                .padding(.vertical, 8)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(recorderVM.selectedInput?.uid == input.uid ? Color.blue.opacity(0.1) : Color.clear)
                )
            }
        }
    }
    

    private var aiEngineSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("AI Processing")
                .font(.headline)
                .foregroundColor(.primary)
                .padding(.horizontal, 24)
            
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Current Engine:")
                        .font(.body)
                        .foregroundColor(.secondary)
                    Text(selectedAIEngine)
                        .font(.body)
                        .fontWeight(.medium)
                        .foregroundColor(.primary)
                }
                
                // Engine status indicator
                HStack {
                    Text("Status:")
                        .font(.body)
                        .foregroundColor(.secondary)
                    
                    // TODO: Update to use new Core Data system
                    // let engineStatus = appCoordinator.registryManager.getEngineAvailabilityStatus()[selectedAIEngine]
                    let statusColor: Color = .green // Temporary: assume available
                    let statusText = "Available" // Temporary: assume available
                    
                    HStack(spacing: 4) {
                        Circle()
                            .fill(statusColor)
                            .frame(width: 8, height: 8)
                        Text(statusText)
                            .font(.body)
                            .fontWeight(.medium)
                            .foregroundColor(statusColor)
                    }
                }
            }
            .padding(.horizontal, 24)
            
            HStack {
                Button(action: {
                    showingAISettings = true
                }) {
                    HStack {
                        Text("Configure AI Engines")
                        Spacer()
                        Image(systemName: "arrow.right")
                    }
                    .padding(.horizontal, 24)
                    .padding(.vertical, 12)
                    .background(
                        RoundedRectangle(cornerRadius: 8)
                            .fill(Color.blue.opacity(0.1))
                    )
                    .foregroundColor(.blue)
                }
                
                Button(action: {
                    // TODO: Update to use new Core Data system
                    // Task {
                    //     await appCoordinator.registryManager.refreshEngineAvailability()
                    // }
                }) {
                    Image(systemName: "arrow.clockwise")
                        .font(.caption)
                        .foregroundColor(.blue)
                }
                .padding(.horizontal, 8)
            }
            .padding(.horizontal, 24)
            
        }
    }
    
    private var transcriptionSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Transcription Engine")
                .font(.headline)
                .foregroundColor(.primary)
                .padding(.horizontal, 24)
            
            HStack {
                Text("Current Engine:")
                    .font(.body)
                    .foregroundColor(.secondary)
                Text(TranscriptionEngine(rawValue: UserDefaults.standard.string(forKey: "selectedTranscriptionEngine") ?? TranscriptionEngine.whisperKit.rawValue)?.rawValue ?? "On Device")
                    .font(.body)
                    .fontWeight(.medium)
                    .foregroundColor(.primary)
            }
            .padding(.horizontal, 24)
            
            Button(action: {
                showingTranscriptionSettings = true
            }) {
                HStack {
                    Text("Configure Transcription")
                    Spacer()
                    Image(systemName: "arrow.right")
                }
                .padding(.horizontal, 24)
                .padding(.vertical, 12)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color.purple.opacity(0.1))
                )
                .foregroundColor(.purple)
            }
            .padding(.horizontal, 24)
        }
    }
    
    
    
    private var advancedSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Advanced Settings")
                .font(.headline)
                .foregroundColor(.primary)
                .padding(.horizontal, 24)
            
            VStack(alignment: .leading, spacing: 8) {
                // Location Services
                VStack(spacing: 8) {
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Location Services")
                                .font(.body)
                                .foregroundColor(.primary)
                            Text("Capture location data with recordings")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        Spacer()
                        Toggle("", isOn: Binding(
                            get: { recorderVM.isLocationTrackingEnabled },
                            set: { newValue in
                                recorderVM.toggleLocationTracking(newValue)
                            }
                        ))
                        .labelsHidden()
                    }
                    
                    // Location status indicator
                    if recorderVM.isLocationTrackingEnabled {
                        HStack {
                            Image(systemName: locationStatusIcon)
                                .font(.caption)
                                .foregroundColor(locationStatusColor)
                            Text(locationStatusText)
                                .font(.caption)
                                .foregroundColor(locationStatusColor)
                            Spacer()
                        }
                    }
                }
                .padding(.horizontal, 24)
                .padding(.vertical, 12)
                .background(
                    Rectangle()
                        .fill(Color(.systemGray6))
                        .opacity(0.3)
                )
                
                // iCloud Sync
                VStack(spacing: 8) {
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("iCloud Sync")
                                .font(.body)
                                .foregroundColor(.primary)
                            Text("Sync summaries to iCloud for access across devices")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        Spacer()
                        Toggle("", isOn: $iCloudManager.isEnabled)
                            .labelsHidden()
                    }

                    // Show sync status
                    HStack {
                        Text("Status:")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        Spacer()
                        HStack(spacing: 4) {
                            Circle()
                                .fill(iCloudManager.isEnabled ? Color.green : Color.gray)
                                .frame(width: 8, height: 8)
                            Text(iCloudManager.isEnabled ? "Enabled" : "Disabled")
                                .font(.caption)
                                .foregroundColor(iCloudManager.isEnabled ? .green : .gray)
                        }
                    }
                    .padding(.top, 4)

                    // Show conflicts if any exist
                    if !iCloudManager.pendingConflicts.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Sync Conflicts (\(iCloudManager.pendingConflicts.count))")
                                .font(.caption)
                                .fontWeight(.medium)
                                .foregroundColor(.orange)

                            ForEach(iCloudManager.pendingConflicts, id: \.summaryId) { conflict in
                                HStack {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(conflict.localSummary.recordingName)
                                            .font(.caption)
                                            .foregroundColor(.primary)
                                        Text("Modified on different devices")
                                            .font(.caption2)
                                            .foregroundColor(.secondary)
                                    }

                                    Spacer()

                                    HStack(spacing: 8) {
                                        Button("Use Local") {
                                            Task {
                                                try? await iCloudManager.resolveConflict(conflict, useLocal: true)
                                            }
                                        }
                                        .font(.caption2)
                                        .foregroundColor(.blue)
                                        .padding(.horizontal, 8)
                                        .padding(.vertical, 4)
                                        .background(
                                            RoundedRectangle(cornerRadius: 4)
                                                .fill(Color.blue.opacity(0.1))
                                        )

                                        Button("Use Cloud") {
                                            Task {
                                                try? await iCloudManager.resolveConflict(conflict, useLocal: false)
                                            }
                                        }
                                        .font(.caption2)
                                        .foregroundColor(.green)
                                        .padding(.horizontal, 8)
                                        .padding(.vertical, 4)
                                        .background(
                                            RoundedRectangle(cornerRadius: 4)
                                                .fill(Color.green.opacity(0.1))
                                        )
                                    }
                                }
                                .padding(.vertical, 4)
                            }
                        }
                        .padding(.top, 4)
                    }

                    // Show errors if any exist
                    if let error = iCloudManager.lastError {
                        Text("Error: \(error)")
                            .font(.caption)
                            .foregroundColor(.red)
                            .padding(.top, 4)
                    }

                    if !iCloudManager.isEnabled {
                        Button(action: {
                            Task {
                                do {
                                    // Check for iCloud data using recovery flag that works even when sync is disabled
                                    let cloudSummaries = try await iCloudManager.fetchSummariesFromiCloud(forRecovery: true)

                                    let localSummaries = appCoordinator.coreDataManager.getAllSummaries()
                                    let localSummaryIds = Set(localSummaries.compactMap { $0.id })
                                    let cloudOnlySummaries = cloudSummaries.filter { !localSummaryIds.contains($0.id) }

                                    if !cloudOnlySummaries.isEmpty {
                                        // Show alert asking user if they want to download
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
                                                        print("✅ Downloaded \(count) summaries from iCloud")
                                                    } catch {
                                                        print("❌ Failed to download summaries: \(error)")
                                                    }
                                                }
                                            })

                                            if let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
                                               let rootViewController = windowScene.windows.first?.rootViewController {
                                                rootViewController.present(alert, animated: true)
                                            }
                                        }
                                    } else {
                                        // Show message that no cloud data was found
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
                                    print("❌ Failed to check for iCloud data: \(error)")
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
                        }) {
                            HStack {
                                Image(systemName: "icloud.and.arrow.down")
                                Text("Check for iCloud Data")
                            }
                            .font(.caption)
                            .foregroundColor(.blue)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .background(
                                RoundedRectangle(cornerRadius: 6)
                                    .fill(Color.blue.opacity(0.1))
                            )
                        }
                        .padding(.top, 8)
                    }
                }
                .padding(.horizontal, 24)
                .padding(.vertical, 12)
                .background(
                    Rectangle()
                        .fill(Color(.systemGray6))
                        .opacity(0.3)
                )
            }
        }
    }
    
    private var debugSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Debug & Troubleshooting")
                .font(.headline)
                .foregroundColor(.primary)
                .padding(.horizontal, 24)

            VStack(alignment: .leading, spacing: 8) {
                // Storage Information
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Total Recordings Storage")
                            .font(.body)
                            .foregroundColor(.primary)
                        Text("Space used by audio recordings")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    Spacer()
                    Text(totalRecordingsStorageString)
                        .font(.body)
                        .fontWeight(.medium)
                        .foregroundColor(.primary)
                }
                .padding(.horizontal, 24)
                .padding(.vertical, 12)
                .background(
                    Rectangle()
                        .fill(Color(.systemGray6))
                        .opacity(0.3)
                )

                // Background Processing
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Background Processing")
                            .font(.body)
                            .foregroundColor(.primary)
                        Text("Manage transcription and summarization jobs")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    Spacer()
                    Button(action: {
                        showingBackgroundProcessing = true
                    }) {
                        HStack {
                            Text("Manage Jobs")
                            Image(systemName: "arrow.right")
                        }
                        .font(.caption)
                        .foregroundColor(.blue)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(
                            RoundedRectangle(cornerRadius: 6)
                                .fill(Color.blue.opacity(0.1))
                        )
                    }
                }
                .padding(.horizontal, 24)
                .padding(.vertical, 12)
                .background(
                    Rectangle()
                        .fill(Color(.systemGray6))
                        .opacity(0.3)
                )
                
                // Experimental On-Device AI Models
                VStack(spacing: 8) {
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Enable Experimental On-Device AI Models")
                                .font(.body)
                                .foregroundColor(.primary)
                            Text("Allow use of experimental models (LFM 2.5, Qwen3-1.7B, Qwen 4B for 8GB+). These models are unreliable and may produce empty summaries. For devices with <6GB RAM, this enables on-device AI with only small experimental models available.")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        Spacer()
                        Toggle("", isOn: $enableExperimentalModels)
                            .labelsHidden()
                    }
                }
                .padding(.horizontal, 24)
                .padding(.vertical, 12)
                .background(
                    Rectangle()
                        .fill(Color(.systemGray6))
                        .opacity(0.3)
                )
                
            }
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(Color(.systemBackground))
                    .shadow(color: Color.black.opacity(0.05), radius: 1, x: 0, y: 1)
                    .overlay(
                        RoundedRectangle(cornerRadius: 12)
                            .stroke(Color(.systemGray5), lineWidth: 0.5)
                    )
                    .opacity(0.3)
            )
        }
    }
    
    private var databaseMaintenanceSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button(action: {
                showingTroubleshootingWarning = true
            }) {
                HStack {
                    Image(systemName: "wrench.and.screwdriver")
                    Text("Advanced Troubleshooting")
                }
                .font(.caption)
                .foregroundColor(.white)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(Color.orange)
                )
            }
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 12)
        .background(
            Rectangle()
                .fill(Color(.systemGray6))
                .opacity(0.3)
        )
        .alert("Warning", isPresented: $showingTroubleshootingWarning) {
            Button("Cancel", role: .cancel) { }
            Button("OK") {
                showingDataMigration = true
            }
        } message: {
            Text("These tools can delete data. Use with caution.")
        }
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
            print("❌ Sync error: \(error)")
            await MainActor.run {
                errorHandler.handle(AppError.from(error, context: "iCloud Sync"), context: "Sync", showToUser: true)
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
