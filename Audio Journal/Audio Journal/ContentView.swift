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
    
    var body: some View {
        TabView {
            RecordingsView()
                .environmentObject(recorderVM)
                .tabItem {
                    Image(systemName: "mic.fill")
                    Text("Record")
                }
            
            SummariesView()
                .environmentObject(recorderVM)
                .tabItem {
                    Image(systemName: "doc.text.magnifyingglass")
                    Text("Summaries")
                }
            
            TranscriptsView()
                .environmentObject(recorderVM)
                .tabItem {
                    Image(systemName: "text.bubble.fill")
                    Text("Transcripts")
                }
            
            SettingsView()
                .environmentObject(recorderVM)
                .tabItem {
                    Image(systemName: "gearshape.fill")
                    Text("Settings")
                }
        }
        .preferredColorScheme(.dark)
        .ignoresSafeArea(.keyboard, edges: .bottom)
    }
}

#Preview {
    ContentView()
}