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
    @State private var showingShareSheet = false

    var body: some View {
        VStack(spacing: 20) {
            HStack {
                Spacer()
                Button(action: { showingShareSheet = true }) {
                    Image(systemName: "square.and.arrow.up")
                        .font(.title3)
                        .foregroundColor(.accentColor)
                }
                .padding(.trailing)
            }

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
            
            Spacer()
            
            // Audio scrubber with progress and seek functionality
            if duration > 0 {
                AudioScrubber(
                    currentTime: recorderVM.playingTime,
                    duration: duration,
                    onSeek: { time in
                        print("🎵 AudioPlayerView: Seeking to time: \(time)")
                        recorderVM.seekToTime(time)
                    }
                )
                .padding(.horizontal)
                // Remove debug logging - scrubber working properly now
            } else {
                // Loading state
                VStack {
                    ProgressView()
                        .progressViewStyle(CircularProgressViewStyle())
                    Text("Loading audio...")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }
                .frame(height: 50)
            }
            
            // Playback controls
            HStack(spacing: 30) {
                // Skip backward 15 seconds
                Button(action: skipBackward) {
                    VStack {
                        Image(systemName: "gobackward.15")
                            .font(.title2)
                        Text("15s")
                            .font(.caption2)
                    }
                }
                .foregroundColor(.accentColor)
                
                // Main play/pause button
                Button(action: togglePlayback) {
                    Image(systemName: recorderVM.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                        .font(.system(size: 60))
                        .foregroundColor(.accentColor)
                }
                
                // Skip forward 15 seconds
                Button(action: skipForward) {
                    VStack {
                        Image(systemName: "goforward.15")
                            .font(.title2)
                        Text("15s")
                            .font(.caption2)
                    }
                }
                .foregroundColor(.accentColor)
            }
            .padding()
            
            Spacer()
            
            Button("Close") {
                if recorderVM.isPlaying {
                    recorderVM.stopPlaying()
                }
                dismiss()
            }
            .font(.headline)
            .padding()
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(.systemBackground))
        .sheet(isPresented: $showingShareSheet) {
            ShareSheet(activityItems: [recording.url])
        }
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
        print("🎵 AudioPlayerView: Toggle playback - currently playing: \(recorderVM.isPlaying)")
        if recorderVM.isPlaying {
            recorderVM.stopPlaying()
        } else {
            recorderVM.playRecording(url: recording.url)
        }
    }
    
    private func skipBackward() {
        let currentTime = recorderVM.getCurrentTime()
        let newTime = max(currentTime - 15.0, 0)
        recorderVM.seekToTime(newTime)
    }
    
    private func skipForward() {
        let currentTime = recorderVM.getCurrentTime()
        let newTime = min(currentTime + 15.0, duration)
        recorderVM.seekToTime(newTime)
    }
    
    private func formatTime(_ time: TimeInterval) -> String {
        let minutes = Int(time) / 60
        let seconds = Int(time) % 60
        return String(format: "%d:%02d", minutes, seconds)
    }
}