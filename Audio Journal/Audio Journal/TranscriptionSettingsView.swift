//
//  TranscriptionSettingsView.swift
//  Audio Journal
//
//  Settings view for transcription configuration
//

import SwiftUI

struct TranscriptionSettingsView: View {
    @AppStorage("maxChunkDuration") private var maxChunkDuration: Double = 300 // 5 minutes
    @AppStorage("maxTranscriptionTime") private var maxTranscriptionTime: Double = 600 // 10 minutes
    @AppStorage("chunkOverlap") private var chunkOverlap: Double = 2.0 // 2 seconds
    @AppStorage("enableEnhancedTranscription") private var enableEnhancedTranscription: Bool = true
    @AppStorage("showTranscriptionProgress") private var showTranscriptionProgress: Bool = true
    
    @Environment(\.dismiss) private var dismiss
    
    var body: some View {
        NavigationView {
            Form {
                Section(header: Text("Enhanced Transcription")) {
                    Toggle("Enable Enhanced Transcription", isOn: $enableEnhancedTranscription)
                    
                    if enableEnhancedTranscription {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("This feature automatically handles large audio files by breaking them into smaller chunks for processing. This prevents timeouts and improves reliability for long recordings.")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        .padding(.vertical, 4)
                    }
                }
                
                if enableEnhancedTranscription {
                    Section(header: Text("Chunk Settings")) {
                        VStack(alignment: .leading, spacing: 12) {
                            HStack {
                                Text("Max Chunk Duration")
                                Spacer()
                                Text(formatDuration(maxChunkDuration))
                                    .foregroundColor(.secondary)
                            }
                            
                            Slider(value: $maxChunkDuration, in: 60...600, step: 30) {
                                Text("Max Chunk Duration")
                            } minimumValueLabel: {
                                Text("1m")
                                    .font(.caption)
                            } maximumValueLabel: {
                                Text("10m")
                                    .font(.caption)
                            }
                            
                            Text("Larger chunks may process faster but are more likely to timeout. Smaller chunks are more reliable but take longer to process.")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        
                        VStack(alignment: .leading, spacing: 12) {
                            HStack {
                                Text("Chunk Overlap")
                                Spacer()
                                Text("\(Int(chunkOverlap))s")
                                    .foregroundColor(.secondary)
                            }
                            
                            Slider(value: $chunkOverlap, in: 0...5, step: 0.5) {
                                Text("Chunk Overlap")
                            } minimumValueLabel: {
                                Text("0s")
                                    .font(.caption)
                            } maximumValueLabel: {
                                Text("5s")
                                    .font(.caption)
                            }
                            
                            Text("Overlap between chunks helps maintain context and improve transcription accuracy at chunk boundaries.")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                    
                    Section(header: Text("Timeout Settings")) {
                        VStack(alignment: .leading, spacing: 12) {
                            HStack {
                                Text("Max Transcription Time")
                                Spacer()
                                Text(formatDuration(maxTranscriptionTime))
                                    .foregroundColor(.secondary)
                            }
                            
                            Slider(value: $maxTranscriptionTime, in: 300...1800, step: 60) {
                                Text("Max Transcription Time")
                            } minimumValueLabel: {
                                Text("5m")
                                    .font(.caption)
                            } maximumValueLabel: {
                                Text("30m")
                                    .font(.caption)
                            }
                            
                            Text("Maximum time allowed for the entire transcription process. If exceeded, transcription will be cancelled.")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                }
                
                Section(header: Text("Progress Display")) {
                    Toggle("Show Detailed Progress", isOn: $showTranscriptionProgress)
                    
                    if showTranscriptionProgress {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Display detailed progress information including chunk processing status and estimated completion time.")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        .padding(.vertical, 4)
                    }
                }
                
                Section(header: Text("Performance Tips")) {
                    VStack(alignment: .leading, spacing: 8) {
                        TipRow(
                            icon: "clock",
                            title: "For 60+ minute files",
                            description: "Use 3-5 minute chunks with 2-3 second overlap"
                        )
                        
                        TipRow(
                            icon: "wifi",
                            title: "Network considerations",
                            description: "Larger chunks require more network bandwidth"
                        )
                        
                        TipRow(
                            icon: "battery.100",
                            title: "Battery optimization",
                            description: "Smaller chunks use less battery but take longer"
                        )
                    }
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
        }
    }
    
    private func formatDuration(_ duration: TimeInterval) -> String {
        let minutes = Int(duration) / 60
        let seconds = Int(duration) % 60
        
        if minutes >= 60 {
            let hours = minutes / 60
            let remainingMinutes = minutes % 60
            return String(format: "%dh %dm", hours, remainingMinutes)
        } else {
            return String(format: "%dm %ds", minutes, seconds)
        }
    }
    
    private func resetToDefaults() {
        maxChunkDuration = 300
        maxTranscriptionTime = 600
        chunkOverlap = 2.0
        enableEnhancedTranscription = true
        showTranscriptionProgress = true
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
    }
} 