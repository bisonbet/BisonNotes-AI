//
//  TranscriptionSettingsView.swift
//  Audio Journal
//
//  Settings view for transcription configuration
//

import SwiftUI

// Note: TranscriptionEngine enum is defined in ContentView.swift


struct TranscriptionSettingsView: View {
    @EnvironmentObject var recorderVM: AudioRecorderViewModel
    @AppStorage("maxChunkDuration") private var maxChunkDuration: Double = 300 // 5 minutes
    @AppStorage("maxTranscriptionTime") private var maxTranscriptionTime: Double = 600 // 10 minutes
    @AppStorage("chunkOverlap") private var chunkOverlap: Double = 2.0 // 2 seconds
    @AppStorage("showTranscriptionProgress") private var showTranscriptionProgress: Bool = true
    
    @State private var showingAWSSettings = false
    @State private var showingWhisperSettings = false
    @State private var showingOpenAISettings = false
    @Environment(\.dismiss) private var dismiss
    
    var body: some View {
        NavigationView {
            Form {
                Section {
                    Picker("Engine", selection: $recorderVM.selectedTranscriptionEngine) {
                        ForEach(TranscriptionEngine.allCases.filter { $0.isAvailable }, id: \.rawValue) { engine in
                            VStack(alignment: .leading) {
                                Text(engine.rawValue)
                                Text(engine.description)
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                            .tag(engine)
                        }
                    }
                    .pickerStyle(.navigationLink)
                    
                    if recorderVM.selectedTranscriptionEngine == .awsTranscribe {
                        Button("AWS Settings") {
                            showingAWSSettings = true
                        }
                        .foregroundColor(.accentColor)
                    }
                    
                    if recorderVM.selectedTranscriptionEngine == .whisper {
                        Button("Whisper Settings") {
                            showingWhisperSettings = true
                        }
                        .foregroundColor(.accentColor)
                    }
                    
                    if recorderVM.selectedTranscriptionEngine == .openAI {
                        Button("OpenAI Settings") {
                            showingOpenAISettings = true
                        }
                        .foregroundColor(.accentColor)
                    }
                } header: {
                    Text("Transcription Engine")
                }
                
                Section {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("Max Chunk Duration")
                            Spacer()
                            Text(formatDuration(maxChunkDuration))
                                .foregroundColor(.secondary)
                        }
                        
                        Slider(value: $maxChunkDuration, in: 60...900, step: 30)
                            .accentColor(.blue)
                        
                        Text("Larger chunks are more accurate but use more memory.")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("Chunk Overlap")
                            Spacer()
                            Text("\(chunkOverlap, specifier: "%.1f")s")
                                .foregroundColor(.secondary)
                        }
                        
                        Slider(value: $chunkOverlap, in: 0...5, step: 0.5)
                            .accentColor(.blue)
                        
                        Text("Overlap helps maintain context between chunks.")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                } header: {
                    Text("Chunk Settings")
                }
                
                Section {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("Max Transcription Time")
                            Spacer()
                            Text(formatDuration(maxTranscriptionTime))
                                .foregroundColor(.secondary)
                        }
                        
                        Slider(value: $maxTranscriptionTime, in: 300...3600, step: 60)
                            .accentColor(.blue)
                        
                        Text("Maximum time to spend on transcription.")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                } header: {
                    Text("Transcription Limits")
                }
                

                
                Section {
                    Toggle("Show Transcription Progress", isOn: $showTranscriptionProgress)
                    
                    Text("Display real-time transcription progress.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                } header: {
                    Text("Display Options")
                }
                
                Section {
                    TipRow(
                        icon: "clock",
                        title: "Chunk duration",
                        description: "Use 3-5 minute chunks with 2-3 second overlap."
                    )
                    
                    TipRow(
                        icon: "wifi",
                        title: "Network considerations",
                        description: "Larger chunks require more network bandwidth."
                    )
                    
                    TipRow(
                        icon: "battery.100",
                        title: "Battery optimization",
                        description: "Smaller chunks use less battery but take longer."
                    )
                } header: {
                    Text("Tips")
                }
                
                Section {
                    Button("Reset to Defaults") {
                        resetToDefaults()
                    }
                    .foregroundColor(.red)
                }
            }
            .navigationTitle("Transcription Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") {
                        dismiss()
                    }
                }
            }
            .sheet(isPresented: $showingAWSSettings) {
                AWSSettingsView()
            }
            .sheet(isPresented: $showingWhisperSettings) {
                WhisperSettingsView()
            }
            .sheet(isPresented: $showingOpenAISettings) {
                OpenAISettingsView()
            }
        }
    }
    
    private func formatDuration(_ duration: TimeInterval) -> String {
        let formatter = DateComponentsFormatter()
        formatter.unitsStyle = .abbreviated
        formatter.allowedUnits = [.hour, .minute, .second]
        formatter.zeroFormattingBehavior = .pad
        
        return formatter.string(from: duration) ?? "0s"
    }
    
    private func resetToDefaults() {
        maxChunkDuration = 300
        maxTranscriptionTime = 600
        chunkOverlap = 2.0
        showTranscriptionProgress = true
        recorderVM.selectedTranscriptionEngine = .appleIntelligence

    }
}

struct TipRow: View {
    let icon: String
    let title: String
    let description: String
    
    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .font(.title3)
                .foregroundColor(.accentColor)
                .frame(width: 24)
            
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.subheadline)
                    .fontWeight(.medium)
                
                Text(description)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            
            Spacer()
        }
        .padding(.vertical, 4)
    }
}

struct TranscriptionSettingsView_Previews: PreviewProvider {
    static var previews: some View {
        TranscriptionSettingsView()
            .environmentObject(AudioRecorderViewModel())
    }
}
