//
//  AudioRecorderViewModel+CatalystEngine.swift
//  BisonNotes AI
//
//  Mac recording uses AVAudioEngine + AVAudioFile because
//  AVAudioRecorder cannot reliably set up its AAC/PCM converter on macOS.
//  The engine taps the input node directly, writes native PCM to a temporary
//  CAF file, then exports that file to the app's normal M4A recording URL.
//

#if targetEnvironment(macCatalyst) || os(macOS)

import Foundation
@preconcurrency import AVFoundation

extension AudioRecorderViewModel {
	// Keep the worst-case summed level below full scale while favoring nearby speech.
	private static let microphoneMeetingMixGain: Float = 0.5
	private static let systemMeetingMixGain: Float = 0.4

	@MainActor
	func setupCatalystRecording(at url: URL) async {
		var systemAudioError: Error?
		catalystScratchSegmentURLs = []

		if isMacSystemAudioCaptureEnabled {
			let systemAudioURL = Self.catalystSystemAudioURL(for: url)
			let capture = CatalystSystemAudioCapture(outputURL: systemAudioURL)
			do {
				try await capture.start()
				catalystSystemAudioCapture = capture
				catalystSystemAudioURL = systemAudioURL
			} catch {
				systemAudioError = error
				catalystSystemAudioCapture = nil
				catalystSystemAudioURL = nil
				AppLog.shared.recording("Catalyst system audio capture unavailable: \(error.localizedDescription)", level: .error)
			}
		}

		do {
			// Catalyst: drive microphone recording with AVAudioEngine + AVAudioFile
			// so we bypass AVAudioRecorder's broken converter setup. The scratch
			// file is exported to M4A when recording stops.
			try startCatalystEngineRecording(at: url)
			markRecordingStarted()

			if let systemAudioError {
				errorMessage = "Meeting audio could not be captured: \(systemAudioError.localizedDescription). Recording microphone audio only."
			}
		} catch {
			if let capture = catalystSystemAudioCapture {
				if let abandonedSystemAudioURL = try? await capture.stop() {
					try? FileManager.default.removeItem(at: abandonedSystemAudioURL)
				}
			}
				catalystSystemAudioCapture = nil
				catalystSystemAudioURL = nil
				finishRecordingStartup()
				errorMessage = "Failed to start recording: \(error.localizedDescription)"
				AppLog.shared.recording("Catalyst recording start failed: \(error.localizedDescription)", level: .error)
			}
		}

	/// Start recording on Mac Catalyst using AVAudioEngine. Writes native PCM
	/// into a temporary CAF file, which is exported to the caller's M4A URL in
	/// `finalizeCatalystRecording(at:)`.
	func startCatalystEngineRecording(at url: URL) throws {
		// Tear down any leftover engine state from a previous run.
		stopCatalystEngineRecording(closingFile: false)

		#if targetEnvironment(macCatalyst)
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
		#else
		// Native macOS uses Core Audio directly. AVAudioSession is an iOS API
		// and the Catalyst-only fallback must never run here.
		try startCatalystEnginePipeline(at: url)
		#endif
	}

