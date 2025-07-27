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
    @AppStorage("enableEnhancedTranscription") private var enableEnhancedTranscription: Bool = true
    @AppStorage("showTranscriptionProgress") private var showTranscriptionProgress: Bool = true
    
    @State private var showingAWSSettings = false
    @Environment(\.dismiss) private var dismiss
    
    var body: some View {
        NavigationView {
            Form {
                Section(header: Text("Transcription Engine")) {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Choose your preferred transcription service")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                            .padding(.bottom, 8)
                        
                        ForEach(TranscriptionEngine.allCases, id: \.self) { engine in
                            VStack(alignment: .leading, spacing: 4) {
                                HStack {
                                    VStack(alignment: .leading, spacing: 2) {
                                        HStack {
                                            Text(engine.rawValue)
                                                .font(.subheadline)
                                                .fontWeight(.medium)
                                            
                                            if !engine.isAvailable {
                                                Text("Coming Soon")
                                                    .font(.caption)
                                                    .padding(.horizontal, 6)
                                                    .padding(.vertical, 2)
                                                    .background(Color.orange.opacity(0.2))
                                                    .foregroundColor(.orange)
                                                    .cornerRadius(4)
                                            }
                                            
                                            if engine.requiresConfiguration && engine.isAvailable {
                                                Text("Requires Setup")
                                                    .font(.caption)
                                                    .padding(.horizontal, 6)
                                                    .padding(.vertical, 2)
                                                    .background(Color.blue.opacity(0.2))
                                                    .foregroundColor(.blue)
                                                    .cornerRadius(4)
                                            }
                                        }
                                        
                                        // Show configuration button for AWS Transcribe when selected
                                        if engine == .awsTranscribe && recorderVM.selectedTranscriptionEngine == engine {
                                            Button(action: {
                                                showingAWSSettings = true
                                            }) {
                                                HStack {
                                                    Image(systemName: "gear")
                                                        .font(.caption)
                                                    Text("Configure")
                                                        .font(.caption)
                                                }
                                                .padding(.horizontal, 8)
                                                .padding(.vertical, 4)
                                                .background(Color.blue.opacity(0.1))
                                                .foregroundColor(.blue)
                                                .cornerRadius(6)
                                            }
                                            .padding(.top, 4)
                                        }
                                        
                                        Text(engine.description)
                                            .font(.caption)
                                            .foregroundColor(.secondary)
                                            .fixedSize(horizontal: false, vertical: true)
                                    }
                                    Spacer()
                                    if recorderVM.selectedTranscriptionEngine == engine {
                                        Image(systemName: "checkmark.circle.fill")
                                            .foregroundColor(.accentColor)
                                    }
                                }
                            }
                            .padding(.vertical, 8)
                            .padding(.horizontal, 12)
                            .background(
                                Rectangle()
                                    .fill(Color(.systemGray6))
                                    .opacity(recorderVM.selectedTranscriptionEngine == engine ? 0.3 : 0.1)
                            )
                            .cornerRadius(8)
                            .contentShape(Rectangle())
                            .onTapGesture {
                                if engine.isAvailable {
                                    withAnimation(.easeInOut(duration: 0.2)) {
                                        recorderVM.selectedTranscriptionEngine = engine
                                    }
                                }
                            }
                        }
                    }
                }
                
                // AWS Transcribe specific settings
                if recorderVM.selectedTranscriptionEngine == .awsTranscribe {
                    Section(header: Text("AWS Transcribe Configuration")) {
                        VStack(alignment: .leading, spacing: 12) {
                            HStack {
                                Image(systemName: "cloud")
                                    .foregroundColor(.blue)
                                VStack(alignment: .leading, spacing: 4) {
                                    Text("Cloud-based transcription service")
                                        .font(.subheadline)
                                        .fontWeight(.medium)
                                    Text("Supports long audio files, multiple languages, and advanced speaker diarization")
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                }
                            }
                            
                            Button(action: {
                                showingAWSSettings = true
                            }) {
                                HStack {
                                    Image(systemName: "gear")
                                    Text("Configure AWS Credentials")
                                    Spacer()
                                    Image(systemName: "arrow.right")
                                }
                                .padding(.vertical, 8)
                                .padding(.horizontal, 12)
                                .background(Color.blue.opacity(0.1))
                                .foregroundColor(.blue)
                                .cornerRadius(8)
                            }
                            
                            VStack(alignment: .leading, spacing: 4) {
                                Text("Requirements:")
                                    .font(.caption)
                                    .fontWeight(.medium)
                                    .foregroundColor(.secondary)
                                Text("• AWS Account with Transcribe service access")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                                Text("• S3 bucket for temporary file storage")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                                Text("• IAM credentials with appropriate permissions")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                        }
                    }
                }
                
                Section(header: Text("Speaker Diarization")) {
                    Toggle("Enable Speaker Diarization", isOn: $recorderVM.isDiarizationEnabled)
                    
                    if recorderVM.isDiarizationEnabled {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Attempt to identify different speakers in transcripts. This helps organize conversations and meetings by speaker.")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        .padding(.vertical, 4)
                        
                        VStack(alignment: .leading, spacing: 12) {
                            Text("Diarization Method")
                                .font(.subheadline)
                                .fontWeight(.medium)
                                .foregroundColor(.primary)
                                .padding(.bottom, 8)
                            
                            ForEach(DiarizationMethod.allCases, id: \.self) { method in
                                VStack(alignment: .leading, spacing: 4) {
                                    HStack {
                                        VStack(alignment: .leading, spacing: 2) {
                                            HStack {
                                                Text(method.rawValue)
                                                    .font(.subheadline)
                                                    .fontWeight(.medium)
                                                
                                                if !method.isAvailable {
                                                    Text("Coming Soon")
                                                        .font(.caption)
                                                        .padding(.horizontal, 6)
                                                        .padding(.vertical, 2)
                                                        .background(Color.orange.opacity(0.2))
                                                        .foregroundColor(.orange)
                                                        .cornerRadius(4)
                                                }
                                            }
                                            
                                            Text(method.description)
                                                .font(.caption)
                                                .foregroundColor(.secondary)
                                                .fixedSize(horizontal: false, vertical: true)
                                        }
                                        Spacer()
                                        if recorderVM.selectedDiarizationMethod == method {
                                            Image(systemName: "checkmark.circle.fill")
                                                .foregroundColor(.accentColor)
                                        }
                                    }
                                }
                                .padding(.vertical, 8)
                                .padding(.horizontal, 12)
                                .background(
                                    Rectangle()
                                        .fill(Color(.systemGray6))
                                        .opacity(recorderVM.selectedDiarizationMethod == method ? 0.3 : 0.1)
                                )
                                .cornerRadius(8)
                                .contentShape(Rectangle())
                                .onTapGesture {
                                    if method.isAvailable {
                                        withAnimation(.easeInOut(duration: 0.2)) {
                                            recorderVM.selectedDiarizationMethod = method
                                        }
                                    }
                                }
                                .opacity(method.isAvailable ? 1.0 : 0.6)
                            }
                        }
                    }
                }
                
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
            .sheet(isPresented: $showingAWSSettings) {
                AWSSettingsView()
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
        recorderVM.selectedTranscriptionEngine = .appleIntelligence
        recorderVM.isDiarizationEnabled = false
        recorderVM.selectedDiarizationMethod = .basicPause
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