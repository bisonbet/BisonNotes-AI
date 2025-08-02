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
    @State private var showingEngineChangePrompt = false
    @State private var previousEngine = ""
    @State private var showingTranscriptionSettings = false
    @State private var showingAISettings = false
    @State private var showingPerformanceView = false
    @State private var showingClearSummariesAlert = false
    @State private var showingCleanupAlert = false
    @State private var isPerformingCleanup = false
    @State private var cleanupResults: CleanupResults?
    @State private var showingBackgroundProcessing = false
    @State private var showingDataMigration = false

    @State private var selectedAudioQuality: AudioQuality = .regular
    @AppStorage("SelectedAIEngine") private var selectedAIEngine: String = "Enhanced Apple Intelligence"
    
    init() {
        // Initialize regeneration manager with the coordinator's registry manager
        self._regenerationManager = StateObject(wrappedValue: SummaryRegenerationManager(
            summaryManager: SummaryManager.shared,
            transcriptManager: TranscriptManager.shared,
            appCoordinator: AppDataCoordinator()
        ))
        self.iCloudManager = iCloudStorageManager()
        
        // Load saved audio quality setting
        if let savedQuality = UserDefaults.standard.string(forKey: "SelectedAudioQuality"),
           let quality = AudioQuality(rawValue: savedQuality) {
            self._selectedAudioQuality = State(initialValue: quality)
        } else {
            self._selectedAudioQuality = State(initialValue: .regular)
        }
    }
    
    var body: some View {
        NavigationView {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    headerSection
                    microphoneSection
                    audioQualitySection
                    aiEngineSection
                    transcriptionSection
                    summarySection
                    fileManagementSection
                    advancedSection
                    databaseMaintenanceSection

                    
                    Spacer(minLength: 40)
                }
            }
            .navigationBarHidden(true)
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
        }

        .alert("Cleanup Orphaned Data", isPresented: $showingCleanupAlert) {
            Button("Cancel") {
                showingCleanupAlert = false
            }
            Button("Clean Up") {
                Task {
                    await performCleanup()
                }
                showingCleanupAlert = false
            }
        } message: {
            Text("This will remove summaries and transcripts for recordings that no longer exist. This action cannot be undone.")
        }
    }
    
    private var headerSection: some View {
        Text("Settings")
            .font(.largeTitle)
            .fontWeight(.bold)
            .foregroundColor(.primary)
            .padding(.top, 20)
            .padding(.horizontal, 24)
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
    
    private var audioQualitySection: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Audio Quality")
                .font(.headline)
                .foregroundColor(.primary)
                .padding(.horizontal, 24)
            
            VStack(alignment: .leading, spacing: 8) {
                Picker("Audio Quality", selection: $selectedAudioQuality) {
                    ForEach(AudioQuality.allCases, id: \.self) { quality in
                        HStack {
                            Text(getQualityDisplayName(quality))
                                .font(.body)
                                .fontWeight(.medium)
                            
                            Spacer()
                            
                            Text(getQualityRecommendation(quality))
                                .font(.caption)
                                .foregroundColor(getQualityColor(quality))
                                .padding(.horizontal, 8)
                                .padding(.vertical, 2)
                                .background(
                                    RoundedRectangle(cornerRadius: 4)
                                        .fill(getQualityColor(quality).opacity(0.1))
                                )
                        }
                        .tag(quality)
                    }
                }
                .pickerStyle(MenuPickerStyle())
                .onChange(of: selectedAudioQuality) { _, newValue in
                    UserDefaults.standard.set(newValue.rawValue, forKey: "SelectedAudioQuality")
                }
                
                // Quality description
                VStack(alignment: .leading, spacing: 4) {
                    Text(getQualityDisplayName(selectedAudioQuality))
                        .font(.body)
                        .fontWeight(.medium)
                        .foregroundColor(.primary)
                    
                    Text(getQualityDescription(selectedAudioQuality))
                        .font(.caption)
                        .foregroundColor(.secondary)
                    
                    Text("File size: ~\(getQualityFileSize(selectedAudioQuality)) per hour")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
                .padding(.horizontal, 24)
                .padding(.vertical, 12)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color(.systemGray6))
                )
            }
            .padding(.horizontal, 24)
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
            
            Button(action: {
                showingPerformanceView = true
            }) {
                HStack {
                    Text("Engine Performance")
                    Spacer()
                    Image(systemName: "chart.line.uptrend.xyaxis")
                }
                .padding(.horizontal, 24)
                .padding(.vertical, 12)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color.green.opacity(0.1))
                )
                .foregroundColor(.green)
            }
            .padding(.horizontal, 24)
            .disabled(true) // Disable until PerformanceView is implemented
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
                Text(TranscriptionEngine(rawValue: UserDefaults.standard.string(forKey: "selectedTranscriptionEngine") ?? TranscriptionEngine.appleIntelligence.rawValue)?.rawValue ?? "Apple Intelligence")
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
    
    private var summarySection: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("iCloud Storage")
                .font(.headline)
                .foregroundColor(.primary)
                .padding(.horizontal, 24)
            
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Sync Summaries to iCloud")
                            .font(.body)
                            .foregroundColor(.primary)
                        Text("Save summaries to iCloud for access across devices")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    Spacer()
                    Toggle("", isOn: $iCloudManager.isEnabled)
                        .labelsHidden()
                }
                
                // Sync Status
                HStack {
                    Text("Status:")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    
                    HStack(spacing: 4) {
                        let statusColor: Color = {
                            switch iCloudManager.syncStatus {
                            case .idle, .completed:
                                return .green
                            case .syncing:
                                return .orange
                            case .failed:
                                return .red
                            }
                        }()
                        
                        Circle()
                            .fill(statusColor)
                            .frame(width: 8, height: 8)
                        
                        Text(iCloudManager.syncStatus.description)
                            .font(.caption)
                            .foregroundColor(statusColor)
                        
                        if case .syncing = iCloudManager.syncStatus {
                            ProgressView()
                                .scaleEffect(0.6)
                                .padding(.leading, 4)
                        }
                    }
                }
                
                // Network Status
                HStack {
                    Text("Network:")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    
                    HStack(spacing: 4) {
                        let networkColor: Color = {
                            switch iCloudManager.networkStatus {
                            case .available:
                                return .green
                            case .limited:
                                return .orange
                            case .unavailable:
                                return .red
                            }
                        }()
                        
                        let networkText: String = {
                            switch iCloudManager.networkStatus {
                            case .available:
                                return "Available"
                            case .limited:
                                return "Limited"
                            case .unavailable:
                                return "Unavailable"
                            }
                        }()
                        
                        Circle()
                            .fill(networkColor)
                            .frame(width: 8, height: 8)
                        
                        Text(networkText)
                            .font(.caption)
                            .foregroundColor(networkColor)
                    }
                }
                
                // Last Sync Date
                if let lastSync = iCloudManager.lastSyncDate {
                    HStack {
                        Text("Last Sync:")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        Text(lastSync, style: .relative)
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
                
                // Pending Sync Count
                if iCloudManager.pendingSyncCount > 0 {
                    HStack {
                        Text("Pending:")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        Text("\(iCloudManager.pendingSyncCount) items")
                            .font(.caption)
                            .foregroundColor(.orange)
                    }
                }
                
                // Manual Sync Button
                if iCloudManager.isEnabled {
                    Button(action: {
                        Task {
                            await syncAllSummaries()
                        }
                    }) {
                        HStack {
                            Image(systemName: "icloud.and.arrow.up")
                            Text("Sync Now")
                        }
                        .font(.caption)
                        .foregroundColor(.white)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(
                            RoundedRectangle(cornerRadius: 6)
                                .fill(Color.blue)
                        )
                    }
                    .disabled(iCloudManager.syncStatus == .syncing)
                }
                
                // Error Display
                if let error = iCloudManager.lastError {
                    Text("Error: \(error)")
                        .font(.caption)
                        .foregroundColor(.red)
                        .padding(.top, 4)
                }
                
                // Conflict Resolution
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
    
    private var fileManagementSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Data Management")
                .font(.headline)
                .foregroundColor(.primary)
                .padding(.horizontal, 24)
            
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Cleanup Orphaned Data")
                            .font(.body)
                            .foregroundColor(.primary)
                        Text("Remove summaries and transcripts for deleted recordings")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    Spacer()
                    Button(action: {
                        showingCleanupAlert = true
                    }) {
                        HStack {
                            if isPerformingCleanup {
                                ProgressView()
                                    .scaleEffect(0.8)
                                    .padding(.trailing, 4)
                            }
                            Text(isPerformingCleanup ? "Cleaning..." : "Clean Up")
                        }
                        .font(.caption)
                        .foregroundColor(.white)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(
                            RoundedRectangle(cornerRadius: 6)
                                .fill(isPerformingCleanup ? Color.gray : Color.orange)
                        )
                    }
                    .disabled(isPerformingCleanup)
                }
                
                if let results = cleanupResults {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Last Cleanup Results:")
                            .font(.caption)
                            .fontWeight(.medium)
                            .foregroundColor(.secondary)
                        
                        Text("• Removed \(results.orphanedSummaries) orphaned summaries")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        
                        Text("• Removed \(results.orphanedTranscripts) orphaned transcripts")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        
                        Text("• Freed \(results.freedSpaceMB, specifier: "%.1f") MB of space")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    .padding(.top, 8)
                }
                
                // Registry Reset Button - REMOVED (too dangerous)
                // Users can delete and reinstall the app for a full reset
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
    
    private var advancedSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Advanced Settings")
                .font(.headline)
                .foregroundColor(.primary)
                .padding(.horizontal, 24)
            
            VStack(alignment: .leading, spacing: 8) {
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
            }
        }
    }
    
    private var databaseMaintenanceSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Database Maintenance")
                .font(.headline)
                .foregroundColor(.primary)
                .padding(.horizontal, 24)
            
            VStack(alignment: .leading, spacing: 8) {
                Button(action: {
                    showingDataMigration = true
                }) {
                    HStack {
                        Image(systemName: "arrow.triangle.2.circlepath")
                        Text("Fix Database")
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
    
    // MARK: - Cleanup Functions
    
    private func performCleanup() async {
        isPerformingCleanup = true
        
        do {
            let results = try await cleanupOrphanedData()
            await MainActor.run {
                self.cleanupResults = results
                self.isPerformingCleanup = false
            }
        } catch {
            await MainActor.run {
                self.isPerformingCleanup = false
                self.errorHandler.handle(AppError.from(error, context: "Data Cleanup"), context: "Cleanup", showToUser: true)
            }
        }
    }
    
    private func cleanupOrphanedData() async throws -> CleanupResults {
        print("🧹 Starting orphaned data cleanup...")
        
        // Get all recordings from Core Data
        let allRecordings = appCoordinator.coreDataManager.getAllRecordings()
        print("📁 Found \(allRecordings.count) recordings in Core Data")
        
        // Get all transcripts and summaries from Core Data
        let allTranscripts = appCoordinator.coreDataManager.getAllTranscripts()
        let allSummaries = appCoordinator.coreDataManager.getAllSummaries()
        
        print("📊 Found \(allSummaries.count) stored summaries and \(allTranscripts.count) stored transcripts")
        
        var orphanedSummaries = 0
        var orphanedTranscripts = 0
        var freedSpaceBytes: Int64 = 0
        
        // Create a set of valid recording IDs for quick lookup
        let validRecordingIds = Set(allRecordings.compactMap { $0.id })
        
        print("🔍 Valid recording IDs: \(validRecordingIds.count)")
        
        // Check for orphaned summaries
        for summary in allSummaries {
            let recordingId = summary.recordingId
            
            // Check if the recording ID exists in Core Data
            let hasValidID = recordingId != nil && validRecordingIds.contains(recordingId!)
            
            if !hasValidID {
                print("🗑️ Found orphaned summary for recording ID: \(recordingId?.uuidString ?? "nil")")
                print("   ID exists: \(hasValidID)")
                
                // Delete the orphaned summary
                appCoordinator.coreDataManager.deleteSummary(id: summary.id)
                orphanedSummaries += 1
                
                // Calculate freed space (rough estimate)
                freedSpaceBytes += Int64(summary.summary?.count ?? 0 * 2) // Approximate UTF-8 bytes
            }
        }
        
        // Check for orphaned transcripts
        for transcript in allTranscripts {
            let recordingId = transcript.recordingId
            
            // Check if the recording ID exists in Core Data
            let hasValidID = recordingId != nil && validRecordingIds.contains(recordingId!)
            
            if !hasValidID {
                print("🗑️ Found orphaned transcript for recording ID: \(recordingId?.uuidString ?? "nil")")
                print("   ID exists: \(hasValidID)")
                
                // Delete the orphaned transcript
                appCoordinator.coreDataManager.deleteTranscript(id: transcript.id)
                orphanedTranscripts += 1
                
                // Calculate freed space
                let transcriptText = transcript.segments ?? ""
                freedSpaceBytes += Int64(transcriptText.count * 2) // Approximate UTF-8 bytes
            } else {
                // Log when we find a transcript that's actually valid
                print("✅ Found valid transcript for recording ID: \(recordingId?.uuidString ?? "nil")")
            }
        }
        
        // Check for transcripts where the recording file doesn't exist on disk
        for transcript in allTranscripts {
            guard let recordingId = transcript.recordingId,
                  let recording = appCoordinator.coreDataManager.getRecording(id: recordingId),
                  let recordingURLString = recording.recordingURL,
                  let recordingURL = URL(string: recordingURLString) else {
                continue
            }
            
            // Check if the recording file exists on disk
            let fileExists = FileManager.default.fileExists(atPath: recordingURL.path)
            
            // Check if the recording exists in Core Data
            let hasValidID = validRecordingIds.contains(recordingId)
            
            // Only remove if the file doesn't exist AND it's not in Core Data
            if !fileExists && !hasValidID {
                print("🗑️ Found transcript for non-existent recording file: \(recordingURL.lastPathComponent)")
                print("   File exists: \(fileExists), ID in Core Data: \(hasValidID)")
                
                // Delete the orphaned transcript
                appCoordinator.coreDataManager.deleteTranscript(id: transcript.id)
                orphanedTranscripts += 1
                
                // Calculate freed space
                let transcriptText = transcript.segments ?? ""
                freedSpaceBytes += Int64(transcriptText.count * 2) // Approximate UTF-8 bytes
            } else if !fileExists {
                // Log when file doesn't exist but recording is in Core Data
                print("⚠️  File not found on disk but recording exists in Core Data: \(recordingURL.lastPathComponent)")
                print("   File exists: \(fileExists), ID in Core Data: \(hasValidID)")
            }
        }
        
        let freedSpaceMB = Double(freedSpaceBytes) / (1024 * 1024)
        
        print("✅ Cleanup complete:")
        print("   • Removed \(orphanedSummaries) orphaned summaries")
        print("   • Removed \(orphanedTranscripts) orphaned transcripts")
        print("   • Freed \(String(format: "%.1f", freedSpaceMB)) MB of space")
        
        return CleanupResults(
            orphanedSummaries: orphanedSummaries,
            orphanedTranscripts: orphanedTranscripts,
            freedSpaceMB: freedSpaceMB
        )
    }
    
    // MARK: - iCloud Sync Functions
    
    private func syncAllSummaries() async {
        do {
            // TODO: Implement iCloud sync with new Core Data system
            let allSummaries: [EnhancedSummaryData] = [] // Placeholder
            try await iCloudManager.performBidirectionalSync(localSummaries: allSummaries)
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
    

}

// MARK: - Supporting Structures

struct CleanupResults {
    let orphanedSummaries: Int
    let orphanedTranscripts: Int
    let freedSpaceMB: Double
}

// MARK: - Audio Quality Helper Functions

extension SettingsView {
    func getQualityDisplayName(_ quality: AudioQuality) -> String {
        switch quality {
        case .regular:
            return "Regular Quality"
        case .high:
            return "High Quality"
        case .maximum:
            return "Maximum Quality"
        }
    }
    
    func getQualityRecommendation(_ quality: AudioQuality) -> String {
        switch quality {
        case .regular:
            return "Good for voice"
        case .high:
            return "Recommended"
        case .maximum:
            return "High fidelity"
        }
    }
    
    func getQualityColor(_ quality: AudioQuality) -> Color {
        switch quality {
        case .regular:
            return .orange
        case .high:
            return .green
        case .maximum:
            return .blue
        }
    }
    
    func getQualityDescription(_ quality: AudioQuality) -> String {
        switch quality {
        case .regular:
            return "Good for voice recordings with smaller file sizes."
        case .high:
            return "Default quality, balanced for most recordings."
        case .maximum:
            return "High fidelity for professional recordings."
        }
    }
    
    func getQualityFileSize(_ quality: AudioQuality) -> String {
        switch quality {
        case .regular:
            return "29 MB"
        case .high:
            return "58 MB"
        case .maximum:
            return "87 MB"
        }
    }
}