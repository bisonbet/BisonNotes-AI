//
//  Swift6AudioConcurrencyTests.swift
//  BisonNotes AITests
//

import Foundation
import Speech
import XCTest
@testable import BisonNotes_AI

final class Swift6AudioConcurrencyTests: XCTestCase {
	func testSpeechAuthorizationResolvesWhenCallbackRunsOnBackgroundQueue() async {
		let granted = await SpeechAuthorizationClient.requestPermission { completion in
			DispatchQueue.global(qos: .userInitiated).async {
				completion(.authorized)
			}
		}

		XCTAssertTrue(granted)
	}

	func testSpeechAuthorizationRejectsEveryNonAuthorizedStatus() async {
		let statuses: [SFSpeechRecognizerAuthorizationStatus] = [
			.denied,
			.restricted,
			.notDetermined
		]

		for status in statuses {
			let granted = await SpeechAuthorizationClient.requestPermission { completion in
				completion(status)
			}
			XCTAssertFalse(granted, "Unexpected authorization result for \(status)")
		}
	}

	func testSpeechAuthorizationIgnoresDuplicateCallbacks() async {
		let granted = await SpeechAuthorizationClient.requestPermission { completion in
			DispatchQueue.global(qos: .userInitiated).async {
				completion(.authorized)
				completion(.denied)
			}
		}

		XCTAssertTrue(granted)
	}

	func testCaptureHealthSerializesConcurrentRealtimeWrites() throws {
		let health = RecordingCaptureHealth()
		let start = Date(timeIntervalSince1970: 4_000)
		health.resetSession(at: start)

		let writerCount = 8
		let writesPerWriter = 100
		DispatchQueue.concurrentPerform(iterations: writerCount * writesPerWriter) { index in
			let writeDate = start.addingTimeInterval(Double((index % writesPerWriter) + 1))
			_ = health.recordSuccessfulWrite(frameCount: 1, at: writeDate)
		}

		let snapshot = health.snapshot()
		XCTAssertEqual(snapshot.segmentFramesWritten, Int64(writerCount * writesPerWriter))
		XCTAssertEqual(snapshot.totalFramesWritten, Int64(writerCount * writesPerWriter))
		let lastWriteAt = try XCTUnwrap(snapshot.lastWriteAt)
		XCTAssertEqual(
			health.assessment(
				at: lastWriteAt.addingTimeInterval(1),
				firstBufferTimeout: 5,
				stallTimeout: 5
			),
			.healthy
		)
	}
}
