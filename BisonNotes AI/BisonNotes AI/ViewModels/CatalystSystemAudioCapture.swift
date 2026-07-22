//
//  CatalystSystemAudioCapture.swift
//  BisonNotes AI
//
//  Captures Mac system/application audio through ScreenCaptureKit while the
//  existing Mac microphone recorder continues to capture local speech.
//

#if targetEnvironment(macCatalyst) || os(macOS)

import Foundation
@preconcurrency import AVFoundation
import CoreMedia
import ScreenCaptureKit

final class CatalystSystemAudioCapture: NSObject, SCStreamOutput, SCStreamDelegate {
	private let outputURL: URL
	private let sampleQueue = DispatchQueue(label: "com.bisonnotesai.catalyst-system-audio")
	private let discardedVideoQueue = DispatchQueue(label: "com.bisonnotesai.catalyst-system-video-discard")

	private var stream: SCStream?
	private var assetWriter: AVAssetWriter?
	private var audioInput: AVAssetWriterInput?
	private var firstSampleTime: CMTime?
	private var lastSourceTime: CMTime?
	private var lastAdjustedTime: CMTime?
	private var pauseStartedAt: CMTime?
	private var accumulatedPausedDuration = CMTime.zero
	private var didReceiveAudio = false
	private var audibleAudioDuration: Double = 0
	private var isPaused = false
	private var stopError: Error?

	private static let audibleAmplitudeThreshold: Float = 0.001
	private static let minimumAudibleDuration = 0.05

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

		let config = Self.makeSystemAudioConfiguration()

		let filter = SCContentFilter(display: display, excludingWindows: [])
		let stream = SCStream(filter: filter, configuration: config, delegate: self)
		try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: discardedVideoQueue)
		try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: sampleQueue)

		self.assetWriter = writer
		self.audioInput = input
		self.stream = stream

		try await stream.startCapture()
		AppLog.shared.recording("Catalyst system audio capture started")
	}

	private static func makeSystemAudioConfiguration() -> SCStreamConfiguration {
		let config = SCStreamConfiguration()
		// ScreenCaptureKit always produces a screen stream, even when the app only
		// needs system audio. The tiny no-op screen output prevents repeated
		// "stream output NOT found" logs for otherwise-unclaimed video frames.
		config.width = 2
		config.height = 2
		config.minimumFrameInterval = CMTime(value: 1, timescale: 1)
		config.queueDepth = 3
		config.capturesAudio = true
		config.excludesCurrentProcessAudio = true
		config.sampleRate = 48_000
		config.channelCount = 2
		return config
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
		      audibleAudioDuration >= Self.minimumAudibleDuration,
		      fileManager.fileExists(atPath: outputURL.path),
		      (try? fileManager.attributesOfItem(atPath: outputURL.path)[.size] as? Int64) ?? 0 > 0 else {
			try? fileManager.removeItem(at: outputURL)
			AppLog.shared.recording(
				"Catalyst system audio capture contained no sustained audible signal; " +
				"continuing with microphone recording only",
				level: .debug
			)
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
			if Self.containsAudibleSignal(sampleBuffer) {
				let duration = CMSampleBufferGetDuration(sampleBuffer).seconds
				if duration.isFinite, duration > 0 {
					audibleAudioDuration += duration
				} else if let formatDescription = CMSampleBufferGetFormatDescription(sampleBuffer),
				          let streamDescription = CMAudioFormatDescriptionGetStreamBasicDescription(formatDescription) {
					let sampleRate = streamDescription.pointee.mSampleRate
					if sampleRate > 0 {
						audibleAudioDuration += Double(CMSampleBufferGetNumSamples(sampleBuffer)) / sampleRate
					}
				}
			}
		} else if let error = writer.error {
			stopError = error
			AppLog.shared.recording("Catalyst system audio append failed: \(error.localizedDescription)", level: .error)
		}
	}

	private static func containsAudibleSignal(_ sampleBuffer: CMSampleBuffer) -> Bool {
		guard let formatDescription = CMSampleBufferGetFormatDescription(sampleBuffer),
		      let streamDescription = CMAudioFormatDescriptionGetStreamBasicDescription(formatDescription) else {
			// Preserve unknown formats rather than risk dropping real system audio.
			return true
		}

		let format = streamDescription.pointee
		guard format.mFormatID == kAudioFormatLinearPCM else { return true }

		var bufferListSize = 0
		let sizeStatus = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
			sampleBuffer,
			bufferListSizeNeededOut: &bufferListSize,
			bufferListOut: nil,
			bufferListSize: 0,
			blockBufferAllocator: nil,
			blockBufferMemoryAllocator: nil,
			flags: 0,
			blockBufferOut: nil
		)
		guard sizeStatus == noErr, bufferListSize > 0 else { return true }

		let rawBufferList = UnsafeMutableRawPointer.allocate(
			byteCount: bufferListSize,
			alignment: MemoryLayout<AudioBufferList>.alignment
		)
		defer { rawBufferList.deallocate() }
		let audioBufferList = rawBufferList.bindMemory(to: AudioBufferList.self, capacity: 1)
		var retainedBlockBuffer: CMBlockBuffer?
		let listStatus = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
			sampleBuffer,
			bufferListSizeNeededOut: nil,
			bufferListOut: audioBufferList,
			bufferListSize: bufferListSize,
			blockBufferAllocator: nil,
			blockBufferMemoryAllocator: nil,
			flags: 0,
			blockBufferOut: &retainedBlockBuffer
		)
		guard listStatus == noErr else { return true }

		let isFloat = format.mFormatFlags & kAudioFormatFlagIsFloat != 0
		let isSignedInteger = format.mFormatFlags & kAudioFormatFlagIsSignedInteger != 0
		let bufferCount = Int(audioBufferList.pointee.mNumberBuffers)

		return withUnsafeMutablePointer(to: &audioBufferList.pointee.mBuffers) { firstBuffer in
			for bufferIndex in 0..<bufferCount {
				let buffer = firstBuffer[bufferIndex]
				guard let data = buffer.mData else { continue }
				let byteCount = Int(buffer.mDataByteSize)
				if isFloat, format.mBitsPerChannel == 32 {
					let samples = data.bindMemory(to: Float.self, capacity: byteCount / MemoryLayout<Float>.size)
					for index in 0..<(byteCount / MemoryLayout<Float>.size)
					where abs(samples[index]) >= audibleAmplitudeThreshold {
						return true
					}
				} else if isSignedInteger, format.mBitsPerChannel == 16 {
					let samples = data.bindMemory(to: Int16.self, capacity: byteCount / MemoryLayout<Int16>.size)
					let threshold = Int16(Float(Int16.max) * audibleAmplitudeThreshold)
					for index in 0..<(byteCount / MemoryLayout<Int16>.size)
					where abs(Int(samples[index])) >= Int(threshold) {
						return true
					}
				} else if isSignedInteger, format.mBitsPerChannel == 32 {
					let samples = data.bindMemory(to: Int32.self, capacity: byteCount / MemoryLayout<Int32>.size)
					let threshold = Int64(Float(Int32.max) * audibleAmplitudeThreshold)
					for index in 0..<(byteCount / MemoryLayout<Int32>.size)
					where abs(Int64(samples[index])) >= threshold {
						return true
					}
				} else {
					return true
				}
			}
			return false
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
