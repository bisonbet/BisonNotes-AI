//
//  CloudKitRetryPolicyTests.swift
//  BisonNotes AITests
//
//  CloudKit throttles by telling us how long to wait. Honouring that — and never
//  holding a foreground task open for a wait measured in minutes — is what turns a
//  throttled sync from a hang into a deferred result.
//

import CloudKit
import XCTest
@testable import BisonNotes_AI

@MainActor
final class CloudKitRetryPolicyTests: XCTestCase {
    private var transport: FakeCloudKitTransport!
    private var clock: ManualCloudSyncClock!
    private var sleeper: RecordingCloudSyncSleeper!
    private var preferences: InMemoryCloudSyncPreferencesStore!
    private var executor: CloudKitBatchExecutor!

    override func setUp() async throws {
        transport = FakeCloudKitTransport()
        clock = ManualCloudSyncClock()
        sleeper = RecordingCloudSyncSleeper(clock: clock)
        preferences = InMemoryCloudSyncPreferencesStore()
        executor = CloudKitBatchExecutor(
            transport: transport,
            sleeper: sleeper,
            clock: clock,
            preferences: preferences,
            jitterProvider: { 0 }
        )
    }

    override func tearDown() async throws {
        executor = nil
        preferences = nil
        sleeper = nil
        clock = nil
        transport = nil
    }

    // MARK: The policy itself

    func testServerSuppliedDelayIsHonoredExactly() {
        let policy = CloudKitRetryPolicy()
        let error = CloudKitTestError.ckError(.requestRateLimited, retryAfter: 7)

        XCTAssertEqual(policy.decision(for: error, attempt: 0, jitter: 0), .retry(after: 7))
    }

    func testCalculatedBackoffIsExponentialAndJittered() {
        let policy = CloudKitRetryPolicy()
        let error = CloudKitTestError.ckError(.networkFailure)

        XCTAssertEqual(policy.decision(for: error, attempt: 0, jitter: 0), .retry(after: 2))
        XCTAssertEqual(policy.decision(for: error, attempt: 1, jitter: 0), .retry(after: 4))
        XCTAssertEqual(policy.decision(for: error, attempt: 2, jitter: 0), .retry(after: 8))
        XCTAssertEqual(
            policy.decision(for: error, attempt: 1, jitter: 1),
            .retry(after: 5),
            "Jitter adds up to a quarter of the calculated delay so devices do not retry in lockstep"
        )
    }

    func testALongServerDelayBecomesADeferralRatherThanASleep() {
        let policy = CloudKitRetryPolicy()
        let error = CloudKitTestError.ckError(.requestRateLimited, retryAfter: 300)

        XCTAssertEqual(policy.decision(for: error, attempt: 0, jitter: 0), .deferFor(seconds: 300))
    }

    func testAttemptsAreExhaustedAfterThreeRetries() {
        let policy = CloudKitRetryPolicy()
        let error = CloudKitTestError.ckError(.serviceUnavailable)

        XCTAssertEqual(policy.decision(for: error, attempt: 2, jitter: 0), .retry(after: 8))
        XCTAssertEqual(policy.decision(for: error, attempt: 3, jitter: 0), .fail)
    }

    func testNonRetryableErrorsFailImmediately() {
        let policy = CloudKitRetryPolicy()

        XCTAssertEqual(
            policy.decision(for: CloudKitTestError.ckError(.permissionFailure), attempt: 0, jitter: 0),
            .fail
        )
        XCTAssertEqual(
            policy.decision(for: CloudKitTestError.ckError(.quotaExceeded), attempt: 0, jitter: 0),
            .fail
        )
    }

    // MARK: The executor's use of it

    func testExecutorSleepsForTheServerRequestedDelayThenRetries() async throws {
        transport.seed([CloudKitTestRecords.record(type: "CD_BackupSummary", name: "summary_1")])
        transport.fetchFailures = [CloudKitTestError.ckError(.requestRateLimited, retryAfter: 4)]

        let outcome = try await executor.fetch(CloudKitTestRecords.recordIDs(["summary_1"]))

        XCTAssertEqual(sleeper.requestedSleeps, [4])
        XCTAssertEqual(outcome.records.count, 1)
        XCTAssertEqual(outcome.stats.retryCount, 1)
        XCTAssertEqual(outcome.stats.retryWaitSeconds, 4)
    }

    func testALongBackoffDefersInsteadOfHoldingTheTask() async throws {
        transport.seed([CloudKitTestRecords.record(type: "CD_BackupSummary", name: "summary_1")])
        transport.fetchFailures = [CloudKitTestError.ckError(.requestRateLimited, retryAfter: 120)]

        let outcome = try await executor.fetch(CloudKitTestRecords.recordIDs(["summary_1"]))

        XCTAssertTrue(sleeper.requestedSleeps.isEmpty, "A two-minute wait must not be spent asleep in the foreground")
        XCTAssertEqual(outcome.deferred, [CKRecord.ID(recordName: "summary_1")])
        XCTAssertEqual(outcome.deferredUntil, clock.now.addingTimeInterval(120))
        XCTAssertFalse(outcome.isComplete, "A deferred fetch is not a successful empty fetch")
    }

    func testNoRequestIsIssuedBeforeTheEligibilityTime() async throws {
        transport.seed([CloudKitTestRecords.record(type: "CD_BackupSummary", name: "summary_1")])
        transport.fetchFailures = [CloudKitTestError.ckError(.requestRateLimited, retryAfter: 120)]
        _ = try await executor.fetch(CloudKitTestRecords.recordIDs(["summary_1"]))
        let requestsBefore = transport.fetchOperationCount

        // Every trigger that arrives during the backoff coalesces into nothing.
        for _ in 0..<5 {
            let outcome = try await executor.fetch(CloudKitTestRecords.recordIDs(["summary_1"]))
            XCTAssertTrue(outcome.records.isEmpty)
            XCTAssertFalse(outcome.deferred.isEmpty)
        }
        XCTAssertEqual(transport.fetchOperationCount, requestsBefore, "Not one request may be sent during a server-requested backoff")
        XCTAssertTrue(executor.isDeferred)

        clock.advance(121)
        let afterWindow = try await executor.fetch(CloudKitTestRecords.recordIDs(["summary_1"]))
        XCTAssertEqual(afterWindow.records.count, 1)
        XCTAssertFalse(executor.isDeferred)
    }

    func testModifyIsAlsoBlockedDuringABackoff() async throws {
        transport.modifyFailures = [CloudKitTestError.ckError(.requestRateLimited, retryAfter: 300)]
        let record = CloudKitTestRecords.record(type: "CD_BackupSummary", name: "summary_1")

        _ = try await executor.save([record])
        transport.clearLedger()

        let outcome = try await executor.save([record])
        XCTAssertEqual(transport.modifyOperationCount, 0)
        XCTAssertEqual(outcome.deferred, [record.recordID])
    }

    func testRetriesStopAfterThreeAttempts() async throws {
        transport.seed([CloudKitTestRecords.record(type: "CD_BackupSummary", name: "summary_1")])
        transport.fetchFailures = Array(
            repeating: CloudKitTestError.ckError(.serviceUnavailable),
            count: 4
        )

        let outcome = try await executor.fetch(CloudKitTestRecords.recordIDs(["summary_1"]))

        XCTAssertEqual(transport.fetchOperationCount, 4, "One attempt plus three retries")
        XCTAssertEqual(sleeper.requestedSleeps, [2, 4, 8])
        XCTAssertEqual(outcome.failures.count, 1)
    }
}
