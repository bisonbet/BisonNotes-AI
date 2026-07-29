//
//  MacRecordingReliabilityTests.swift
//  BisonNotes AITests
//

import Foundation
import XCTest
@testable import BisonNotes_AI

final class MacRecordingReliabilityTests: XCTestCase {
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
