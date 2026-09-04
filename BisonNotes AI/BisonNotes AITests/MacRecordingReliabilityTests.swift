//
//  MacRecordingReliabilityTests.swift
//  BisonNotes AITests
//

import Foundation
import CoreMedia
import XCTest
@testable import BisonNotes_AI

final class MacRecordingReliabilityTests: XCTestCase {
	func testRecordingInputSelectionPreservesPreferenceThenTriesMeetingBridge() {
		let candidates = [
			MacRecordingInputCandidate(deviceID: 7, name: "MacBook Microphone"),
			MacRecordingInputCandidate(deviceID: 9, name: "ZoomAudioDevice"),
			MacRecordingInputCandidate(deviceID: 5, name: "Poly Sync 10")
		]

		XCTAssertEqual(
			MacRecordingInputSelection.orderedDeviceIDs(
				preferredDeviceID: 7,
				defaultDeviceID: 5,
				available: candidates
			),
			[7, 5, 9]
		)
	}

	func testRecordingInputSelectionRetainsDefaultWhenDiscoveryIsTemporarilyBehind() {
		XCTAssertEqual(
			MacRecordingInputSelection.orderedDeviceIDs(
				preferredDeviceID: 11,
				defaultDeviceID: 13,
				available: []
			),
			[13]
		)
	}

	/// A microphone that just stopped producing audio must not be retried, or the
	/// fallback would keep picking the device that is already failing.
	func testFailedInputIsExcludedFromItsOwnRetry() {
		XCTAssertEqual(
			MacRecordingInputSelection.excludedDeviceID(
				currentInputDeviceID: 7,
				trigger: .currentInputFailed
			),
			7
		)
	}

	/// Core Audio can reuse a device ID when a microphone is plugged back in, and
	/// the failure path never clears the ID the recording was bound to. Carrying
	/// the exclusion into the reconnection filtered the returning microphone out of
	/// its own recovery, leaving a recording with no other input stuck in
	/// `waitingForMicrophone` for the rest of the session.
	func testReconnectedInputIsNotExcludedFromRecovery() {
		XCTAssertNil(
			MacRecordingInputSelection.excludedDeviceID(
				currentInputDeviceID: 7,
				trigger: .deviceBecameAvailable
			)
		)
	}

	/// With nothing excluded, a returning microphone is a candidate again even when
	/// it is the only input present — the case that used to strand the recording.
	func testSoleReconnectedMicrophoneRemainsACandidate() {
		let excluded = MacRecordingInputSelection.excludedDeviceID(
			currentInputDeviceID: 7,
			trigger: .deviceBecameAvailable
		)
		let candidates = MacRecordingInputSelection.orderedDeviceIDs(
			preferredDeviceID: 7,
			defaultDeviceID: 7,
			available: [MacRecordingInputCandidate(deviceID: 7, name: "MacBook Microphone")]
		)

		XCTAssertEqual(candidates.filter { $0 != excluded }, [7])
	}

	func testSystemAudioStartupGateReleasesExactlyOnceForMicrophoneWrite() {
		var gate = MacSystemAudioStartupGate()
		let sessionID = UUID()
		let startedAt = Date(timeIntervalSince1970: 10)
		gate.begin(sessionID: sessionID, at: startedAt)

		let release = gate.release(
			sessionID: sessionID,
			reason: .microphoneFirstWrite,
			at: startedAt.addingTimeInterval(0.25)
		)

		XCTAssertEqual(release?.reason, .microphoneFirstWrite)
		XCTAssertEqual(release?.elapsed, 0.25)
		XCTAssertNil(
			gate.release(
				sessionID: sessionID,
				reason: .safetyTimeout,
				at: startedAt.addingTimeInterval(1.5)
			)
		)
	}

	func testSystemAudioStartupGateTimeoutWinsRaceExactlyOnce() {
		var gate = MacSystemAudioStartupGate()
		let sessionID = gate.begin(at: Date(timeIntervalSince1970: 20))

		XCTAssertEqual(
			gate.release(
				sessionID: sessionID,
				reason: .safetyTimeout,
				at: Date(timeIntervalSince1970: 21.5)
			)?.reason,
			.safetyTimeout
		)
		XCTAssertNil(
			gate.release(
				sessionID: sessionID,
				reason: .microphoneFirstWrite,
				at: Date(timeIntervalSince1970: 21.5)
			)
		)
	}

