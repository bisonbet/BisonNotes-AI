//
//  MacSystemAudioSynchronization.swift
//  BisonNotes AI
//
//  Deterministic state used to align native Mac microphone and system audio.
//

import CoreMedia
import Foundation

struct MacSystemAudioStartupGate {
	enum ReleaseReason: String, Equatable {
		case microphoneFirstWrite
		case safetyTimeout
	}

	struct Release: Equatable {
		let reason: ReleaseReason
		let elapsed: TimeInterval
	}

	private(set) var activeSessionID: UUID?
	private(set) var releaseReason: ReleaseReason?
	private var startedAt: Date?

	@discardableResult
	mutating func begin(
		sessionID: UUID = UUID(),
		at date: Date = Date()
	) -> UUID {
		activeSessionID = sessionID
		startedAt = date
		releaseReason = nil
		return sessionID
	}

	mutating func release(
		sessionID: UUID,
		reason: ReleaseReason,
		at date: Date = Date()
	) -> Release? {
		guard activeSessionID == sessionID,
		      releaseReason == nil,
		      let startedAt else { return nil }
		self.releaseReason = reason
		return Release(
			reason: reason,
			elapsed: max(0, date.timeIntervalSince(startedAt))
		)
	}

	@discardableResult
	mutating func cancel(sessionID: UUID? = nil) -> Bool {
		guard let activeSessionID else { return false }
		if let sessionID, sessionID != activeSessionID { return false }
		self.activeSessionID = nil
		startedAt = nil
		releaseReason = nil
		return true
	}
}

struct MacSystemAudioTimeline {
	struct Adjustment {
		let presentationTime: CMTime
		let startsWriterSession: Bool
	}

	private(set) var isPaused: Bool
	private(set) var accumulatedPausedDuration = CMTime.zero
	private var firstSampleTime: CMTime?
	private var lastAdjustedTime: CMTime?
	private var pauseStartedAt: CMTime?

	init(initiallyPaused: Bool = false) {
		isPaused = initiallyPaused
	}

	mutating func reset(initiallyPaused: Bool) {
		self = MacSystemAudioTimeline(initiallyPaused: initiallyPaused)
	}

	mutating func setPaused(_ paused: Bool, at sourceTime: CMTime) {
		guard paused != isPaused else { return }
		isPaused = paused
		if paused, sourceTime.isValid {
			pauseStartedAt = sourceTime
		}
	}

	mutating func adjustment(for sourceTime: CMTime) -> Adjustment? {
		guard sourceTime.isValid else { return nil }
		if isPaused {
			if pauseStartedAt == nil {
				pauseStartedAt = sourceTime
			}
			return nil
		}

		if let pauseStartedAt {
			// Before the first accepted sample, the system track has no timeline
			// origin yet. Its initial startup gate must not also be counted as an
			// ordinary pause or the gate duration would be subtracted twice.
			if firstSampleTime != nil {
				let pauseDuration = CMTimeSubtract(sourceTime, pauseStartedAt)
				if pauseDuration.isValid, pauseDuration.seconds > 0 {
					accumulatedPausedDuration = CMTimeAdd(accumulatedPausedDuration, pauseDuration)
				}
			}
			self.pauseStartedAt = nil
		}

		let startsWriterSession = firstSampleTime == nil
		if startsWriterSession {
			firstSampleTime = sourceTime
		}

		guard let firstSampleTime else { return nil }
		var adjustedTime = CMTimeSubtract(sourceTime, firstSampleTime)
		adjustedTime = CMTimeSubtract(adjustedTime, accumulatedPausedDuration)
		if adjustedTime < .zero {
			adjustedTime = .zero
		}
		if let lastAdjustedTime, adjustedTime <= lastAdjustedTime {
			return nil
		}
		self.lastAdjustedTime = adjustedTime
		return Adjustment(
			presentationTime: adjustedTime,
			startsWriterSession: startsWriterSession
		)
	}
}
