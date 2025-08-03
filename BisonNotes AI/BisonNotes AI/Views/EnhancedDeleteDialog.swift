//
//  EnhancedDeleteDialog.swift
//  Audio Journal
//
//  Enhanced deletion confirmation dialog with file relationship information
//

import SwiftUI

struct EnhancedDeleteDialog: View {
    let recording: AudioRecordingFile
    let relationships: FileRelationships
    @Binding var preserveSummary: Bool
    let onConfirm: () -> Void
    let onCancel: () -> Void
    
    @Environment(\.dismiss) private var dismiss
    
    var body: some View {
        NavigationView {
            VStack(spacing: 20) {
                // Header
                VStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 40))
                        .foregroundColor(.orange)
                    
                    Text("Delete Recording")
                        .font(.title2)
                        .fontWeight(.bold)
                        .foregroundColor(.primary)
                    
                    Text("Are you sure you want to delete '\(recording.name)'?")
                        .font(.body)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                }
                .padding(.top)
                
                // File relationships information
                VStack(alignment: .leading, spacing: 16) {
                    Text("File Status")
                        .font(.headline)
                        .foregroundColor(.primary)
                    
                    VStack(spacing: 12) {
                        FileStatusRow(
                            icon: "waveform",
                            title: "Recording",
                            status: relationships.hasRecording ? "Available" : "Not available",
                            color: relationships.hasRecording ? .green : .gray
                        )
                        
                        FileStatusRow(
                            icon: "text.quote",
                            title: "Transcript",
                            status: relationships.transcriptExists ? "Available" : "Not available",
                            color: relationships.transcriptExists ? .blue : .gray
                        )
                        
                        FileStatusRow(
                            icon: "doc.text",
                            title: "Summary",
                            status: relationships.summaryExists ? "Available" : "Not available",
                            color: relationships.summaryExists ? .purple : .gray
                        )
                    }
                }
                .padding()
                .background(
                    RoundedRectangle(cornerRadius: 12)
                        .fill(Color(.systemGray6))
                )
                
                // Deletion options
                if relationships.summaryExists {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Deletion Options")
                            .font(.headline)
                            .foregroundColor(.primary)
                        
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Image(systemName: preserveSummary ? "checkmark.circle.fill" : "circle")
                                    .foregroundColor(preserveSummary ? .green : .gray)
                                    .font(.title3)
                                
                                VStack(alignment: .leading, spacing: 4) {
                                    Text("Preserve Summary")
                                        .font(.subheadline)
                                        .fontWeight(.medium)
                                        .foregroundColor(.primary)
                                    
                                    Text("Keep the summary even after deleting the recording")
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                }
                                
                                Spacer()
                            }
                            .contentShape(Rectangle())
                            .onTapGesture {
                                preserveSummary = true
                            }
                            
                            HStack {
                                Image(systemName: !preserveSummary ? "checkmark.circle.fill" : "circle")
                                    .foregroundColor(!preserveSummary ? .red : .gray)
                                    .font(.title3)
                                
                                VStack(alignment: .leading, spacing: 4) {
                                    Text("Delete Everything")
                                        .font(.subheadline)
                                        .fontWeight(.medium)
                                        .foregroundColor(.primary)
                                    
                                    Text("Delete recording, transcript, and summary")
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                }
                                
                                Spacer()
                            }
                            .contentShape(Rectangle())
                            .onTapGesture {
                                preserveSummary = false
                            }
                        }
                    }
                    .padding()
                    .background(
                        RoundedRectangle(cornerRadius: 12)
                            .fill(Color(.systemGray6))
                    )
                }
                
                // Warning message
                if relationships.summaryExists && preserveSummary {
                    HStack {
                        Image(systemName: "info.circle.fill")
                            .foregroundColor(.blue)
                        Text("The summary will be preserved and can be accessed later, even without the original recording.")
                            .font(.caption)
                            .foregroundColor(.blue)
                    }
                    .padding()
                    .background(
                        RoundedRectangle(cornerRadius: 8)
                            .fill(Color.blue.opacity(0.1))
                    )
                }
                
                Spacer()
                
                // Action buttons
                VStack(spacing: 12) {
                    Button(action: onConfirm) {
                        HStack {
                            Image(systemName: "trash.fill")
                            Text("Delete Recording")
                        }
                        .font(.headline)
                        .foregroundColor(.white)
                        .frame(maxWidth: .infinity)
                        .padding()
                        .background(
                            RoundedRectangle(cornerRadius: 12)
                                .fill(Color.red)
                        )
                    }
                    
                    Button(action: onCancel) {
                        Text("Cancel")
                            .font(.headline)
                            .foregroundColor(.primary)
                            .frame(maxWidth: .infinity)
                            .padding()
                            .background(
                                RoundedRectangle(cornerRadius: 12)
                                    .stroke(Color.gray, lineWidth: 1)
                            )
                    }
                }
                .padding(.bottom)
            }
            .padding()
            .navigationTitle("Delete Recording")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Cancel") {
                        onCancel()
                    }
                }
            }
        }
        .onAppear {
            // Set default preserve summary option
            preserveSummary = relationships.summaryExists
            // Debug logging
            let _ = print("🗑️ EnhancedDeleteDialog rendering:")
            let _ = print("   - Recording name: \(recording.name)")
            let _ = print("   - Relationships name: \(relationships.recordingName)")
            let _ = print("   - Has recording: \(relationships.hasRecording)")
            let _ = print("   - Has transcript: \(relationships.transcriptExists)")
            let _ = print("   - Has summary: \(relationships.summaryExists)")
            let _ = print("   - Preserve summary: \(preserveSummary)")
        }
    }
}

struct FileStatusRow: View {
    let icon: String
    let title: String
    let status: String
    let color: Color
    
    var body: some View {
        HStack {
            Image(systemName: icon)
                .font(.title3)
                .foregroundColor(color)
                .frame(width: 24)
            
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.subheadline)
                    .fontWeight(.medium)
                    .foregroundColor(.primary)
                
                Text(status)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            
            Spacer()
            
            Circle()
                .fill(color)
                .frame(width: 8, height: 8)
        }
    }
}

#Preview {
    let sampleRelationships = FileRelationships(
        recordingURL: URL(string: "file:///sample.m4a"),
        recordingName: "Sample Recording",
        recordingDate: Date(),
        transcriptExists: true,
        summaryExists: true,
        iCloudSynced: false
    )
    
    let sampleRecording = AudioRecordingFile(
        url: URL(string: "file:///sample.m4a")!,
        name: "Sample Recording",
        date: Date(),
        duration: 120.0,
        locationData: nil
    )
    
    EnhancedDeleteDialog(
        recording: sampleRecording,
        relationships: sampleRelationships,
        preserveSummary: .constant(true),
        onConfirm: {},
        onCancel: {}
    )
} 