	func testSystemAudioStartupGateRejectsStaleSessionTimeout() {
		var gate = MacSystemAudioStartupGate()
		let staleSessionID = gate.begin(at: Date(timeIntervalSince1970: 30))
		let currentSessionID = gate.begin(at: Date(timeIntervalSince1970: 31))

		XCTAssertNil(
			gate.release(
				sessionID: staleSessionID,
				reason: .safetyTimeout,
				at: Date(timeIntervalSince1970: 32)
			)
		)
		XCTAssertEqual(gate.activeSessionID, currentSessionID)
		XCTAssertNil(gate.releaseReason)
	}

	func testInitialSystemAudioGateDoesNotDoubleSubtractTime() throws {
		var timeline = MacSystemAudioTimeline(initiallyPaused: true)
		XCTAssertNil(timeline.adjustment(for: CMTime(seconds: 10, preferredTimescale: 48_000)))

		timeline.setPaused(false, at: CMTime(seconds: 11.5, preferredTimescale: 48_000))
		let first = try XCTUnwrap(
			timeline.adjustment(for: CMTime(seconds: 11.5, preferredTimescale: 48_000))
		)
		let second = try XCTUnwrap(
			timeline.adjustment(for: CMTime(seconds: 11.6, preferredTimescale: 48_000))
		)

		XCTAssertTrue(first.startsWriterSession)
		XCTAssertEqual(first.presentationTime.seconds, 0, accuracy: 0.000_001)
		XCTAssertEqual(second.presentationTime.seconds, 0.1, accuracy: 0.000_001)
		XCTAssertEqual(timeline.accumulatedPausedDuration.seconds, 0, accuracy: 0.000_001)
	}

	func testOrdinarySystemAudioPauseIsRemovedFromTimeline() throws {
		var timeline = MacSystemAudioTimeline()
		_ = try XCTUnwrap(timeline.adjustment(for: CMTime(seconds: 10, preferredTimescale: 48_000)))
		_ = try XCTUnwrap(timeline.adjustment(for: CMTime(seconds: 11, preferredTimescale: 48_000)))

		timeline.setPaused(true, at: CMTime(seconds: 12, preferredTimescale: 48_000))
		XCTAssertNil(timeline.adjustment(for: CMTime(seconds: 12, preferredTimescale: 48_000)))
		timeline.setPaused(false, at: CMTime(seconds: 14, preferredTimescale: 48_000))
		let resumed = try XCTUnwrap(
			timeline.adjustment(for: CMTime(seconds: 14, preferredTimescale: 48_000))
		)

		XCTAssertEqual(resumed.presentationTime.seconds, 2, accuracy: 0.000_001)
		XCTAssertEqual(timeline.accumulatedPausedDuration.seconds, 2, accuracy: 0.000_001)
	}

	func testDelayedMicrophoneStartsAtItsSystemAudioOffset() {
		let startTime = MacAudioMixTiming.microphoneStartTime(for: 3.25)

		XCTAssertEqual(startTime.seconds, 3.25, accuracy: 0.000_001)
	}

	func testMeetingMixPreservesTheLaterTrackEnd() {
		let systemDuration = CMTime(seconds: 12, preferredTimescale: 48_000)
		let microphoneEndTime = CMTime(seconds: 10, preferredTimescale: 48_000)

		XCTAssertEqual(
			MacAudioMixTiming.exportDuration(
				microphoneEndTime: microphoneEndTime,
				systemDuration: systemDuration
			).seconds,
			12,
			accuracy: 0.000_001
		)
	}

	func testWrittenSystemTimelineReportsTheLastSampleEnd() {
		var timeline = MacSystemAudioWrittenTimeline()
		timeline.recordSample(
			at: CMTime(seconds: 2, preferredTimescale: 48_000),
			duration: CMTime(seconds: 0.02, preferredTimescale: 48_000)
		)

		XCTAssertEqual(timeline.duration, 2.02, accuracy: 0.000_001)
	}

	func testActiveCombineCannotBeDismissed() {
		XCTAssertFalse(CombineRecordingsDismissalPolicy.allowsDismissal(isCombining: true))
		XCTAssertTrue(CombineRecordingsDismissalPolicy.allowsDismissal(isCombining: false))
	}

    func testCaptureHealthRequiresARealFirstWrite() {
        let health = RecordingCaptureHealth()
        let start = Date(timeIntervalSince1970: 1_000)
        health.resetSession(at: start)

        XCTAssertEqual(
            health.assessment(
                at: start.addingTimeInterval(2),
                firstBufferTimeout: 5,
                stallTimeout: 5
            ),
            .starting
        )
        XCTAssertEqual(
            health.assessment(
                at: start.addingTimeInterval(5),
                firstBufferTimeout: 5,
                stallTimeout: 5
            ),
            .noInitialAudio
        )
    }

