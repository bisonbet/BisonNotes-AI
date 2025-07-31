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
    @State private var selectedTab = 0
    @State private var isInitialized = false
    @State private var initializationError: String?
    
    var body: some View {
        Group {
            if isInitialized {
                TabView(selection: $selectedTab) {
                    RecordingsView()
                        .environmentObject(recorderVM)
                        .tabItem {
                            Image(systemName: "mic.fill")
                            Text("Record")
                        }
                        .tag(0)
                    
                    SummariesView()
                        .environmentObject(recorderVM)
                        .tabItem {
                            Image(systemName: "doc.text.magnifyingglass")
                            Text("Summaries")
                        }
                        .tag(1)
                    
                    TranscriptsView()
                        .environmentObject(recorderVM)
                        .tabItem {
                            Image(systemName: "text.bubble.fill")
                            Text("Transcripts")
                        }
                        .tag(2)
                    
                    SettingsView()
                        .environmentObject(recorderVM)
                        .tabItem {
                            Image(systemName: "gearshape.fill")
                            Text("Settings")
                        }
                        .tag(3)
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
    }
    
    private func initializeApp() {
        // Use a longer delay to ensure the app is fully loaded
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            Task { @MainActor in
                do {
                    // Initialize the recorder view model on main thread
                    await recorderVM.initialize()
                    
                    // Add a small delay to ensure everything is properly set up
                    try await Task.sleep(nanoseconds: 200_000_000) // 0.2 seconds
                    
                    isInitialized = true
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
        .environment(\.managedObjectContext, PersistenceController.preview.container.viewContext)
}