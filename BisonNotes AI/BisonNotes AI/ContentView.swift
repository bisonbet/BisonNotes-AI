//
//  ContentView.swift
//  Audio Journal
//
//  Created by Tim Champ on 7/26/25.
//  Refactored on 7/28/25.
//

import SwiftUI

struct ContentView: View {
    @StateObject private var recorderVM = AudioRecorderViewModel()
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @EnvironmentObject var appCoordinator: AppDataCoordinator
    @State private var selectedTab = 0
    @State private var isInitialized = false
    @State private var initializationError: String?
    @State private var isFirstLaunch = false
    @State private var showingLocationPermission = false
    @State private var pendingActionButtonRecording = false
    @State private var showingAppleIntelligenceMigrationAlert = false
    @State private var showingOnDeviceLLMSettings = false
    @State private var showingWhisperKitRemovedAlert = false
    @State private var showingWhisperKitSwitchedAlert = false
    @State private var showingParakeetMigrationAlert = false
    @State private var showingFluidAudioSettings = false
    @State private var showingUnsupportedFileAlert = false
    @State private var showingCrashReport = false
    @StateObject private var downloadMonitor = OnDeviceAIDownloadMonitor.shared
    @State private var showSplash = true

    var body: some View {
        ZStack {
            Group {
                if isInitialized {
                    if isFirstLaunch {
                        firstLaunchView
                    } else {
                        mainContentView
                    }
                } else {
                    loadingView
                }
            }

            if showSplash {
                SplashView(isActive: $showSplash)
                    .transition(.opacity)
                    .zIndex(1)
            }
        }
        .preferredColorScheme(horizontalSizeClass == .compact ? .dark : nil)
        .ignoresSafeArea(.keyboard, edges: .bottom)
        .onAppear {
            DispatchQueue.main.async {
                initializeApp()
            }
            // Check if previous session crashed
            if AppLog.shared.previousSessionCrashed {
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                    showingCrashReport = true
                }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("FirstSetupCompleted"))) { _ in
            isFirstLaunch = false
        }
        .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("RequestLocationPermission"))) { _ in
            showingLocationPermission = true
            UserDefaults.standard.set(true, forKey: "hasAskedLocationPermission")
        }
        .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("SwitchToRecordTabForImport"))) { _ in
            selectedTab = 0
        }
        .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("UnsupportedFileTypeFromShare"))) { _ in
            showingUnsupportedFileAlert = true
        }
        .onChange(of: scenePhase) { _, newPhase in
            guard newPhase == .active else { return }
            handleActionButtonLaunchIfNeeded()
        }
        .onChange(of: isInitialized) { _, initialized in
            if initialized && pendingActionButtonRecording {
                pendingActionButtonRecording = false
                triggerActionButtonRecording()
            }
        }
        .task {
            handleActionButtonLaunchIfNeeded()
        }
    }

    // MARK: - Extracted Sub-Views

    private var firstLaunchView: some View {
        SimpleSettingsView()
            .environmentObject(recorderVM)
            .environmentObject(appCoordinator)
            .onAppear {
                UserDefaults.standard.set(true, forKey: "hasCompletedFirstSetup")
            }
    }

    @ViewBuilder
    private var mainContentView: some View {
        Group {
            if horizontalSizeClass == .compact {
                tabContentView
            } else {
                AdaptiveNavigationView()
                    .environmentObject(recorderVM)
                    .environmentObject(appCoordinator)
            }
        }
        .alert("Enable Location Services", isPresented: $showingLocationPermission) {
            Button("Continue") {
                recorderVM.locationManager.requestLocationPermission()
            }
        } message: {
            Text("We use your location to log where each recording happens, helping you organize and revisit your audio notes with helpful context.")
        }
        .alert("Apple Intelligence Has Been Removed", isPresented: $showingAppleIntelligenceMigrationAlert) {
            Button("Configure On-Device AI") {
                showingOnDeviceLLMSettings = true
            }
        } message: {
            Text("Apple Intelligence has been removed from the app. Your settings have been automatically updated to use On-Device AI, which provides similar functionality. Please download an AI model to continue using on-device AI processing.")
        }
        .sheet(isPresented: $showingOnDeviceLLMSettings) {
            #if targetEnvironment(macCatalyst)
            VStack(spacing: 0) {
                HStack {
                    Text("On-Device AI").font(.headline)
                    Spacer()
                    Button("Done") { showingOnDeviceLLMSettings = false }.buttonStyle(.bordered)
                }
                .padding(.horizontal, 16).padding(.vertical, 10)
                Divider()
                OnDeviceLLMSettingsView()
            }
            #else
            NavigationStack {
                OnDeviceLLMSettingsView()
            }
            #endif
        }
        .alert("Switched to Parakeet", isPresented: $showingWhisperKitSwitchedAlert) {
            Button("OK") { }
        } message: {
            Text("WhisperKit has been removed. We've automatically switched you to Parakeet, which is already downloaded and ready to use.")
        }
        .alert("On-Device Transcription Updated", isPresented: $showingWhisperKitRemovedAlert) {
            Button("Download Parakeet Model") {
                showingFluidAudioSettings = true
            }
            Button("Later", role: .cancel) { }
        } message: {
            Text("WhisperKit has been removed and replaced by Parakeet, our faster and more accurate on-device transcription engine. Your WhisperKit model files have been deleted to free up space. Please download the Parakeet model (~250 MB) to continue using on-device transcription.")
        }
        .alert("Transcription Engine Updated", isPresented: $showingParakeetMigrationAlert) {
            Button("Download Model") {
                showingFluidAudioSettings = true
            }
            Button("Later", role: .cancel) { }
        } message: {
            Text("Your transcription engine has been upgraded to Parakeet, a fast and accurate on-device engine. Please download the Parakeet model (~250MB) to continue transcribing audio.")
        }
        .sheet(isPresented: $showingFluidAudioSettings) {
            #if targetEnvironment(macCatalyst)
            VStack(spacing: 0) {
                HStack {
                    Text("On Device Transcription").font(.headline)
                    Spacer()
                    Button("Done") { showingFluidAudioSettings = false }.buttonStyle(.bordered)
                }
                .padding(.horizontal, 16).padding(.vertical, 10)
                Divider()
                FluidAudioSettingsView()
            }
            #else
            NavigationStack {
                FluidAudioSettingsView()
            }
            #endif
        }
        .alert("Download Complete", isPresented: $downloadMonitor.showingCompletionAlert) {
            Button("OK") {
                downloadMonitor.reset()
            }
        } message: {
            Text(downloadMonitor.completionMessage)
        }
        .alert("Unsupported File Type", isPresented: $showingUnsupportedFileAlert) {
            Button("OK", role: .cancel) { }
        } message: {
            Text("This file type cannot be imported as a recording or transcript.")
        }
        .alert("Unexpected Shutdown", isPresented: $showingCrashReport) {
            Button("Send Report") {
                Task {
                    do {
                        let url = try await LogExporter.exportLogs()
                        LogEmailPresenter.shared.presentLogEmail(logFileURL: url) {}
                    } catch {
                        AppLog.shared.error("Failed to generate crash report: \(error.localizedDescription)", category: .general)
                    }
                }
            }
            Button("Dismiss", role: .cancel) { }
        } message: {
            Text("It looks like BisonNotes AI didn't shut down properly last time. Would you like to send a diagnostic report to help us fix this?")
        }
    }

    private var tabContentView: some View {
        TabView(selection: $selectedTab) {
            RecordingsView()
                .environmentObject(recorderVM)
                .environmentObject(appCoordinator)
                .tabItem {
                    Image(systemName: "mic.fill")
                    Text("Record")
                }
                .tag(0)

            TranscriptsView()
                .environmentObject(recorderVM)
                .environmentObject(appCoordinator)
                .tabItem {
                    Image(systemName: "text.bubble.fill")
                    Text("Transcripts")
                }
                .tag(1)

            SummariesView()
                .environmentObject(recorderVM)
                .environmentObject(appCoordinator)
                .tabItem {
                    Image(systemName: "doc.text.magnifyingglass")
                    Text("Summaries")
                }
                .tag(2)

            SimpleSettingsView()
                .environmentObject(recorderVM)
                .environmentObject(appCoordinator)
                .tabItem {
                    Image(systemName: "gearshape.fill")
                    Text("Setup")
                }
                .tag(3)
        }
    }

    private var loadingView: some View {
        VStack {
            ProgressView()
                .scaleEffect(1.5)
            Text("Loading...")
                .padding(.top)

            if let error = initializationError {
                Text("Error: \(error)")
                    .foregroundColor(.red)
                    .font(.caption)
                    .padding(.top)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(red: 0.039, green: 0.086, blue: 0.157))
    }

    @MainActor
    private func initializeApp() {
        // Check if this is first launch
        let hasCompletedSetup = UserDefaults.standard.bool(forKey: "hasCompletedFirstSetup")
        isFirstLaunch = !hasCompletedSetup

        // Phase 6: Set AppDelegate reference to AudioRecorderViewModel for notification handling
        AppDelegate.recorderViewModel = recorderVM
        AppLog.shared.log("AppDelegate.recorderViewModel reference set", category: .general)

        // Use a longer delay to ensure the app is fully loaded
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            Task { @MainActor in
                do {
                    // Check if Core Data has recordings, if not, trigger migration
                    let coreDataRecordings = appCoordinator.getAllRecordingsWithData()
                    if coreDataRecordings.isEmpty {
                        AppLog.shared.log("No recordings found in Core Data, triggering migration...", category: .general)
                        let migrationManager = DataMigrationManager()
                        await migrationManager.performDataMigration()
                        AppLog.shared.log("Migration completed", category: .general)
                    } else {
                        // Core Data has existing recordings
                        
                        // Always run URL migration to ensure relative paths
                        AppLog.shared.log("Running URL migration to ensure relative paths...", level: .debug, category: .general)
                        appCoordinator.syncRecordingURLs()
                        AppLog.shared.log("URL migration completed", category: .general)

                        // Clean up any orphaned records and missing files
                        AppLog.shared.log("Cleaning up orphaned records...", level: .debug, category: .general)
                        let cleanedCount = appCoordinator.cleanupOrphanedRecordings()
                        let fixedCount = appCoordinator.fixIncompletelyDeletedRecordings()
                        
                        // Also clean up recordings that reference missing files
                        AppLog.shared.log("Cleaning up recordings with missing files...", level: .debug, category: .general)
                        let missingFileCount = appCoordinator.cleanupRecordingsWithMissingFiles()
                        
                        let totalCleaned = cleanedCount + fixedCount + missingFileCount
                        
                        if totalCleaned > 0 {
                            AppLog.shared.log("Cleaned up \(totalCleaned) orphaned records (\(cleanedCount) orphaned, \(fixedCount) incomplete deletions, \(missingFileCount) missing files)", category: .general)
                        }
                        
                        // Check if any recordings have transcripts in Core Data
                        let recordingsWithTranscripts = coreDataRecordings.filter { $0.transcript != nil }
                        if recordingsWithTranscripts.isEmpty {
                            AppLog.shared.log("Recordings found but no transcripts in Core Data, triggering migration...", category: .general)
                            let migrationManager = DataMigrationManager()
                            await migrationManager.performDataMigration()
                            AppLog.shared.log("Migration completed", category: .general)
                        } else {
                            // Core Data has existing transcripts, no migration needed
                        }
                    }
                    
                    // Initialize the recorder view model on main thread
                    await recorderVM.initialize()
                    
                    // Set the app coordinator for the recorder
                    recorderVM.setAppCoordinator(appCoordinator)
                    
                    // Set up the enhanced file manager with the coordinator
                    EnhancedFileManager.shared.setCoordinator(appCoordinator)
                    
                    // Add a small delay to ensure everything is properly set up
                    try await Task.sleep(nanoseconds: 200_000_000) // 0.2 seconds
                    
                    isInitialized = true
                    
                    // Show location permission prompt after initialization (only if not first launch)
                    if !isFirstLaunch && !UserDefaults.standard.bool(forKey: "hasAskedLocationPermission") {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                            showingLocationPermission = true
                            UserDefaults.standard.set(true, forKey: "hasAskedLocationPermission")
                        }
                    }
                    
                    // Check if we need to show Apple Intelligence migration alert
                    if !isFirstLaunch && UserDefaults.standard.bool(forKey: "showAppleIntelligenceMigrationAlert") {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                            showingAppleIntelligenceMigrationAlert = true
                            UserDefaults.standard.removeObject(forKey: "showAppleIntelligenceMigrationAlert")
                        }
                    }

                    // Check if we need to show Parakeet migration alert (Apple Transcription → Parakeet)
                    if !isFirstLaunch && UserDefaults.standard.bool(forKey: "showParakeetMigrationSettings") {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                            showingParakeetMigrationAlert = true
                            UserDefaults.standard.removeObject(forKey: "showParakeetMigrationSettings")
                        }
                    }

                    // Show appropriate alert for former WhisperKit users
                    if !isFirstLaunch && UserDefaults.standard.bool(forKey: "showWhisperKitSwitchedToParakeet") {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                            showingWhisperKitSwitchedAlert = true
                            UserDefaults.standard.removeObject(forKey: "showWhisperKitSwitchedToParakeet")
                        }
                    } else if !isFirstLaunch && UserDefaults.standard.bool(forKey: "showWhisperKitRemovedAlert") {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                            showingWhisperKitRemovedAlert = true
                            UserDefaults.standard.removeObject(forKey: "showWhisperKitRemovedAlert")
                        }
                    }
                } catch {
                    initializationError = error.localizedDescription
                    isInitialized = true // Still show the app even if there's an error
                }
            }
        }
    }

    private func handleActionButtonLaunchIfNeeded() {
        if ActionButtonLaunchManager.consumeRecordingRequest() {
            AppLog.shared.log("Action button recording requested", level: .debug, category: .general)
            if isInitialized {
                AppLog.shared.log("App is initialized, triggering recording immediately", level: .debug, category: .general)
                triggerActionButtonRecording()
            } else {
                AppLog.shared.log("App not initialized yet, setting pending flag", level: .debug, category: .general)
                pendingActionButtonRecording = true
            }
        } else {
        }
    }

    private func triggerActionButtonRecording() {
        AppLog.shared.log("Triggering action button recording", level: .debug, category: .general)
        selectedTab = 0

        DispatchQueue.main.async {
            AppLog.shared.log("Action button: isRecording=\(recorderVM.isRecording)", level: .debug, category: .general)
            if !recorderVM.isRecording {
                recorderVM.startRecording()
            }
        }
    }
}

#Preview {
    ContentView()
        .environmentObject(AppDataCoordinator())
        .environmentObject(FileImportManager())
        .environmentObject(TranscriptImportManager())
        .environment(\.managedObjectContext, PersistenceController.preview.container.viewContext)
}
