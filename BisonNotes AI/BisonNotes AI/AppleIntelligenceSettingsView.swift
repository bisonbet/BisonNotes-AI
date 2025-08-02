//
//  AppleIntelligenceSettingsView.swift
//  Audio Journal
//
//  Settings view for Apple Intelligence transcription configuration
//

import SwiftUI

struct AppleIntelligenceSettingsView: View {
    @AppStorage("maxChunkDuration") private var maxChunkDuration: Double = 300 // 5 minutes
    @AppStorage("maxTranscriptionTime") private var maxTranscriptionTime: Double = 600 // 10 minutes
    @AppStorage("chunkOverlap") private var chunkOverlap: Double = 2.0 // 2 seconds
    @Environment(\.dismiss) private var dismiss
    
    var body: some View {
        NavigationView {
            Form {
                chunkSettingsSection
                transcriptionLimitsSection
                tipsSection
                resetSection
            }
            .navigationTitle("Apple Intelligence Settings")
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
    
    private var chunkSettingsSection: some View {
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
        } footer: {
            Text("These settings control how Apple Intelligence processes large audio files by breaking them into smaller chunks.")
        }
    }
    
    private var transcriptionLimitsSection: some View {
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
        } footer: {
            Text("This prevents transcription from running indefinitely on very long recordings.")
        }
    }
    
    private var tipsSection: some View {
        Section {
            TipRow(
                icon: "clock",
                title: "Chunk duration",
                description: "Use 3-5 minute chunks with 2-3 second overlap for best results."
            )
            
            TipRow(
                icon: "memorychip",
                title: "Memory usage",
                description: "Larger chunks use more memory but provide better accuracy."
            )
            
            TipRow(
                icon: "battery.100",
                title: "Battery optimization",
                description: "Smaller chunks use less battery but take longer to process."
            )
        } header: {
            Text("Tips")
        }
    }
    
    private var resetSection: some View {
        Section {
            Button("Reset to Defaults") {
                resetToDefaults()
            }
            .foregroundColor(.red)
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
    }
}

struct AppleIntelligenceSettingsView_Previews: PreviewProvider {
    static var previews: some View {
        AppleIntelligenceSettingsView()
    }
} 