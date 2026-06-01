//
//  AudioRecorderViewModel+CatalystEngine.swift
//  BisonNotes AI
//
//  Mac Catalyst recording uses AVAudioEngine + AVAudioFile because
//  AVAudioRecorder cannot reliably set up its AAC/PCM converter without an
//  AVAudioSession. The engine taps the input node directly, AVAudioFile
//  writes AAC/M4A using the buffer's known format, and pause/resume work
//  by removing and re-installing the tap on a single file (no segments).
//

#if targetEnvironment(macCatalyst)

import Foundation
@preconcurrency import AVFoundation

extension AudioRecorderViewModel {

	/// Start recording on Mac Catalyst using AVAudioEngine. Writes AAC into a
	/// single .m4a file. Throws on setup failure so the caller can surface an
	/// error to the user.
	func startCatalystEngineRecording(at url: URL) throws {
		// Tear down any leftover engine state from a previous run.
		stopCatalystEngineRecording(closingFile: false)

		// AVAudioEngine input on Mac Catalyst requires a configured audio
		// session — without it the input audio unit fails to initialize
		// (AUIOBase Initialize error=-50). Best-effort: setCategory may log
		// "cannot add handler" Mach port noise but still installs the
		// category that the audio unit needs.
		let session = AVAudioSession.sharedInstance()
		try? session.setCategory(.playAndRecord, mode: .default, options: [.mixWithOthers])
		try? session.setActive(true)

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

		let outputSettings: [String: Any] = [
			AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
			AVSampleRateKey: inputFormat.sampleRate,
			AVNumberOfChannelsKey: 1,
			AVEncoderBitRateKey: 64000
		]
		let audioFile = try AVAudioFile(forWriting: url, settings: outputSettings)
		AppFileProtection.apply(to: url)

		catalystAudioEngine = engine
		catalystAudioFile = audioFile
		catalystEngineFormat = inputFormat

		installCatalystInputTap()

		engine.prepare()
		try engine.start()
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

	/// Fully stop Catalyst recording. Closes the file (via deinit) and tears
	/// down the engine. After this returns the file at the original URL is
	/// finalized AAC and ready to read.
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
			// Best-effort: release the playAndRecord category we set in start.
			try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
		}
	}

	/// Persist a Catalyst recording to Core Data after `stopRecording()`
	/// finishes. Mirrors the iOS path in `audioRecorderDidFinishRecording`,
	/// minus the AAC transcode (the file is already AAC).
	@MainActor
	func finalizeCatalystRecording(at url: URL) async {
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
	}

	private func installCatalystInputTap() {
		guard let engine = catalystAudioEngine,
		      let format = catalystEngineFormat else { return }

		// `format: nil` means "use the input node's native format", which
		// is what we already captured. Pass it explicitly so the tap matches
		// the file we're writing to.
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
}

#endif
