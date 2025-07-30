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
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color.black)
            }
        }
        .preferredColorScheme(.dark)
        .ignoresSafeArea(.keyboard, edges: .bottom)
        .onAppear {
            // Delay initialization to avoid race conditions
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                isInitialized = true
            }
        }
    }
}

#Preview {
    ContentView()
        .environment(\.managedObjectContext, PersistenceController.preview.container.viewContext)
}