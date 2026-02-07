//
//  AudioRecorderViewModel+Playback.swift
//  BisonNotes AI
//
//  Audio playback control and AVAudioPlayerDelegate.
//

import Foundation
@preconcurrency import AVFoundation

// MARK: - Audio Playback

extension AudioRecorderViewModel {

	func playRecording(url: URL) {
		Task {
			do {
				try await enhancedAudioSessionManager.configurePlaybackSession()

				// Store the current seek position before creating new player
				let seekPosition = await MainActor.run { playingTime }

				// Create player on current thread (where we can use try)
				let player = try AVAudioPlayer(contentsOf: url)

				await MainActor.run {
					audioPlayer = player
					audioPlayer?.delegate = self

					// If we had a seek position, restore it
					if seekPosition > 0 {
						audioPlayer?.currentTime = seekPosition
						playingTime = seekPosition
					} else {
						playingTime = 0
					}

					audioPlayer?.play()
					isPlaying = true
					startPlayingTimer()
				}

			} catch {
				await MainActor.run {
					errorMessage = "Failed to play recording: \(error.localizedDescription)"
				}
			}
		}
	}

	func stopPlaying() {
		audioPlayer?.stop()
		isPlaying = false
		stopPlayingTimer()

		// Deactivate audio session to restore other audio apps
		Task {
			try? await enhancedAudioSessionManager.deactivateSession()
		}
	}

	/// Seek to a specific time in the current audio playback
	func seekToTime(_ time: TimeInterval) {
		guard let player = audioPlayer else { return }
		player.currentTime = min(max(time, 0), player.duration)
		playingTime = player.currentTime
	}

	/// Get the current playback time
	func getCurrentTime() -> TimeInterval {
		return audioPlayer?.currentTime ?? 0
	}

	/// Get the total duration of the current audio
	func getDuration() -> TimeInterval {
		return audioPlayer?.duration ?? 0
	}

	/// Get the current playback progress as a percentage (0.0 to 1.0)
	func getPlaybackProgress() -> Double {
		guard let player = audioPlayer, player.duration > 0 else { return 0.0 }
		return player.currentTime / player.duration
	}
}

// MARK: - AVAudioPlayerDelegate

extension AudioRecorderViewModel: AVAudioPlayerDelegate {
	nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
		Task {
			await MainActor.run {
				isPlaying = false
				stopPlayingTimer()

				// Deactivate audio session when playback finishes to restore other audio apps
				Task {
					try? await enhancedAudioSessionManager.deactivateSession()
				}
			}
		}
	}
}
