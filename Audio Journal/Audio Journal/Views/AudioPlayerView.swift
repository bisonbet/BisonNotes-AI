//
//  AudioPlayerView.swift
//  Audio Journal
//
//  Created by Kiro on 8/1/25.
//

import SwiftUI
import AVFoundation

struct AudioPlayerView: View {
    let recording: AudioRecordingFile
    @EnvironmentObject var recorderVM: AudioRecorderViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var duration: TimeInterval = 0
    
    var body: some View {
        VStack(spacing: 20) {
            Text("Audio Player")
                .font(.largeTitle)
                .fontWeight(.bold)
                .foregroundColor(.primary)
            
            Text("Recording: \(recording.name)")
                .font(.title2)
                .multilineTextAlignment(.center)
            
            Text("Date: \(recording.dateString)")
                .font(.subheadline)
                .foregroundColor(.secondary)
            
            if duration > 0 {
                Text("Duration: \(formatTime(duration))")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
            } else {
                Text("Loading duration...")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
            }
            
            Button(action: togglePlayback) {
                HStack {
                    Image(systemName: recorderVM.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                        .font(.title)
                    Text(recorderVM.isPlaying ? "Pause" : "Play")
                        .font(.title2)
                }
                .foregroundColor(.white)
                .padding()
                .background(Color.accentColor)
                .cornerRadius(10)
            }
            
            Button("Close") {
                if recorderVM.isPlaying {
                    recorderVM.stopPlaying()
                }
                dismiss()
            }
            .font(.headline)
            .padding()
            
            Spacer()
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(.systemBackground))
        .onAppear {
            print("🎵 AudioPlayerView appeared for: \(recording.name)")
            setupAudio()
        }
        .onDisappear {
            print("🎵 AudioPlayerView disappeared")
            if recorderVM.isPlaying {
                recorderVM.stopPlaying()
            }
        }
    }
    
    private func setupAudio() {
        print("🎵 AudioPlayerView setupAudio called for: \(recording.name)")
        print("🎵 Recording URL: \(recording.url)")
        print("🎵 Recording duration from struct: \(recording.duration)")
        
        // Get duration from the audio file
        do {
            let player = try AVAudioPlayer(contentsOf: recording.url)
            duration = player.duration
            print("🎵 Duration loaded from AVAudioPlayer: \(duration)")
        } catch {
            print("❌ Error getting audio duration: \(error)")
            // Fallback to recording duration if available
            duration = recording.duration
            print("🎵 Using fallback duration: \(duration)")
        }
    }
    
    private func togglePlayback() {
        if recorderVM.isPlaying {
            recorderVM.stopPlaying()
        } else {
            recorderVM.playRecording(url: recording.url)
        }
    }
    
    private func seekBackward() {
        // Restart from beginning since AudioRecorderViewModel doesn't have seek functionality
        if recorderVM.isPlaying {
            recorderVM.stopPlaying()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                recorderVM.playRecording(url: recording.url)
            }
        }
    }
    
    private func seekForward() {
        // Placeholder for future seek functionality
        // Would require additional methods in AudioRecorderViewModel
    }
    
    private func formatTime(_ time: TimeInterval) -> String {
        let minutes = Int(time) / 60
        let seconds = Int(time) % 60
        return String(format: "%d:%02d", minutes, seconds)
    }
}