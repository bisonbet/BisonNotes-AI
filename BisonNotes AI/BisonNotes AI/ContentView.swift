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
    @EnvironmentObject var appCoordinator: AppDataCoordinator
    @State private var selectedTab = 0
    @State private var isInitialized = false
    @State private var initializationError: String?
    @State private var isFirstLaunch = false
    @State private var showingLocationPermission = false
    @State private var pendingActionButtonRecording = false
    
    var body: some View {
        Group {
            if isInitialized {
            if isFirstLaunch {
                SimpleSettingsView()
                    .environmentObject(recorderVM)
                    .environmentObject(appCoordinator)
                    .onAppear {
                        // Mark first launch as complete when they finish setup
                        UserDefaults.standard.set(true, forKey: "hasCompletedFirstSetup")
                    }
            } else {
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
                .alert("Enable Location Services", isPresented: $showingLocationPermission) {
                    Button("Continue") {
                        recorderVM.locationManager.requestLocationPermission()
                    }
                } message: {
                    Text("We use your location to log where each recording happens, helping you organize and revisit your audio notes with helpful context.")
                }
            }
        } else {
            // Loading state
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
                .background(Color.black)
            }
        }
        .preferredColorScheme(.dark)
        .ignoresSafeArea(.keyboard, edges: .bottom)
        .onAppear {
            // Ensure initialization happens on main thread
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
        .onChange(of: scenePhase) { newPhase in
            guard newPhase == .active else { return }
            handleActionButtonLaunchIfNeeded()
        }
        .onChange(of: isInitialized) { initialized in
            if initialized && pendingActionButtonRecording {
                pendingActionButtonRecording = false
                triggerActionButtonRecording()
            }
        }
        .task {
            handleActionButtonLaunchIfNeeded()
        }
    }

    @MainActor
    private func initializeApp() {
        // Check if this is first launch
        let hasCompletedSetup = UserDefaults.standard.bool(forKey: "hasCompletedFirstSetup")
        isFirstLaunch = !hasCompletedSetup
        
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
                        } else {
                            print("ℹ️ No orphaned records found")
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
                } catch {
                    initializationError = error.localizedDescription
                    isInitialized = true // Still show the app even if there's an error
                }
            }
        }
    }

    private func handleActionButtonLaunchIfNeeded() {
        if ActionButtonLaunchManager.consumeRecordingRequest() {
            if isInitialized {
                triggerActionButtonRecording()
            } else {
                pendingActionButtonRecording = true
            }
        }
    }

    private func triggerActionButtonRecording() {
        selectedTab = 0

        DispatchQueue.main.async {
            if !recorderVM.isRecording {
                recorderVM.startRecording()
            }
        }
    }
}

#Preview {
    ContentView()
        .environmentObject(AppDataCoordinator())
        .environment(\.managedObjectContext, PersistenceController.preview.container.viewContext)
}