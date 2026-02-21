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
    @State private var showingWhisperKitMigrationAlert = false
    @State private var showingWhisperKitSettings = false
    @State private var showingUnsupportedFileAlert = false
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
            NavigationView {
                OnDeviceLLMSettingsView()
            }
        }
        .alert("Transcription Engine Updated", isPresented: $showingWhisperKitMigrationAlert) {
            Button("Download Model") {
                showingWhisperKitSettings = true
            }
            Button("Later", role: .cancel) { }
        } message: {
            Text("Apple Transcription has been replaced with WhisperKit, a high-quality on-device transcription engine. Please download the WhisperKit model (~950MB) to continue transcribing audio.")
        }
        .sheet(isPresented: $showingWhisperKitSettings) {
            NavigationStack {
                WhisperKitSettingsView()
            }
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

            SummariesView()
                .environmentObject(recorderVM)
                .environmentObject(appCoordinator)
                .tabItem {
                    Image(systemName: "doc.text.magnifyingglass")
                    Text("Summaries")
                }
                .tag(1)

            TranscriptsView()
                .environmentObject(recorderVM)
                .environmentObject(appCoordinator)
                .tabItem {
                    Image(systemName: "text.bubble.fill")
                    Text("Transcripts")
                }
                .tag(2)

            SimpleSettingsView()
                .environmentObject(recorderVM)
                .environmentObject(appCoordinator)
                .tabItem {
                    Image(systemName: "gearshape.fill")
                    Text("Settings")
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
        print("✅ AppDelegate.recorderViewModel reference set")

        // Use a longer delay to ensure the app is fully loaded
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            Task { @MainActor in
                do {
                    // Check if Core Data has recordings, if not, trigger migration
                    let coreDataRecordings = appCoordinator.getAllRecordingsWithData()
                    if coreDataRecordings.isEmpty {
                        print("🔄 No recordings found in Core Data, triggering migration...")
                        let migrationManager = DataMigrationManager()
                        await migrationManager.performDataMigration()
                        print("✅ Migration completed")
                    } else {
                        // Core Data has existing recordings
                        
                        // Always run URL migration to ensure relative paths
                        print("🔄 Running URL migration to ensure relative paths...")
                        appCoordinator.syncRecordingURLs()
                        print("✅ URL migration completed")
                        
                        // Clean up any orphaned records and missing files
                        print("🔄 Cleaning up orphaned records...")
                        let cleanedCount = appCoordinator.cleanupOrphanedRecordings()
                        let fixedCount = appCoordinator.fixIncompletelyDeletedRecordings()
                        
                        // Also clean up recordings that reference missing files
                        print("🔄 Cleaning up recordings with missing files...")
                        let missingFileCount = appCoordinator.cleanupRecordingsWithMissingFiles()
                        
                        let totalCleaned = cleanedCount + fixedCount + missingFileCount
                        
                        if totalCleaned > 0 {
                            print("✅ Cleaned up \(totalCleaned) orphaned records (\(cleanedCount) orphaned, \(fixedCount) incomplete deletions, \(missingFileCount) missing files)")
                        }
                        
                        // Check if any recordings have transcripts in Core Data
                        let recordingsWithTranscripts = coreDataRecordings.filter { $0.transcript != nil }
                        if recordingsWithTranscripts.isEmpty {
                            print("🔄 Recordings found but no transcripts in Core Data, triggering migration...")
                            let migrationManager = DataMigrationManager()
                            await migrationManager.performDataMigration()
                            print("✅ Migration completed")
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

                    // Check if we need to show WhisperKit migration alert (Apple Transcription → WhisperKit)
                    if !isFirstLaunch && UserDefaults.standard.bool(forKey: "showWhisperKitMigrationSettings") {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                            showingWhisperKitMigrationAlert = true
                            UserDefaults.standard.removeObject(forKey: "showWhisperKitMigrationSettings")
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
            print("📱 ContentView: Action button recording requested!")
            if isInitialized {
                print("📱 ContentView: App is initialized, triggering recording immediately")
                triggerActionButtonRecording()
            } else {
                print("📱 ContentView: App not initialized yet, setting pending flag")
                pendingActionButtonRecording = true
            }
        } else {
        }
    }

    private func triggerActionButtonRecording() {
        print("🎙️ ContentView: Triggering action button recording")
        selectedTab = 0

        DispatchQueue.main.async {
            print("🎙️ ContentView: On main queue, current recording state: \(recorderVM.isRecording)")
            if !recorderVM.isRecording {
                print("🎙️ ContentView: Starting recording...")
                recorderVM.startRecording()
            } else {
                print("🎙️ ContentView: Already recording, skipping")
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