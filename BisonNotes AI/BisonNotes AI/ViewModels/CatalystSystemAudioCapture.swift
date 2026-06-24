//
//  CatalystSystemAudioCapture.swift
//  BisonNotes AI
//
//  Captures Mac system/application audio through ScreenCaptureKit while the
//  existing Catalyst microphone recorder continues to capture local speech.
//

#if targetEnvironment(macCatalyst)

import Foundation
@preconcurrency import AVFoundation
import CoreMedia
import ScreenCaptureKit

final class CatalystSystemAudioCapture: NSObject, SCStreamOutput, SCStreamDelegate {
	private let outputURL: URL
	private let sampleQueue = DispatchQueue(label: "com.bisonnotesai.catalyst-system-audio")

	private var stream: SCStream?
	private var assetWriter: AVAssetWriter?
	private var audioInput: AVAssetWriterInput?
	private var firstSampleTime: CMTime?
	private var lastSourceTime: CMTime?
	private var lastAdjustedTime: CMTime?
	private var pauseStartedAt: CMTime?
	private var accumulatedPausedDuration = CMTime.zero
	private var didReceiveAudio = false
	private var isPaused = false
	private var stopError: Error?

	init(outputURL: URL) {
		self.outputURL = outputURL
		super.init()
	}

	func start() async throws {
		let fileManager = FileManager.default
		if fileManager.fileExists(atPath: outputURL.path) {
			try fileManager.removeItem(at: outputURL)
		}

		let writer = try AVAssetWriter(outputURL: outputURL, fileType: .m4a)
		let input = AVAssetWriterInput(
			mediaType: .audio,
			outputSettings: [
				AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
				AVSampleRateKey: 48_000,
				AVNumberOfChannelsKey: 2,
				AVEncoderBitRateKey: 128_000
			]
		)
		input.expectsMediaDataInRealTime = true

		guard writer.canAdd(input) else {
			throw NSError(
				domain: "CatalystSystemAudioCapture",
				code: -1,
				userInfo: [NSLocalizedDescriptionKey: "System audio writer could not accept an audio input."]
			)
		}
		writer.add(input)
		guard writer.startWriting() else {
			throw writer.error ?? NSError(
				domain: "CatalystSystemAudioCapture",
				code: -2,
				userInfo: [NSLocalizedDescriptionKey: "System audio writer could not start."]
			)
		}

		let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
		guard let display = content.displays.first else {
			throw NSError(
				domain: "CatalystSystemAudioCapture",
				code: -3,
				userInfo: [NSLocalizedDescriptionKey: "No Mac display is available for system audio capture."]
			)
		}

		let config = SCStreamConfiguration()
		config.width = max(display.width, 2)
		config.height = max(display.height, 2)
		config.minimumFrameInterval = CMTime(value: 1, timescale: 2)
		config.queueDepth = 3
		config.capturesAudio = true
		config.excludesCurrentProcessAudio = true
		config.sampleRate = 48_000
		config.channelCount = 2

		let filter = SCContentFilter(display: display, excludingWindows: [])
		let stream = SCStream(filter: filter, configuration: config, delegate: self)
		try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: sampleQueue)

		self.assetWriter = writer
		self.audioInput = input
		self.stream = stream

