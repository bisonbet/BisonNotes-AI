//
//  CloudAudioAssetPolicyTests.swift
//  BisonNotes AITests
//
//  Audio is the one part of a backup that can be large, slow, and missing. None of
//  that may block metadata: these tests pin what happens for each state the file on
//  disk can be in.
//

import CloudKit
import XCTest
@testable import BisonNotes_AI

@MainActor
final class CloudAudioAssetPolicyTests: XCTestCase {
    private var temporaryDirectory: URL!

    override func setUpWithError() throws {
        temporaryDirectory = try TestHelpers.createTemporaryDirectory()
    }

    override func tearDownWithError() throws {
        if let temporaryDirectory {
            try? TestHelpers.cleanupTemporaryDirectory(temporaryDirectory)
        }
        temporaryDirectory = nil
    }

    // MARK: Decisions

    func testAudioDisabledSkipsWithoutTouchingTheFile() {
        let decision = CloudAudioAssetPolicy.decide(
            includeAudioFiles: false,
            sourceExists: true,
            localSignature: "abc",
            cloudSignature: nil,
            byteCount: 1_024
        )

        XCTAssertEqual(decision, .skippedDisabled)
        XCTAssertFalse(decision.uploads)
    }

    func testUnchangedAudioProducesNoUpload() {
        let decision = CloudAudioAssetPolicy.decide(
            includeAudioFiles: true,
            sourceExists: true,
            localSignature: "abc",
            cloudSignature: "abc",
            byteCount: 1_024
        )

        XCTAssertEqual(decision, .skippedUnchanged)
    }

    func testChangedAudioUploadsWithItsSignature() {
        let decision = CloudAudioAssetPolicy.decide(
            includeAudioFiles: true,
            sourceExists: true,
            localSignature: "new",
            cloudSignature: "old",
            byteCount: 2_048
        )

        XCTAssertEqual(decision, .upload(byteCount: 2_048, signature: "new"))
    }

    func testMissingSourceSkipsTheAssetRatherThanFailing() {
        let decision = CloudAudioAssetPolicy.decide(
            includeAudioFiles: true,
            sourceExists: false,
            localSignature: nil,
            cloudSignature: nil,
            byteCount: 0
        )

        XCTAssertEqual(
            decision,
            .skippedMissingSource,
            "A recording whose file is gone must still back its metadata up"
        )
    }

    func testUnreadableSourceIsTreatedAsMissing() {
        let decision = CloudAudioAssetPolicy.decide(
            includeAudioFiles: true,
            sourceExists: true,
            localSignature: nil,
            cloudSignature: "old",
            byteCount: 0
        )

        XCTAssertEqual(decision, .skippedMissingSource)
    }

    // MARK: Staging

    func testStagingCopiesTheSourceSoAnInFlightUploadCannotChange() async throws {
        let source = temporaryDirectory.appendingPathComponent("recording.m4a")
        try Data("original".utf8).write(to: source)

        let staging = TemporaryDirectoryAssetStaging(runIdentifier: "test-run")
        defer { staging.cleanUp() }

        let stagedCopy = await staging.stage(source)
        let staged = try XCTUnwrap(stagedCopy)
        XCTAssertNotEqual(staged, source)
        XCTAssertEqual(try Data(contentsOf: staged), Data("original".utf8))

        // The user keeps recording into the same file.
        try Data("appended data".utf8).write(to: source)
        XCTAssertEqual(
            try Data(contentsOf: staged),
            Data("original".utf8),
            "The staged copy is immutable, so CloudKit cannot reject the upload as modified"
        )
    }

    func testSourceRemovedAfterTheDecisionYieldsNoStagedCopy() async throws {
        let source = temporaryDirectory.appendingPathComponent("gone.m4a")
        try Data("audio".utf8).write(to: source)
        try FileManager.default.removeItem(at: source)

        let staging = TemporaryDirectoryAssetStaging(runIdentifier: "test-run")
        defer { staging.cleanUp() }

        let staged = await staging.stage(source)
        XCTAssertNil(staged, "A file that vanished mid-run must not fail the whole batch")
    }

    func testCleanUpRemovesEveryStagedFile() async throws {
        let first = temporaryDirectory.appendingPathComponent("one.m4a")
        let second = temporaryDirectory.appendingPathComponent("two.m4a")
        try Data("one".utf8).write(to: first)
        try Data("two".utf8).write(to: second)

        let staging = TemporaryDirectoryAssetStaging(runIdentifier: "cleanup-run")
        let firstCopy = await staging.stage(first)
        let stagedFirst = try XCTUnwrap(firstCopy)
        let secondCopy = await staging.stage(second)
        let stagedSecond = try XCTUnwrap(secondCopy)
        XCTAssertEqual(staging.stagedFileCount, 2)

        staging.cleanUp()

        XCTAssertFalse(FileManager.default.fileExists(atPath: stagedFirst.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: stagedSecond.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: first.path), "Cleanup must never touch the originals")
        XCTAssertTrue(FileManager.default.fileExists(atPath: second.path))
    }

    // MARK: Partial failure

    func testAnAssetFailureLeavesTheOtherRecordsMetadataInPlace() async throws {
        let transport = FakeCloudKitTransport()
        let clock = ManualCloudSyncClock()
        let executor = CloudKitBatchExecutor(
            transport: transport,
            sleeper: RecordingCloudSyncSleeper(clock: clock),
            clock: clock,
            preferences: InMemoryCloudSyncPreferencesStore(),
            jitterProvider: { 0 }
        )

        let source = temporaryDirectory.appendingPathComponent("audio.m4a")
        try Data("audio".utf8).write(to: source)

        let withAsset = CloudKitTestRecords.record(type: "CD_BackupRecording", name: "backup_recording_1")
        withAsset["audioAsset"] = CKAsset(fileURL: source)
        let metadataOnly = CloudKitTestRecords.record(
            type: "CD_BackupRecording",
            name: "backup_recording_2",
            fields: ["recordingName": "Second"]
        )
        transport.perRecordSaveFailures[withAsset.recordID] = [
            CloudKitTestError.ckError(.assetFileNotFound)
        ]

        let outcome = try await executor.save([withAsset, metadataOnly])

        XCTAssertEqual(outcome.failures.count, 1)
        XCTAssertNotNil(outcome.saved[metadataOnly.recordID], "One failed asset must not take a sibling's metadata down with it")
        XCTAssertEqual(transport.record(named: "backup_recording_2")?["recordingName"] as? String, "Second")
    }

    func testAssetErrorsAreRecognizedAsAssetProblems() {
        XCTAssertTrue(CloudKitTestError.ckError(.assetFileNotFound).isAssetFileProblem)
        XCTAssertTrue(CloudKitTestError.ckError(.assetFileModified).isAssetFileProblem)
        XCTAssertFalse(CloudKitTestError.ckError(.networkFailure).isAssetFileProblem)
    }
}
