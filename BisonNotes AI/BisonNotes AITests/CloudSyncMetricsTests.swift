//
//  CloudSyncMetricsTests.swift
//  BisonNotes AITests
//
//  Sync metrics exist so a slow run can be diagnosed from a shared device log.
//  That only works if the numbers are right and the log can never carry a
//  recording name, a filename, or a line of a transcript.
//

import CloudKit
import XCTest
@testable import BisonNotes_AI

@MainActor
final class CloudSyncMetricsTests: XCTestCase {
    private var clock: ManualCloudSyncClock!
    private var sink: RecordingCloudSyncMetricsSink!

    override func setUp() async throws {
        clock = ManualCloudSyncClock()
        sink = RecordingCloudSyncMetricsSink()
    }

    override func tearDown() async throws {
        sink = nil
        clock = nil
    }

    private func makeRecorder(
        reason: CloudSyncReason = .appLaunch,
        intent: CloudSyncIntent = .routineSnapshot,
        queueDelaySeconds: TimeInterval = 0
    ) -> CloudSyncRunRecorder {
        CloudSyncRunRecorder(
            reason: reason,
            intent: intent,
            queueDelaySeconds: queueDelaySeconds,
            clock: clock,
            sink: sink,
            runIdentifier: "run1234"
        )
    }

    // MARK: Timing

    func testPhaseDurationsUseTheMonotonicClock() {
        let recorder = makeRecorder()

        recorder.begin(.flushOutboundTombstones)
        clock.advance(2)
        recorder.begin(.fetchCloudSnapshot)
        clock.advance(5)
        recorder.endPhase()
        clock.advance(1)

        let report = recorder.finish(.succeeded)

        XCTAssertEqual(report.phaseSeconds[.flushOutboundTombstones], 2)
        XCTAssertEqual(report.phaseSeconds[.fetchCloudSnapshot], 5)
        XCTAssertEqual(report.totalSeconds, 8)
    }

    func testPhaseOrderIsRecordedInTheOrderItRan() {
        let recorder = makeRecorder()

        recorder.begin(.flushOutboundTombstones)
        recorder.begin(.applyInboundTombstones)
        recorder.begin(.fetchCloudSnapshot)
        recorder.begin(.commitManifest)
        recorder.finish(.succeeded)

        XCTAssertEqual(
            recorder.phaseOrder,
            [.flushOutboundTombstones, .applyInboundTombstones, .fetchCloudSnapshot, .commitManifest]
        )
    }

    // MARK: Counts

    func testOperationCountsAccumulateAcrossExecutorCalls() {
        let recorder = makeRecorder()

        var fetch = CloudKitFetchOutcome()
        fetch.records[CKRecord.ID(recordName: "a")] = CloudKitTestRecords.record(type: "T", name: "a")
        fetch.records[CKRecord.ID(recordName: "b")] = CloudKitTestRecords.record(type: "T", name: "b")
        fetch.stats = CloudKitOperationStats(requestCount: 2, batchCount: 2, retryCount: 1, retryWaitSeconds: 4)
        recorder.add(fetch: fetch)

        var modify = CloudKitModifyOutcome()
        modify.saved[CKRecord.ID(recordName: "a")] = CloudKitTestRecords.record(type: "T", name: "a")
        modify.deleted.insert(CKRecord.ID(recordName: "c"))
        modify.stats = CloudKitOperationStats(requestCount: 1, batchCount: 1)
        recorder.add(modify: modify)

        let report = recorder.finish(.succeeded)

        XCTAssertEqual(report.requestCount, 3)
        XCTAssertEqual(report.batchCount, 3)
        XCTAssertEqual(report.recordsFetched, 2)
        XCTAssertEqual(report.recordsSaved, 1)
        XCTAssertEqual(report.recordsDeleted, 1)
        XCTAssertEqual(report.retryCount, 1)
        XCTAssertEqual(report.retryWaitSeconds, 4)
    }

    func testDeferredWorkIsReportedAsDeferredNotAsSuccess() {
        let recorder = makeRecorder()
        var fetch = CloudKitFetchOutcome()
        fetch.deferred.insert(CKRecord.ID(recordName: "a"))
        fetch.deferredUntil = clock.now.addingTimeInterval(300)
        fetch.stats = CloudKitOperationStats(requestCount: 1, batchCount: 1, deferredCount: 1)
        recorder.add(fetch: fetch)

        let report = recorder.finish(.deferred)

        XCTAssertEqual(report.result, .deferred)
        XCTAssertEqual(report.deferredItemCount, 1)
        XCTAssertNotNil(report.deferredUntil)
        XCTAssertTrue(report.logDescription.contains("result=deferred"))
    }

