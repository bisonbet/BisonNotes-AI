//
//  AudioRecorderViewModel+MacEngine.swift
//  BisonNotes AI
//
//  Mac recording uses AVAudioEngine + AVAudioFile because
//  AVAudioRecorder cannot reliably set up its AAC/PCM converter on macOS.
//  The engine taps the input node directly, writes native PCM to a temporary
//  CAF file, then exports that file to the app's normal M4A recording URL.
//

#if os(macOS)

import Foundation
@preconcurrency import AVFoundation
import CoreGraphics

/// Builds the AVAudioEngine tap outside `AudioRecorderViewModel`'s MainActor
/// isolation. AVAudioEngine invokes this block on its real-time audio queue;
/// constructing it inside the MainActor-isolated view model causes Swift 6 to
/// emit a runtime executor precondition before the first statement executes.
private enum MacInputTapBlockFactory {
	static func make(
		file: AVAudioFile,
		captureHealth: RecordingCaptureHealth,
		onFirstWrite: @escaping @MainActor @Sendable () -> Void
	) -> AVAudioNodeTapBlock {
		{ buffer, _ in
			do {
				try file.write(from: buffer)
				let isFirstWrite = captureHealth.recordSuccessfulWrite(
					frameCount: Int64(buffer.frameLength)
				)
				if isFirstWrite {
					Task { @MainActor in
						onFirstWrite()
					}
				}
			} catch {
				if captureHealth.recordWriteFailure(error.localizedDescription) {
					AppLog.shared.recording(
						"Mac microphone file write failed: \(error.localizedDescription)",
						level: .error
					)
				}
			}
		}
	}
}

private enum MacMeetingAudioCaptureError: LocalizedError {
	case permissionUnavailable

	var errorDescription: String? {
		switch self {
		case .permissionUnavailable:
			return "Screen & System Audio Recording permission is not active. " +
				"Enable BisonNotes in System Settings, then quit and reopen the app"
		}
	}
}

extension AudioRecorderViewModel {
	// Keep the worst-case summed level below full scale while favoring nearby speech.
	private static let microphoneMeetingMixGain: Float = 0.5
	private static let systemMeetingMixGain: Float = 0.4

	@MainActor
	func setupMacRecording(at url: URL) async {
		var systemAudioError: Error?
		stopMacCaptureHealthMonitoring()
		macScratchSegmentURLs = []
		macAutomaticRecoveryAttempts = 0
		macAwaitingRecoveryBuffer = false
		macCaptureHealth.resetSession()
		macSystemAudioCapture = nil
		macSystemAudioURL = nil

		if isMacSystemAudioCaptureEnabled {
			if CGPreflightScreenCaptureAccess() {
				let systemAudioURL = Self.macSystemAudioURL(for: url)
				let capture = MacSystemAudioCapture(outputURL: systemAudioURL)
				do {
					try await capture.start()
					macSystemAudioCapture = capture
					macSystemAudioURL = systemAudioURL
				} catch {
					systemAudioError = error
					macSystemAudioCapture = nil
					macSystemAudioURL = nil
					AppLog.shared.recording("Mac system audio capture unavailable: \(error.localizedDescription)", level: .error)
				}
			} else {
				systemAudioError = MacMeetingAudioCaptureError.permissionUnavailable
				AppLog.shared.recording(
					"Mac system audio capture skipped because Screen & System Audio Recording " +
						"permission is not active",
					level: .error
				)
			}
		}

		do {
			// Mac: drive microphone recording with AVAudioEngine + AVAudioFile
			// so we bypass AVAudioRecorder's broken converter setup. The scratch
			// file is exported to M4A when recording stops.
			try startMacEngineRecording(at: url)

			if let systemAudioError {
				errorMessage = "Meeting audio could not be captured: \(systemAudioError.localizedDescription). Recording microphone audio only."
			}
		} catch {
			if let capture = macSystemAudioCapture {
				if let abandonedSystemAudioURL = try? await capture.stop() {
					try? FileManager.default.removeItem(at: abandonedSystemAudioURL)
				}
			}
			macSystemAudioCapture = nil
			macSystemAudioURL = nil
			finishRecordingStartup()
			errorMessage = "Failed to start recording: \(error.localizedDescription)"
			AppLog.shared.recording("Mac recording start failed: \(error.localizedDescription)", level: .error)
		}
	}