    func testCaptureHealthDetectsAStalledInputAfterSuccessfulWrites() {
        let health = RecordingCaptureHealth()
        let start = Date(timeIntervalSince1970: 2_000)
        health.resetSession(at: start)

        XCTAssertTrue(health.recordSuccessfulWrite(frameCount: 4_096, at: start.addingTimeInterval(1)))
        XCTAssertFalse(health.recordSuccessfulWrite(frameCount: 4_096, at: start.addingTimeInterval(2)))
        XCTAssertEqual(
            health.assessment(
                at: start.addingTimeInterval(6),
                firstBufferTimeout: 5,
                stallTimeout: 5
            ),
            .healthy
        )
        XCTAssertEqual(
            health.assessment(
                at: start.addingTimeInterval(7),
                firstBufferTimeout: 5,
                stallTimeout: 5
            ),
            .stalled
        )
        XCTAssertEqual(health.snapshot().totalFramesWritten, 8_192)
    }

    func testCaptureHealthSurfacesAndThenClearsAWriteFailure() {
        let health = RecordingCaptureHealth()
        let start = Date(timeIntervalSince1970: 3_000)
        health.resetSession(at: start)

        XCTAssertTrue(health.recordWriteFailure("disk write failed", at: start.addingTimeInterval(1)))
        XCTAssertFalse(health.recordWriteFailure("disk write failed", at: start.addingTimeInterval(2)))
        XCTAssertEqual(
            health.assessment(
                at: start.addingTimeInterval(2),
                firstBufferTimeout: 5,
                stallTimeout: 5
            ),
            .writeFailed("disk write failed")
        )

        XCTAssertTrue(health.recordSuccessfulWrite(frameCount: 512, at: start.addingTimeInterval(3)))
        XCTAssertEqual(
            health.assessment(
                at: start.addingTimeInterval(3),
                firstBufferTimeout: 5,
                stallTimeout: 5
            ),
            .healthy
        )
    }

    func testFinalizationPlanSalvagesEitherIndependentTrack() {
        XCTAssertEqual(
            MacRecordingFinalizationPlan.choose(hasMicrophoneAudio: true, hasSystemAudio: true),
            .mixMicrophoneAndSystem
        )
        XCTAssertEqual(
            MacRecordingFinalizationPlan.choose(hasMicrophoneAudio: true, hasSystemAudio: false),
            .microphoneOnly
        )
        XCTAssertEqual(
            MacRecordingFinalizationPlan.choose(hasMicrophoneAudio: false, hasSystemAudio: true),
            .systemOnly
        )
        XCTAssertEqual(
            MacRecordingFinalizationPlan.choose(hasMicrophoneAudio: false, hasSystemAudio: false),
            .unavailable
        )
    }

    func testRecoveryStoreMovesScratchFilesOutOfTemporaryStorage() throws {
        let testRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("MacRecordingReliabilityTests-\(UUID().uuidString)", isDirectory: true)
        let scratchRoot = testRoot.appendingPathComponent("Scratch", isDirectory: true)
        let recoveryRoot = testRoot.appendingPathComponent("Recovery", isDirectory: true)
        try FileManager.default.createDirectory(at: scratchRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: testRoot) }

        let microphoneURL = scratchRoot.appendingPathComponent("meeting.caf")
        let systemURL = scratchRoot.appendingPathComponent("meeting-system.m4a")
        try Data("microphone".utf8).write(to: microphoneURL)
        try Data("system".utf8).write(to: systemURL)

        let result = try RecordingRecoveryStore.preserve(
            files: [microphoneURL, systemURL],
            intendedFinalURL: URL(fileURLWithPath: "/Documents/meeting.m4a"),
            reason: "test failure",
            rootDirectory: recoveryRoot,
            now: Date(timeIntervalSince1970: 4_000)
        )

        XCTAssertFalse(FileManager.default.fileExists(atPath: microphoneURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: systemURL.path))
        XCTAssertEqual(result.preservedFileURLs.count, 2)
        XCTAssertTrue(result.preservedFileURLs.allSatisfy { FileManager.default.fileExists(atPath: $0.path) })
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: result.directoryURL.appendingPathComponent("Recovery Info.txt").path
            )
        )

        let inventory = RecordingRecoveryStore.diagnosticInventory(
            rootDirectory: recoveryRoot,
            fileManager: .default
        )
        XCTAssertTrue(inventory.contains("Recording recovery sessions:"))
        XCTAssertTrue(inventory.contains(result.directoryURL.lastPathComponent))
        XCTAssertTrue(inventory.contains("3 files"))
    }
}