	private func startCatalystEnginePipeline(
		at url: URL,
		scratchURL suppliedScratchURL: URL? = nil,
		removingFinalOutput: Bool = true
	) throws {
		let engine = AVAudioEngine()
		#if os(macOS)
		try enhancedAudioSessionManager.configureInputDevice(for: engine)
		#endif
		let inputNode = engine.inputNode
		let inputFormat = inputNode.outputFormat(forBus: 0)

		guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0 else {
			throw NSError(
				domain: "AudioRecorderViewModel.Catalyst",
				code: -1,
				userInfo: [NSLocalizedDescriptionKey: "Microphone not available — check macOS Sound input settings."]
			)
		}

		let scratchURL = suppliedScratchURL ?? Self.catalystScratchURL(for: url)
		let fileManager = FileManager.default
		if fileManager.fileExists(atPath: scratchURL.path) {
			try fileManager.removeItem(at: scratchURL)
		}
		if removingFinalOutput, fileManager.fileExists(atPath: url.path) {
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

	#if targetEnvironment(macCatalyst)
	private func activateCatalystAudioSessionFallback() throws {
		let session = AVAudioSession.sharedInstance()
		try session.setCategory(.playAndRecord, mode: .default, options: [.mixWithOthers])
		try session.setActive(true)
		catalystAudioSessionActivated = true
	}
	#endif

	/// Pause Catalyst recording: remove the input tap so the file stops
	/// receiving samples. The engine and file stay alive so resume can
	/// continue writing to the same file.
	func pauseCatalystEngineRecording() {
		guard let engine = catalystAudioEngine else { return }
		engine.inputNode.removeTap(onBus: 0)
		catalystSystemAudioCapture?.setPaused(true)
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
		catalystSystemAudioCapture?.setPaused(false)
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
		#if os(macOS)
		enhancedAudioSessionManager.clearConfiguredInputDevice()
		#endif
		if closingFile {
			catalystAudioFile = nil
			#if targetEnvironment(macCatalyst)
			if catalystAudioSessionActivated {
				try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
				catalystAudioSessionActivated = false
			}
			#endif
		}
	}

	#if os(macOS)
	/// Closes the current PCM segment without discarding it. A replacement input
	/// may expose a different native format, so recovery always starts a new CAF.
	func sealNativeMacScratchSegment() {
		let currentScratchURL = catalystScratchRecordingURL
		stopCatalystEngineRecording()
		if let currentScratchURL,
		   FileManager.default.fileExists(atPath: currentScratchURL.path),
		   !catalystScratchSegmentURLs.contains(currentScratchURL) {
			catalystScratchSegmentURLs.append(currentScratchURL)
		}
		catalystScratchRecordingURL = nil
	}

	/// Starts the next PCM segment on the currently resolved Core Audio input.
	/// The original final URL is retained for the normal stop/finalize flow.
	func startNativeMacContinuation(at finalURL: URL) throws {
		let segmentIndex = catalystScratchSegmentURLs.count + 1
		let scratchURL = Self.catalystScratchURL(for: finalURL, segmentIndex: segmentIndex)
		try startCatalystEnginePipeline(
			at: finalURL,
			scratchURL: scratchURL,
			removingFinalOutput: false
		)
	}
	#endif

	func stopCatalystSystemAudioCapture() async -> URL? {
		guard let capture = catalystSystemAudioCapture else {
			catalystSystemAudioURL = nil
			return nil
		}

		do {
			let capturedURL = try await capture.stop()
			catalystSystemAudioCapture = nil
			catalystSystemAudioURL = capturedURL
			return capturedURL
		} catch {
			AppLog.shared.recording("Catalyst system audio capture finalize failed: \(error.localizedDescription)", level: .error)
			catalystSystemAudioCapture = nil
			catalystSystemAudioURL = nil
			return nil
		}
	}

	/// Persist a Catalyst recording to Core Data after `stopRecording()`
	/// finishes. Mirrors the iOS path in `audioRecorderDidFinishRecording`,
	/// after exporting the native PCM scratch file to M4A.
	@MainActor
	func finalizeCatalystRecording(at url: URL) async {
		let scratchURLs = allCatalystScratchURLs()
		guard !scratchURLs.isEmpty else {
			AppLog.shared.recording("Catalyst finalize: scratch recording URL is missing", level: .error)
			errorMessage = "Recording was not saved because the temporary audio file was missing."
			return
		}

		do {
			if let systemAudioURL = catalystSystemAudioURL {
				try await exportAndMixCatalystRecording(
					microphoneScratchURLs: scratchURLs,
					systemAudioURL: systemAudioURL,
					finalURL: url
				)
			} else {
				try await exportCatalystScratchRecordings(from: scratchURLs, to: url)
			}
		} catch {
			AppLog.shared.recording("Catalyst finalize: failed to export recording: \(error.localizedDescription)", level: .error)
			errorMessage = "Recording could not be finalized: \(error.localizedDescription)"
			removeCatalystScratchFiles(scratchURLs)
			catalystScratchRecordingURL = nil
			catalystScratchSegmentURLs = []
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

		resetCatalystFinalizationState()
	}

	private func resetCatalystFinalizationState() {
		resetRecordingLocation()
		recordingStartedAt = nil
		recordingBeingProcessed = false
		catalystScratchRecordingURL = nil
		catalystScratchSegmentURLs = []
		catalystSystemAudioURL = nil
	}

	private func allCatalystScratchURLs() -> [URL] {
		var scratchURLs = catalystScratchSegmentURLs
		if let currentScratchURL = catalystScratchRecordingURL,
		   !scratchURLs.contains(currentScratchURL) {
			scratchURLs.append(currentScratchURL)
		}
		return scratchURLs
	}

	private func removeCatalystScratchFiles(_ scratchURLs: [URL]) {
		for scratchURL in scratchURLs {
			try? FileManager.default.removeItem(at: scratchURL)
		}
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

	private static func catalystScratchURL(for finalURL: URL, segmentIndex: Int? = nil) -> URL {
		// Stage in the temp directory, not next to the recording: an orphaned
		// scratch file left by a crash between stop and finalize would otherwise
		// sit in the recordings directory. The name is derived from the final
		// recording so the start-pipeline retry cleanup can find and remove it.
		let basename = finalURL.deletingPathExtension().lastPathComponent
		let scratchName = segmentIndex.map { "\(basename)-input-\($0)" } ?? basename
		return FileManager.default.temporaryDirectory
			.appendingPathComponent(scratchName)
			.appendingPathExtension("caf")
	}

	private static func catalystSystemAudioURL(for finalURL: URL) -> URL {
		FileManager.default.temporaryDirectory
			.appendingPathComponent("\(finalURL.deletingPathExtension().lastPathComponent)-system")
			.appendingPathExtension("m4a")
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

		// Export into the temp directory, not the recordings directory: a stray
		// `.m4a` left there by a failed/killed export would be misread as an
		// orphaned recording by EnhancedFileManager's documents-directory scan.
		let tempURL = fileManager.temporaryDirectory
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

	private func exportCatalystScratchRecordings(from scratchURLs: [URL], to finalURL: URL) async throws {
		guard scratchURLs.count > 1 else {
			guard let scratchURL = scratchURLs.first else {
				throw NSError(
					domain: "AudioRecorderViewModel.Catalyst",
					code: -13,
					userInfo: [NSLocalizedDescriptionKey: "No temporary recording segments were available."]
				)
			}
			try await exportCatalystScratchRecording(from: scratchURL, to: finalURL)
			return
		}

		let (composition, insertionTime) = try await makeRecoveredMicrophoneComposition(from: scratchURLs)
		guard insertionTime.isValid, insertionTime.seconds > 0,
		      let exportSession = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetAppleM4A) else {
			throw NSError(
				domain: "AudioRecorderViewModel.Catalyst",
				code: -15,
				userInfo: [NSLocalizedDescriptionKey: "Recovered microphone segments contained no audio."]
			)
		}

		let fileManager = FileManager.default
		let tempURL = fileManager.temporaryDirectory
			.appendingPathComponent("catalyst_segments_\(UUID().uuidString).m4a")
		try await exportSession.export(to: tempURL, as: .m4a)
		let attributes = try fileManager.attributesOfItem(atPath: tempURL.path)
		let exportedSize = attributes[.size] as? Int64 ?? 0
		let exportedDuration = try await AVURLAsset(url: tempURL).load(.duration).seconds
		guard exportedSize > 0, exportedDuration.isFinite, exportedDuration > 0 else {
			try? fileManager.removeItem(at: tempURL)
			throw NSError(
				domain: "AudioRecorderViewModel.Catalyst",
				code: -16,
				userInfo: [NSLocalizedDescriptionKey: "Recovered microphone export was empty."]
			)
		}
		if fileManager.fileExists(atPath: finalURL.path) {
			try fileManager.removeItem(at: finalURL)
		}
		try fileManager.moveItem(at: tempURL, to: finalURL)
		AppFileProtection.apply(to: finalURL)
		removeCatalystScratchFiles(scratchURLs)
		AppLog.shared.recording(
			"Recovered Mac microphone segments exported to M4A: \(scratchURLs.count) segments, " +
			"duration: \(exportedDuration)s, size: \(exportedSize) bytes"
		)
	}

	private func makeRecoveredMicrophoneComposition(
		from scratchURLs: [URL]
	) async throws -> (AVMutableComposition, CMTime) {
		let composition = AVMutableComposition()
		guard let compositionTrack = composition.addMutableTrack(
			withMediaType: .audio,
			preferredTrackID: kCMPersistentTrackID_Invalid
		) else {
			throw NSError(
				domain: "AudioRecorderViewModel.Catalyst",
				code: -14,
				userInfo: [NSLocalizedDescriptionKey: "Could not create a track for recovered microphone audio."]
			)
		}

		var insertionTime = CMTime.zero
		for scratchURL in scratchURLs {
			let asset = AVURLAsset(url: scratchURL)
			guard let sourceTrack = try await asset.loadTracks(withMediaType: .audio).first else { continue }
			let duration = try await asset.load(.duration)
			guard duration.isValid, duration.seconds > 0 else { continue }
			try compositionTrack.insertTimeRange(
				CMTimeRange(start: .zero, duration: duration),
				of: sourceTrack,
				at: insertionTime
			)
			insertionTime = CMTimeAdd(insertionTime, duration)
		}
		return (composition, insertionTime)
	}

	private func exportAndMixCatalystRecording(
		microphoneScratchURLs: [URL],
		systemAudioURL: URL,
		finalURL: URL
	) async throws {
		let fileManager = FileManager.default

		do {
			try await mixCatalystAudioTracks(
				microphoneScratchURLs: microphoneScratchURLs,
				systemAudioURL: systemAudioURL,
				finalURL: finalURL
			)
			removeCatalystScratchFiles(microphoneScratchURLs)
			try? fileManager.removeItem(at: systemAudioURL)
		} catch {
			AppLog.shared.recording("Catalyst meeting audio mix failed; saving microphone track only: \(error.localizedDescription)", level: .error)
			try await exportCatalystScratchRecordings(from: microphoneScratchURLs, to: finalURL)
			errorMessage = "Meeting audio could not be mixed into this recording. Saved microphone audio only."
			try? fileManager.removeItem(at: systemAudioURL)
		}
	}

	private func mixCatalystAudioTracks(
		microphoneScratchURLs: [URL],
		systemAudioURL: URL,
		finalURL: URL
	) async throws {
		let fileManager = FileManager.default
		let systemAsset = AVURLAsset(url: systemAudioURL)
		let (composition, microphoneDuration) = try await makeRecoveredMicrophoneComposition(
			from: microphoneScratchURLs
		)
		guard microphoneDuration.isValid, microphoneDuration.seconds > 0 else {
			throw NSError(
				domain: "AudioRecorderViewModel.Catalyst",
				code: -12,
				userInfo: [NSLocalizedDescriptionKey: "Microphone recording has no audio duration."]
			)
		}

		var mixParameters: [AVAudioMixInputParameters] = composition.tracks(withMediaType: .audio).map { track in
			let parameter = AVMutableAudioMixInputParameters(track: track)
			parameter.setVolume(Self.microphoneMeetingMixGain, at: .zero)
			return parameter
		}
		try await addAudioTracks(
			from: systemAsset,
			to: composition,
			mixParameters: &mixParameters,
			volume: Self.systemMeetingMixGain,
			maxDuration: microphoneDuration
		)

		guard !composition.tracks(withMediaType: .audio).isEmpty else {
			throw NSError(
				domain: "AudioRecorderViewModel.Catalyst",
				code: -9,
				userInfo: [NSLocalizedDescriptionKey: "No audio tracks were available to mix."]
			)
		}

		let audioMix = AVMutableAudioMix()
		audioMix.inputParameters = mixParameters

		guard let exportSession = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetAppleM4A) else {
			throw NSError(
				domain: "AudioRecorderViewModel.Catalyst",
				code: -10,
				userInfo: [NSLocalizedDescriptionKey: "Could not create meeting audio export session."]
			)
		}
		exportSession.audioMix = audioMix
		exportSession.timeRange = CMTimeRange(start: .zero, duration: microphoneDuration)

		let tempURL = fileManager.temporaryDirectory
			.appendingPathComponent("catalyst_meeting_mix_\(UUID().uuidString).m4a")
		if fileManager.fileExists(atPath: tempURL.path) {
			try fileManager.removeItem(at: tempURL)
		}

		try await exportSession.export(to: tempURL, as: .m4a)
		AppFileProtection.apply(to: tempURL)

		let exportedAsset = AVURLAsset(url: tempURL)
		let exportedDuration = try await exportedAsset.load(.duration).seconds
		guard exportedDuration.isFinite, exportedDuration > 0 else {
			throw NSError(
				domain: "AudioRecorderViewModel.Catalyst",
				code: -11,
				userInfo: [NSLocalizedDescriptionKey: "Mixed meeting recording has no audio duration."]
			)
		}

		if fileManager.fileExists(atPath: finalURL.path) {
			try fileManager.removeItem(at: finalURL)
		}
		try fileManager.moveItem(at: tempURL, to: finalURL)
		AppFileProtection.apply(to: finalURL)
		AppLog.shared.recording("Catalyst meeting recording mixed to M4A: \(finalURL.lastPathComponent), duration: \(exportedDuration)s")
	}

	private func addAudioTracks(
		from asset: AVURLAsset,
		to composition: AVMutableComposition,
		mixParameters: inout [AVAudioMixInputParameters],
		volume: Float,
		maxDuration: CMTime? = nil
	) async throws {
		let tracks = try await asset.loadTracks(withMediaType: .audio)
		let assetDuration = try await asset.load(.duration)
		guard assetDuration.isValid, assetDuration.seconds > 0 else { return }
		let duration: CMTime
		if let maxDuration, CMTimeCompare(assetDuration, maxDuration) > 0 {
			duration = maxDuration
		} else {
			duration = assetDuration
		}
		guard duration.isValid, duration.seconds > 0 else { return }

		for sourceTrack in tracks {
			guard let compositionTrack = composition.addMutableTrack(
				withMediaType: .audio,
				preferredTrackID: kCMPersistentTrackID_Invalid
			) else { continue }

			try compositionTrack.insertTimeRange(
				CMTimeRange(start: .zero, duration: duration),
				of: sourceTrack,
				at: .zero
			)
			let parameter = AVMutableAudioMixInputParameters(track: compositionTrack)
			parameter.setVolume(volume, at: .zero)
			mixParameters.append(parameter)
		}
	}
}

#endif