	/// Start recording on Mac using AVAudioEngine. Writes native PCM
	/// into a temporary CAF file, which is exported to the caller's M4A URL in
	/// `finalizeMacRecording(at:)`.
	func startMacEngineRecording(at url: URL) throws {
		// Tear down any leftover engine state from a previous run.
		stopMacEngineRecording(closingFile: false)

		// Native macOS uses Core Audio directly. AVAudioSession is an iOS API
		// and the Mac-only fallback must never run here.
		do {
			try startMacEnginePipeline(at: url)
		} catch {
			// The pipeline assigns its engine/file/scratch URL before the final start
			// call. If that call fails, release the partial state before the next retry.
			discardFailedMacCaptureState()
			throw error
		}
	}

	private func startMacEnginePipeline(
		at url: URL,
		scratchURL suppliedScratchURL: URL? = nil,
		removingFinalOutput: Bool = true
	) throws {
		let engine = AVAudioEngine()
		#if os(macOS)
		try enhancedAudioSessionManager.configureInputDevice(for: engine)
		#endif
		let inputNode = engine.inputNode
		// Apple documents the input-scope format as the hardware-availability
		// check. The output format can remain populated while a USB input route
		// is present but not actually delivering microphone buffers.
		let hardwareInputFormat = inputNode.inputFormat(forBus: 0)
		let inputFormat = inputNode.outputFormat(forBus: 0)

		guard hardwareInputFormat.sampleRate > 0, hardwareInputFormat.channelCount > 0,
		      inputFormat.sampleRate > 0, inputFormat.channelCount > 0 else {
			throw NSError(
				domain: "AudioRecorderViewModel.Mac",
				code: -1,
				userInfo: [NSLocalizedDescriptionKey: "Microphone input is not enabled — check macOS Sound input settings."]
			)
		}

		let scratchURL = suppliedScratchURL ?? Self.macScratchURL(for: url)
		let fileManager = FileManager.default
		if fileManager.fileExists(atPath: scratchURL.path) {
			try fileManager.removeItem(at: scratchURL)
		}
		if removingFinalOutput, fileManager.fileExists(atPath: url.path) {
			try fileManager.removeItem(at: url)
		}

		let audioFile = try AVAudioFile(forWriting: scratchURL, settings: inputFormat.settings)
		AppFileProtection.apply(to: scratchURL)

		macAudioEngine = engine
		macAudioFile = audioFile
		macEngineFormat = inputFormat
		macScratchRecordingURL = scratchURL
		macCaptureHealth.beginSegment()

		installMacInputTap()

		engine.prepare()
		try engine.start()
		guard engine.isRunning else {
			throw NSError(
				domain: "AudioRecorderViewModel.Mac",
				code: -9,
				userInfo: [NSLocalizedDescriptionKey: "The microphone engine did not remain running."]
			)
		}
		startMacCaptureHealthMonitoring()
		AppLog.shared.recording(
			"Mac microphone engine started; awaiting first buffer " +
			"(hardwareSampleRate=\(hardwareInputFormat.sampleRate), " +
			"hardwareChannels=\(hardwareInputFormat.channelCount), " +
			"sampleRate=\(inputFormat.sampleRate), channels=\(inputFormat.channelCount), " +
			"interleaved=\(inputFormat.isInterleaved))"
		)
	}

	/// Pause Mac recording: remove the input tap so the file stops
	/// receiving samples. The engine and file stay alive so resume can
	/// continue writing to the same file.
	func pauseMacEngineRecording() {
		guard let engine = macAudioEngine else { return }
		engine.inputNode.removeTap(onBus: 0)
		macSystemAudioCapture?.setPaused(true)
		stopMacCaptureHealthMonitoring()
		macCaptureHealth.suspend()
	}

	/// Resume Mac recording: re-install the tap on the same input node,
	/// writing into the same AVAudioFile that was opened in `start...`.
	func resumeMacEngineRecording() throws {
		guard macAudioEngine != nil, macAudioFile != nil else {
			throw NSError(
				domain: "AudioRecorderViewModel.Mac",
				code: -2,
				userInfo: [NSLocalizedDescriptionKey: "Engine state was lost; cannot resume."]
			)
		}
		macCaptureHealth.beginSegment()
		installMacInputTap()
		macSystemAudioCapture?.setPaused(false)
		startMacCaptureHealthMonitoring()
	}

