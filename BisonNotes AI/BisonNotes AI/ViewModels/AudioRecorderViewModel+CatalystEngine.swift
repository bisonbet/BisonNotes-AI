//
//  AudioRecorderViewModel+CatalystEngine.swift
//  BisonNotes AI
//
//  Mac Catalyst recording uses AVAudioEngine + AVAudioFile because
//  AVAudioRecorder cannot reliably set up its AAC/PCM converter on macOS.
//  The engine taps the input node directly, writes native PCM to a temporary
//  CAF file, then exports that file to the app's normal M4A recording URL.
//

#if targetEnvironment(macCatalyst)

import Foundation
@preconcurrency import AVFoundation

extension AudioRecorderViewModel {

	/// Start recording on Mac Catalyst using AVAudioEngine. Writes native PCM
	/// into a temporary CAF file, which is exported to the caller's M4A URL in
	/// `finalizeCatalystRecording(at:)`.
	func startCatalystEngineRecording(at url: URL) throws {
		// Tear down any leftover engine state from a previous run.
		stopCatalystEngineRecording(closingFile: false)

		do {
			try startCatalystEnginePipeline(at: url)
		} catch {
			AppLog.shared.recording("Catalyst engine start failed without AVAudioSession, retrying with fallback: \(error.localizedDescription)", level: .debug)
			stopCatalystEngineRecording(closingFile: true)
			try activateCatalystAudioSessionFallback()

			do {
				try startCatalystEnginePipeline(at: url)
			} catch {
				try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
				catalystAudioSessionActivated = false
				throw error
			}
		}
	}

	private func startCatalystEnginePipeline(at url: URL) throws {
		let engine = AVAudioEngine()
		let inputNode = engine.inputNode
		let inputFormat = inputNode.outputFormat(forBus: 0)

		guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0 else {
			throw NSError(
				domain: "AudioRecorderViewModel.Catalyst",
				code: -1,
				userInfo: [NSLocalizedDescriptionKey: "Microphone not available — check macOS Sound input settings."]
			)
		}

		let scratchURL = Self.catalystScratchURL(for: url)
		let fileManager = FileManager.default
		if fileManager.fileExists(atPath: scratchURL.path) {
			try fileManager.removeItem(at: scratchURL)
		}
		if fileManager.fileExists(atPath: url.path) {
			try fileManager.removeItem(at: url)
		}

		let audioFile = try AVAudioFile(forWriting: scratchURL, settings: inputFormat.settings)
		AppFileProtection.apply(to: scratchURL)

		catalystAudioEngine = engine
		catalystAudioFile = audioFile
		catalystEngineFormat = inputFormat
		catalystScratchRecordingURL = scratchURL

		installCatalystInputTap()

		engine.prepare()
		try engine.start()
	}

	private func activateCatalystAudioSessionFallback() throws {
		let session = AVAudioSession.sharedInstance()
		try session.setCategory(.playAndRecord, mode: .default, options: [.mixWithOthers])
		try session.setActive(true)
		catalystAudioSessionActivated = true
	}

	/// Pause Catalyst recording: remove the input tap so the file stops
	/// receiving samples. The engine and file stay alive so resume can
	/// continue writing to the same file.
	func pauseCatalystEngineRecording() {
		guard let engine = catalystAudioEngine else { return }
		engine.inputNode.removeTap(onBus: 0)
	}

	/// Resume Catalyst recording: re-install the tap on the same input node,
	/// writing into the same AVAudioFile that was opened in `start...`.
	func resumeCatalystEngineRecording() throws {
		guard catalystAudioEngine != nil, catalystAudioFile != nil else {
			throw NSError(
				domain: "AudioRecorderViewModel.Catalyst",
				code: -2,
				userInfo: [NSLocalizedDescriptionKey: "Engine state was lost; cannot resume."]
			)
		}
		installCatalystInputTap()
	}

	/// Fully stop Catalyst recording. Closes the scratch file (via deinit) and
	/// tears down the engine. The final M4A is produced later in
	/// `finalizeCatalystRecording(at:)`.
	func stopCatalystEngineRecording(closingFile: Bool = true) {
		if let engine = catalystAudioEngine {
			engine.inputNode.removeTap(onBus: 0)
			if engine.isRunning {
				engine.stop()
			}
		}
		catalystAudioEngine = nil
		catalystEngineFormat = nil
		if closingFile {
			catalystAudioFile = nil
			if catalystAudioSessionActivated {
				try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
				catalystAudioSessionActivated = false
			}
		}
	}