    /// A run logged after its own deferral deadline had passed reported
    /// `deferredFor=-5s`, which reads as a broken deferral rather than a stale line.
    func testDeferredWaitIsNeverNegative() {
        let recorder = makeRecorder()
        var report = recorder.finish(.deferred)
        report.deferredUntil = Date(timeIntervalSinceNow: -5)

        XCTAssertTrue(
            report.logDescription.contains("deferredFor=0s"),
            "Expected a clamped wait, got: \(report.logDescription)"
        )
    }

    func testFailureIsReportedAsFailure() {
        let recorder = makeRecorder()
        let report = recorder.finish(.failed)

        XCTAssertEqual(report.result, .failed)
        XCTAssertTrue(report.logDescription.contains("result=failed"))
    }

    func testTheSinkReceivesExactlyOneReportPerRun() {
        let recorder = makeRecorder()
        recorder.finish(.succeeded)
        recorder.finish(.succeeded)

        XCTAssertEqual(sink.reports.count, 1, "A run reports once, however many times finish is called")
    }

    // MARK: Audio

    func testAudioIsReportedSeparatelyFromMetadataTiming() {
        let recorder = makeRecorder()
        recorder.addAudio(fileCount: 2, byteCount: 10_485_760, seconds: 600)
        clock.advance(10)

        let report = recorder.finish(.succeeded)

        XCTAssertEqual(report.audioFilesUploaded, 2)
        XCTAssertEqual(report.audioBytesUploaded, 10_485_760)
        let audioLine = try? XCTUnwrap(report.audioLogDescription)
        XCTAssertTrue(audioLine?.contains("audioMB=10.00") ?? false)
        XCTAssertTrue(audioLine?.contains("throughputMBps=1.00") ?? false)
        XCTAssertFalse(
            report.logDescription.contains("audioMB"),
            "Audio bytes must not be mixed into the metadata line the latency gates are read from"
        )
    }

    // MARK: Privacy

    func testTheLogLineCarriesNoUserContent() {
        let recorder = makeRecorder(reason: .localChange, intent: .routineSnapshot)

        var fetch = CloudKitFetchOutcome()
        let recordName = "backup_recording_5C1D9E2F-0000-0000-0000-000000000001"
        fetch.records[CKRecord.ID(recordName: recordName)] = CloudKitTestRecords.record(
            type: "CD_BackupRecording",
            name: recordName,
            fields: [
                "recordingName": "Therapy session with Dr. Alvarez",
                "audioFileName": "therapy-2026-08-24.m4a",
                "deviceIdentifier": "ABCD-1234-EFGH"
            ]
        )
        fetch.stats = CloudKitOperationStats(requestCount: 1, batchCount: 1)
        recorder.add(fetch: fetch)

        let description = recorder.finish(.succeeded).logDescription

        XCTAssertFalse(description.contains("Therapy"))
        XCTAssertFalse(description.contains("Alvarez"))
        XCTAssertFalse(description.contains("therapy-2026-08-24.m4a"))
        XCTAssertFalse(description.contains("ABCD-1234-EFGH"))
        XCTAssertFalse(description.contains(recordName))
        XCTAssertTrue(description.contains("fetched=1"))
        XCTAssertTrue(description.contains("reason=localChange"))
    }

    func testEveryReasonAndPhaseIsLoggableAsAFixedToken() {
        // The closed enums are what make the privacy guarantee structural rather
        // than a matter of remembering not to interpolate a name.
        for reason in CloudSyncReason.allCases {
            XCTAssertFalse(reason.rawValue.contains(" "))
        }
        for phase in CloudSyncPhase.allCases {
            XCTAssertFalse(phase.rawValue.contains(" "))
        }
    }

    func testQueueDelayIsReported() {
        let recorder = makeRecorder(queueDelaySeconds: 3.5)
        let report = recorder.finish(.succeeded)

        XCTAssertEqual(report.queueDelaySeconds, 3.5)
        XCTAssertTrue(report.logDescription.contains("queue=3.50s"))
    }
}