	/// Fully stop Mac recording. Closes the scratch file (via deinit) and
	/// tears down the engine. The final M4A is produced later in
	/// `finalizeMacRecording(at:)`.
	func stopMacEngineRecording(closingFile: Bool = true) {
		stopMacCaptureHealthMonitoring()
		let health = macCaptureHealth.snapshot()
		let hasCaptureState = macAudioEngine != nil || macAudioFile != nil || macScratchRecordingURL != nil
		if hasCaptureState {
			AppLog.shared.recording(
				"Mac microphone engine stopping " +
				"(segmentFrames=\(health.segmentFramesWritten), totalFrames=\(health.totalFramesWritten))",
				level: health.totalFramesWritten > 0 ? .info : .error
			)
		}
		if let engine = macAudioEngine {
			engine.inputNode.removeTap(onBus: 0)
			if engine.isRunning {
				engine.stop()
			}
		}
		macAudioEngine = nil
		macEngineFormat = nil
		#if os(macOS)
		enhancedAudioSessionManager.clearConfiguredInputDevice()
		#endif
		if closingFile {
			macAudioFile = nil
		}
	}

	/// Releases the state left behind by a failed pipeline start. The scratch file
	/// only ever holds a CAF header at this point — no buffer reached the tap — so it
	/// is deleted rather than kept: leaving the URL set would leak the temp file and
	/// make the next start believe a capture is still in flight.
	func discardFailedMacCaptureState() {
		let failedScratchURL = macScratchRecordingURL
		stopMacEngineRecording()
		if let failedScratchURL {
			try? FileManager.default.removeItem(at: failedScratchURL)
		}
		macScratchRecordingURL = nil
	}

	/// Closes the current PCM segment without discarding it. A replacement input
	/// may expose a different native format, so recovery always starts a new CAF.
	func sealMacScratchSegment() {
		let currentScratchURL = macScratchRecordingURL
		stopMacEngineRecording()
		if let currentScratchURL,
		   FileManager.default.fileExists(atPath: currentScratchURL.path),
		   !macScratchSegmentURLs.contains(currentScratchURL) {
			macScratchSegmentURLs.append(currentScratchURL)
		}
		macScratchRecordingURL = nil
	}

	/// Starts the next PCM segment on the currently resolved Core Audio input.
	/// The original final URL is retained for the normal stop/finalize flow.
	func startMacContinuation(at finalURL: URL) throws {
		let segmentIndex = macScratchSegmentURLs.count + 1
		let scratchURL = Self.macScratchURL(for: finalURL, segmentIndex: segmentIndex)
		try startMacEnginePipeline(
			at: finalURL,
			scratchURL: scratchURL,
			removingFinalOutput: false
		)
	}

	#if os(macOS)
	func sealNativeMacScratchSegment() {
		sealMacScratchSegment()
	}

	func startNativeMacContinuation(at finalURL: URL) throws {
		try startMacContinuation(at: finalURL)
	}
	#endif

	func stopMacSystemAudioCapture() async -> URL? {
		guard let capture = macSystemAudioCapture else {
			return macSystemAudioURL
		}

		do {
			let capturedURL = try await capture.stop()
			macSystemAudioCapture = nil
			macSystemAudioURL = capturedURL
			return capturedURL
		} catch {
			AppLog.shared.recording("Mac system audio capture finalize failed: \(error.localizedDescription)", level: .error)
			macSystemAudioCapture = nil
			let partialURL = macSystemAudioURL.flatMap { url in
				FileManager.default.fileExists(atPath: url.path) ? url : nil
			}
			macSystemAudioURL = partialURL
			return partialURL
		}
	}

	private func installMacInputTap() {
		guard let engine = macAudioEngine,
		      let format = macEngineFormat,
		      let file = macAudioFile else { return }
		let captureHealth = macCaptureHealth
		let handleFirstSuccessfulWrite: @MainActor @Sendable () -> Void = { [weak self] in
			self?.handleMacFirstSuccessfulWrite()
		}
		let tapBlock = MacInputTapBlockFactory.make(
			file: file,
			captureHealth: captureHealth,
			onFirstWrite: handleFirstSuccessfulWrite
		)

		// The scratch file uses the input node's native PCM format, so the tap
		// can write each buffer directly without invoking a compressed encoder
		// from the real-time audio callback.
		engine.inputNode.installTap(
			onBus: 0,
			bufferSize: 4096,
			format: format,
			block: tapBlock
		)
	}

