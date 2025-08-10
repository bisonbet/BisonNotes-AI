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
    @EnvironmentObject var appCoordinator: AppDataCoordinator
    @State private var selectedTab = 0
    @State private var isInitialized = false
    @State private var initializationError: String?
    @State private var isFirstLaunch = false
    @State private var showingLocationPermission = false
    
    var body: some View {
        Group {
            if isInitialized {
            if isFirstLaunch {
                SimpleSettingsView()
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
                    Button("Enable") {
                        recorderVM.locationManager.requestLocationPermission()
                    }
                    Button("Skip") {
                        // Do nothing, just dismiss
                    }
                } message: {
                    Text("Location services help add context to your recordings by capturing where they were made. This can be useful for organizing and remembering your audio notes.")
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
    }
    
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
}

#Preview {
    ContentView()
        .environmentObject(AppDataCoordinator())
        .environment(\.managedObjectContext, PersistenceController.preview.container.viewContext)
}