	/// Persist a Catalyst recording to Core Data after `stopRecording()`
	/// finishes. Mirrors the iOS path in `audioRecorderDidFinishRecording`,
	/// after exporting the native PCM scratch file to M4A.
	@MainActor
	func finalizeCatalystRecording(at url: URL) async {
		guard let scratchURL = catalystScratchRecordingURL else {
			AppLog.shared.recording("Catalyst finalize: scratch recording URL is missing", level: .error)
			errorMessage = "Recording was not saved because the temporary audio file was missing."
			return
		}

		do {
			try await exportCatalystScratchRecording(from: scratchURL, to: url)
		} catch {
			AppLog.shared.recording("Catalyst finalize: failed to export recording: \(error.localizedDescription)", level: .error)
			errorMessage = "Recording could not be finalized: \(error.localizedDescription)"
			try? FileManager.default.removeItem(at: scratchURL)
			catalystScratchRecordingURL = nil
			return
		}

		guard FileManager.default.fileExists(atPath: url.path) else {
			AppLog.shared.recording("Catalyst finalize: recording file is missing at \(url.lastPathComponent)", level: .error)
			errorMessage = "Recording was lost — file was not written."
			return
		}

		saveLocationData(for: url)

		guard let workflowManager = workflowManager else {
			AppLog.shared.recording("WorkflowManager not set - Catalyst recording not saved", level: .error)
			return
		}

		let fileSize = getFileSize(url: url)
		let duration = getRecordingDuration(url: url)
		let quality = AudioRecorderViewModel.getCurrentAudioQuality()
		let displayName = generateAppRecordingDisplayName()

		let recordingId = workflowManager.createRecording(
			url: url,
			name: displayName,
			date: currentRecordingDate(for: url),
			fileSize: fileSize,
			duration: duration,
			quality: quality,
			locationData: recordingLocationSnapshot()
		)
		AppLog.shared.recording("Catalyst recording created with workflow manager, ID: \(recordingId)")

		self.resetRecordingLocation()
		self.recordingStartedAt = nil
		self.recordingBeingProcessed = false
		self.catalystScratchRecordingURL = nil
	}

	private func installCatalystInputTap() {
		guard let engine = catalystAudioEngine,
		      let format = catalystEngineFormat else { return }

		// The scratch file uses the input node's native PCM format, so the tap
		// can write each buffer directly without invoking a compressed encoder
		// from the real-time audio callback.
		engine.inputNode.installTap(
			onBus: 0,
			bufferSize: 4096,
			format: format
		) { [weak self] buffer, _ in
			guard let file = self?.catalystAudioFile else { return }
			do {
				try file.write(from: buffer)
			} catch {
				AppLog.shared.recording("Catalyst engine: file write failed: \(error.localizedDescription)", level: .error)
			}
		}
	}

	private static func catalystScratchURL(for finalURL: URL) -> URL {
		finalURL
			.deletingPathExtension()
			.appendingPathExtension("caf")
	}

	private func exportCatalystScratchRecording(from scratchURL: URL, to finalURL: URL) async throws {
		let fileManager = FileManager.default
		guard fileManager.fileExists(atPath: scratchURL.path) else {
			throw NSError(
				domain: "AudioRecorderViewModel.Catalyst",
				code: -3,
				userInfo: [NSLocalizedDescriptionKey: "Temporary recording file does not exist."]
			)
		}

		let sourceAsset = AVURLAsset(url: scratchURL)
		let sourceDuration = try await sourceAsset.load(.duration).seconds
		guard sourceDuration.isFinite, sourceDuration > 0 else {
			throw NSError(
				domain: "AudioRecorderViewModel.Catalyst",
				code: -4,
				userInfo: [NSLocalizedDescriptionKey: "Temporary recording has no audio duration."]
			)
		}

		guard !(try await sourceAsset.loadTracks(withMediaType: .audio)).isEmpty else {
			throw NSError(
				domain: "AudioRecorderViewModel.Catalyst",
				code: -5,
				userInfo: [NSLocalizedDescriptionKey: "Temporary recording has no audio track."]
			)
		}

		guard let exportSession = AVAssetExportSession(asset: sourceAsset, presetName: AVAssetExportPresetAppleM4A) else {
			throw NSError(
				domain: "AudioRecorderViewModel.Catalyst",
				code: -6,
				userInfo: [NSLocalizedDescriptionKey: "Could not create audio export session."]
			)
		}

		let tempURL = finalURL
			.deletingLastPathComponent()
			.appendingPathComponent("catalyst_export_\(UUID().uuidString).m4a")

		if fileManager.fileExists(atPath: tempURL.path) {
			try fileManager.removeItem(at: tempURL)
		}

		try await exportSession.export(to: tempURL, as: .m4a)
		AppFileProtection.apply(to: tempURL)

		let attributes = try fileManager.attributesOfItem(atPath: tempURL.path)
		let exportedSize = attributes[.size] as? Int64 ?? 0
		guard exportedSize > 0 else {
			throw NSError(
				domain: "AudioRecorderViewModel.Catalyst",
				code: -7,
				userInfo: [NSLocalizedDescriptionKey: "Exported recording file is empty."]
			)
		}

		let exportedAsset = AVURLAsset(url: tempURL)
		let exportedDuration = try await exportedAsset.load(.duration).seconds
		guard exportedDuration.isFinite, exportedDuration > 0 else {
			throw NSError(
				domain: "AudioRecorderViewModel.Catalyst",
				code: -8,
				userInfo: [NSLocalizedDescriptionKey: "Exported recording has no audio duration."]
			)
		}

		if fileManager.fileExists(atPath: finalURL.path) {
			try fileManager.removeItem(at: finalURL)
		}
		try fileManager.moveItem(at: tempURL, to: finalURL)
		AppFileProtection.apply(to: finalURL)
		try? fileManager.removeItem(at: scratchURL)

		AppLog.shared.recording("Catalyst recording exported to M4A: \(finalURL.lastPathComponent), duration: \(exportedDuration)s, size: \(exportedSize) bytes")
	}
}

#endif