	private static func macScratchURL(for finalURL: URL, segmentIndex: Int? = nil) -> URL {
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

	private static func macSystemAudioURL(for finalURL: URL) -> URL {
		FileManager.default.temporaryDirectory
			.appendingPathComponent("\(finalURL.deletingPathExtension().lastPathComponent)-system")
			.appendingPathExtension("m4a")
	}

	func exportMacScratchRecording(from scratchURL: URL, to finalURL: URL) async throws {
		let fileManager = FileManager.default
		guard fileManager.fileExists(atPath: scratchURL.path) else {
			throw NSError(
				domain: "AudioRecorderViewModel.Mac",
				code: -3,
				userInfo: [NSLocalizedDescriptionKey: "Temporary recording file does not exist."]
			)
		}

		let sourceAsset = AVURLAsset(url: scratchURL)
		let sourceDuration = try await sourceAsset.load(.duration).seconds
		guard sourceDuration.isFinite, sourceDuration > 0 else {
			throw NSError(
				domain: "AudioRecorderViewModel.Mac",
				code: -4,
				userInfo: [NSLocalizedDescriptionKey: "Temporary recording has no audio duration."]
			)
		}

		guard !(try await sourceAsset.loadTracks(withMediaType: .audio)).isEmpty else {
			throw NSError(
				domain: "AudioRecorderViewModel.Mac",
				code: -5,
				userInfo: [NSLocalizedDescriptionKey: "Temporary recording has no audio track."]
			)
		}

		guard let exportSession = AVAssetExportSession(asset: sourceAsset, presetName: AVAssetExportPresetAppleM4A) else {
			throw NSError(
				domain: "AudioRecorderViewModel.Mac",
				code: -6,
				userInfo: [NSLocalizedDescriptionKey: "Could not create audio export session."]
			)
		}

		// Export into the temp directory, not the recordings directory: a stray
		// `.m4a` left there by a failed/killed export would be misread as an
		// orphaned recording by EnhancedFileManager's documents-directory scan.
		let tempURL = fileManager.temporaryDirectory
			.appendingPathComponent("mac_export_\(UUID().uuidString).m4a")

		if fileManager.fileExists(atPath: tempURL.path) {
			try fileManager.removeItem(at: tempURL)
		}

		try await exportSession.export(to: tempURL, as: .m4a)
		AppFileProtection.apply(to: tempURL)

		let attributes = try fileManager.attributesOfItem(atPath: tempURL.path)
		let exportedSize = attributes[.size] as? Int64 ?? 0
		guard exportedSize > 0 else {
			throw NSError(
				domain: "AudioRecorderViewModel.Mac",
				code: -7,
				userInfo: [NSLocalizedDescriptionKey: "Exported recording file is empty."]
			)
		}

		let exportedAsset = AVURLAsset(url: tempURL)
		let exportedDuration = try await exportedAsset.load(.duration).seconds
		guard exportedDuration.isFinite, exportedDuration > 0 else {
			throw NSError(
				domain: "AudioRecorderViewModel.Mac",
				code: -8,
				userInfo: [NSLocalizedDescriptionKey: "Exported recording has no audio duration."]
			)
		}

		if fileManager.fileExists(atPath: finalURL.path) {
			try fileManager.removeItem(at: finalURL)
		}
		try fileManager.moveItem(at: tempURL, to: finalURL)
		AppFileProtection.apply(to: finalURL)

		AppLog.shared.recording(
			"Mac recording exported to M4A: \(finalURL.lastPathComponent), " +
				"duration: \(exportedDuration)s, size: \(exportedSize) bytes"
		)
	}

	func exportMacScratchRecordings(from scratchURLs: [URL], to finalURL: URL) async throws {
		guard scratchURLs.count > 1 else {
			guard let scratchURL = scratchURLs.first else {
				throw NSError(
					domain: "AudioRecorderViewModel.Mac",
					code: -13,
					userInfo: [NSLocalizedDescriptionKey: "No temporary recording segments were available."]
				)
			}
			try await exportMacScratchRecording(from: scratchURL, to: finalURL)
			return
		}

		let (composition, insertionTime) = try await makeRecoveredMicrophoneComposition(from: scratchURLs)
		guard insertionTime.isValid, insertionTime.seconds > 0,
		      let exportSession = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetAppleM4A) else {
			throw NSError(
				domain: "AudioRecorderViewModel.Mac",
				code: -15,
				userInfo: [NSLocalizedDescriptionKey: "Recovered microphone segments contained no audio."]
			)
		}

		let fileManager = FileManager.default
		let tempURL = fileManager.temporaryDirectory
			.appendingPathComponent("mac_segments_\(UUID().uuidString).m4a")
		try await exportSession.export(to: tempURL, as: .m4a)
		let attributes = try fileManager.attributesOfItem(atPath: tempURL.path)
		let exportedSize = attributes[.size] as? Int64 ?? 0
		let exportedDuration = try await AVURLAsset(url: tempURL).load(.duration).seconds
		guard exportedSize > 0, exportedDuration.isFinite, exportedDuration > 0 else {
			try? fileManager.removeItem(at: tempURL)
			throw NSError(
				domain: "AudioRecorderViewModel.Mac",
				code: -16,
				userInfo: [NSLocalizedDescriptionKey: "Recovered microphone export was empty."]
			)
		}
		if fileManager.fileExists(atPath: finalURL.path) {
			try fileManager.removeItem(at: finalURL)
		}
		try fileManager.moveItem(at: tempURL, to: finalURL)
		AppFileProtection.apply(to: finalURL)
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
				domain: "AudioRecorderViewModel.Mac",
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

	func exportAndMixMacRecording(
		microphoneScratchURLs: [URL],
		systemAudioURL: URL,
		finalURL: URL
	) async throws {
		do {
			try await mixMacAudioTracks(
				microphoneScratchURLs: microphoneScratchURLs,
				systemAudioURL: systemAudioURL,
				finalURL: finalURL
			)
		} catch let mixError {
			AppLog.shared.recording(
				"Mac meeting audio mix failed; trying microphone-only salvage: " +
				"\(mixError.localizedDescription)",
				level: .error
			)
			do {
				try await exportMacScratchRecordings(from: microphoneScratchURLs, to: finalURL)
				errorMessage = "Meeting audio could not be mixed. Saved microphone audio only."
			} catch let microphoneError {
				AppLog.shared.recording(
					"Microphone-only salvage failed; trying system-audio-only salvage: " +
					"\(microphoneError.localizedDescription)",
					level: .error
				)
				try await exportMacScratchRecording(from: systemAudioURL, to: finalURL)
				errorMessage = "The microphone track could not be saved. Saved meeting/system audio only."
			}
		}
	}

	private func mixMacAudioTracks(
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
				domain: "AudioRecorderViewModel.Mac",
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
				domain: "AudioRecorderViewModel.Mac",
				code: -9,
				userInfo: [NSLocalizedDescriptionKey: "No audio tracks were available to mix."]
			)
		}

