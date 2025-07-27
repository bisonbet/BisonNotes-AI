//
//  TranscriptionProgressView.swift
//  Audio Journal
//
//  Progress view for transcription operations
//

import SwiftUI

struct TranscriptionProgressView: View {
    let progress: TranscriptionProgress
    let status: String
    let onCancel: () -> Void
    
    var body: some View {
        VStack(spacing: 20) {
            // Progress indicator
            VStack(spacing: 12) {
                ProgressView(value: progress.percentage)
                    .progressViewStyle(LinearProgressViewStyle(tint: .accentColor))
                    .scaleEffect(y: 2)
                    .frame(width: 200)
                
                Text(progress.formattedProgress)
                    .font(.headline)
                    .foregroundColor(.primary)
                
                Text(status)
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 20)
            }
            
            // Additional info for large files
            if progress.totalChunks > 1 {
                VStack(spacing: 8) {
                    HStack {
                        Text("Processed:")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        Spacer()
                        Text(formatDuration(progress.processedDuration))
                            .font(.caption)
                            .foregroundColor(.primary)
                    }
                    
                    HStack {
                        Text("Total:")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        Spacer()
                        Text(formatDuration(progress.totalDuration))
                            .font(.caption)
                            .foregroundColor(.primary)
                    }
                }
                .padding(.horizontal, 20)
            }
            
            // Cancel button
            Button(action: onCancel) {
                HStack {
                    Image(systemName: "xmark.circle.fill")
                    Text("Cancel Transcription")
                }
                .foregroundColor(.red)
                .padding(.horizontal, 20)
                .padding(.vertical, 10)
                .background(Color.red.opacity(0.1))
                .cornerRadius(8)
            }
        }
        .padding(24)
        .background(Color(.systemBackground))
        .cornerRadius(16)
        .shadow(radius: 10)
    }
    
    private func formatDuration(_ duration: TimeInterval) -> String {
        let hours = Int(duration) / 3600
        let minutes = Int(duration) / 60 % 60
        let seconds = Int(duration) % 60
        
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, seconds)
        } else {
            return String(format: "%d:%02d", minutes, seconds)
        }
    }
}

struct TranscriptionProgressView_Previews: PreviewProvider {
    static var previews: some View {
        TranscriptionProgressView(
            progress: TranscriptionProgress(
                currentChunk: 3,
                totalChunks: 12,
                processedDuration: 900, // 15 minutes
                totalDuration: 3600, // 60 minutes
                currentText: "Sample transcript text...",
                isComplete: false,
                error: nil
            ),
            status: "Processing chunk 3 of 12...",
            onCancel: {}
        )
        .previewLayout(.sizeThatFits)
        .padding()
    }
} 