		try await stream.startCapture()
		AppLog.shared.recording("Catalyst system audio capture started")
	}

	func setPaused(_ paused: Bool) {
		sampleQueue.async { [weak self] in
			guard let self else { return }
			guard self.isPaused != paused else { return }
			self.isPaused = paused
			if paused {
				self.pauseStartedAt = self.lastSourceTime
			}
		}
	}

	func stop() async throws -> URL? {
		if let stream {
			do {
				try await stream.stopCapture()
			} catch {
				AppLog.shared.recording("Catalyst system audio capture stop failed: \(error.localizedDescription)", level: .error)
			}
		}

		await performOnSampleQueue { [weak self] in
			self?.audioInput?.markAsFinished()
		}

		if let writer = assetWriter {
			await finish(writer)
		}

		stream = nil
		assetWriter = nil
		audioInput = nil

		if let stopError {
			throw stopError
		}

		let fileManager = FileManager.default
		guard didReceiveAudio,
		      fileManager.fileExists(atPath: outputURL.path),
		      (try? fileManager.attributesOfItem(atPath: outputURL.path)[.size] as? Int64) ?? 0 > 0 else {
			try? fileManager.removeItem(at: outputURL)
			AppLog.shared.recording("Catalyst system audio capture produced no audio; continuing with microphone recording only", level: .debug)
			return nil
		}

		AppFileProtection.apply(to: outputURL)
		return outputURL
	}

	func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
		guard type == .audio else { return }
		guard CMSampleBufferDataIsReady(sampleBuffer) else { return }
		guard let writer = assetWriter,
		      let input = audioInput,
		      writer.status == .writing else { return }

		let sourceTime = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
		guard sourceTime.isValid else { return }
		lastSourceTime = sourceTime

		if isPaused {
			if pauseStartedAt == nil {
				pauseStartedAt = sourceTime
			}
			return
		}

		if let pauseStartedAt {
			let pauseDuration = CMTimeSubtract(sourceTime, pauseStartedAt)
			if pauseDuration.isValid, pauseDuration.seconds > 0 {
				accumulatedPausedDuration = CMTimeAdd(accumulatedPausedDuration, pauseDuration)
			}
			self.pauseStartedAt = nil
		}

		if firstSampleTime == nil {
			firstSampleTime = sourceTime
			writer.startSession(atSourceTime: .zero)
		}

		guard let firstSampleTime else { return }
		var adjustedTime = CMTimeSubtract(sourceTime, firstSampleTime)
		adjustedTime = CMTimeSubtract(adjustedTime, accumulatedPausedDuration)
		if adjustedTime < .zero {
			adjustedTime = .zero
		}
		if let lastAdjustedTime, adjustedTime <= lastAdjustedTime {
			return
		}
		self.lastAdjustedTime = adjustedTime

		guard input.isReadyForMoreMediaData else { return }
		guard let retimedBuffer = copy(sampleBuffer, withPresentationTime: adjustedTime) else { return }

		if input.append(retimedBuffer) {
			didReceiveAudio = true
		} else if let error = writer.error {
			stopError = error
			AppLog.shared.recording("Catalyst system audio append failed: \(error.localizedDescription)", level: .error)
		}
	}

	func stream(_ stream: SCStream, didStopWithError error: Error) {
		stopError = error
		AppLog.shared.recording("Catalyst system audio stream stopped with error: \(error.localizedDescription)", level: .error)
	}

	private func copy(_ sampleBuffer: CMSampleBuffer, withPresentationTime presentationTime: CMTime) -> CMSampleBuffer? {
		let sampleCount = CMSampleBufferGetNumSamples(sampleBuffer)
		let duration = CMSampleBufferGetDuration(sampleBuffer)
		let sampleDuration: CMTime
		if duration.isValid, sampleCount > 0 {
			sampleDuration = CMTime(value: duration.value, timescale: duration.timescale * CMTimeScale(sampleCount))
		} else {
			sampleDuration = .invalid
		}

		var timing = CMSampleTimingInfo(
			duration: sampleDuration,
			presentationTimeStamp: presentationTime,
			decodeTimeStamp: .invalid
		)
		var copiedBuffer: CMSampleBuffer?
		let status = CMSampleBufferCreateCopyWithNewTiming(
			allocator: kCFAllocatorDefault,
			sampleBuffer: sampleBuffer,
			sampleTimingEntryCount: 1,
			sampleTimingArray: &timing,
			sampleBufferOut: &copiedBuffer
		)
		if status != noErr {
			AppLog.shared.recording("Catalyst system audio retiming failed: \(status)", level: .error)
			return nil
		}
		return copiedBuffer
	}

	private func finish(_ writer: AVAssetWriter) async {
		await withCheckedContinuation { continuation in
			writer.finishWriting {
				continuation.resume()
			}
		}
	}

	private func performOnSampleQueue(_ work: @escaping () -> Void) async {
		await withCheckedContinuation { continuation in
			sampleQueue.async {
				work()
				continuation.resume()
			}
		}
	}
}

#endif