		let audioMix = AVMutableAudioMix()
		audioMix.inputParameters = mixParameters

		guard let exportSession = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetAppleM4A) else {
			throw NSError(
				domain: "AudioRecorderViewModel.Mac",
				code: -10,
				userInfo: [NSLocalizedDescriptionKey: "Could not create meeting audio export session."]
			)
		}
		exportSession.audioMix = audioMix
		exportSession.timeRange = CMTimeRange(start: .zero, duration: microphoneDuration)

		let tempURL = fileManager.temporaryDirectory
			.appendingPathComponent("mac_meeting_mix_\(UUID().uuidString).m4a")
		if fileManager.fileExists(atPath: tempURL.path) {
			try fileManager.removeItem(at: tempURL)
		}

		try await exportSession.export(to: tempURL, as: .m4a)
		AppFileProtection.apply(to: tempURL)

		let exportedAsset = AVURLAsset(url: tempURL)
		let exportedDuration = try await exportedAsset.load(.duration).seconds
		guard exportedDuration.isFinite, exportedDuration > 0 else {
			throw NSError(
				domain: "AudioRecorderViewModel.Mac",
				code: -11,
				userInfo: [NSLocalizedDescriptionKey: "Mixed meeting recording has no audio duration."]
			)
		}

		if fileManager.fileExists(atPath: finalURL.path) {
			try fileManager.removeItem(at: finalURL)
		}
		try fileManager.moveItem(at: tempURL, to: finalURL)
		AppFileProtection.apply(to: finalURL)
		AppLog.shared.recording(
			"Mac meeting recording mixed to M4A: \(finalURL.lastPathComponent), " +
				"duration: \(exportedDuration)s"
		)
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
