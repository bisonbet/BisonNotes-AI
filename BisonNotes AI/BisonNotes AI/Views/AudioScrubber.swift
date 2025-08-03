//
//  AudioScrubber.swift
//  Audio Journal
//
//  Audio scrubber/seek bar component for precise playback control
//

import SwiftUI

struct AudioScrubber: View {
    let currentTime: TimeInterval
    let duration: TimeInterval
    let onSeek: (TimeInterval) -> Void
    
    @State private var isDragging = false
    @State private var dragValue: Double = 0
    
    private var progress: Double {
        guard duration > 0 else { return 0 }
        return isDragging ? dragValue : currentTime / duration
    }
    
    private var currentTimeString: String {
        formatTime(isDragging ? dragValue * duration : currentTime)
    }
    
    private var remainingTimeString: String {
        let remaining = duration - (isDragging ? dragValue * duration : currentTime)
        return "-\(formatTime(remaining))"
    }
    
    var body: some View {
        VStack(spacing: 8) {
            // Time labels
            HStack {
                Text(currentTimeString)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .monospacedDigit()
                
                Spacer()
                
                Text(remainingTimeString)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .monospacedDigit()
            }
            
            // Progress bar and scrubber
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    // Background track
                    Rectangle()
                        .fill(Color.secondary.opacity(0.3))
                        .frame(height: 4)
                        .cornerRadius(2)
                    
                    // Progress track
                    Rectangle()
                        .fill(Color.accentColor)
                        .frame(width: geometry.size.width * progress, height: 4)
                        .cornerRadius(2)
                    
                    // Scrubber handle
                    Circle()
                        .fill(Color.accentColor)
                        .frame(width: isDragging ? 20 : 16, height: isDragging ? 20 : 16)
                        .shadow(color: .black.opacity(0.2), radius: 2, x: 0, y: 1)
                        .offset(x: (geometry.size.width * progress) - (isDragging ? 10 : 8))
                        .animation(.easeInOut(duration: 0.1), value: isDragging)
                }
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            if !isDragging {
                                isDragging = true
                            }
                            
                            let newValue = min(max(value.location.x / geometry.size.width, 0), 1)
                            dragValue = newValue
                        }
                        .onEnded { value in
                            let finalValue = min(max(value.location.x / geometry.size.width, 0), 1)
                            let seekTime = finalValue * duration
                            onSeek(seekTime)
                            isDragging = false
                        }
                )
                .onTapGesture { value in
                    let tapValue = value.x / geometry.size.width
                    let seekTime = tapValue * duration
                    onSeek(seekTime)
                }
            }
            .frame(height: 20)
        }
    }
    
    private func formatTime(_ time: TimeInterval) -> String {
        let totalSeconds = Int(max(time, 0))
        let minutes = totalSeconds / 60
        let seconds = totalSeconds % 60
        
        if minutes >= 60 {
            let hours = minutes / 60
            let remainingMinutes = minutes % 60
            return String(format: "%d:%02d:%02d", hours, remainingMinutes, seconds)
        } else {
            return String(format: "%d:%02d", minutes, seconds)
        }
    }
}

#Preview {
    VStack(spacing: 30) {
        AudioScrubber(
            currentTime: 125,
            duration: 300,
            onSeek: { time in
                print("Seek to: \(time)")
            }
        )
        .padding()
        
        AudioScrubber(
            currentTime: 0,
            duration: 3725, // Over 1 hour
            onSeek: { time in
                print("Seek to: \(time)")
            }
        )
        .padding()
    }
}