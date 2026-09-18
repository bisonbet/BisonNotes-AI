import Foundation
import XCTest
@testable import BisonNotes_AI

final class PrivacyPreservingCrashReportingTests: XCTestCase {
    private let incidentDate = Date(timeIntervalSince1970: 1_000_000)
    private let consentDate = Date(timeIntervalSince1970: 999_000)

    func testEnvelopeRetainsApprovedTechnicalFieldsAndUsesStableOccurrenceID() throws {
        let input = makeInput()
        let consent = DiagnosticConsentSnapshot(
            isEnabled: true,
            epoch: UUID(uuidString: "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa"),
            enabledAt: consentDate
        )

        let first = try XCTUnwrap(
            CrashEnvelopeBuilder.build(
                input: input,
                consent: consent,
                receivingRuntime: runtime,
                contextEvents: [],
                receivedAt: incidentDate
            )
        )
        let second = try XCTUnwrap(
            CrashEnvelopeBuilder.build(
                input: input,
                consent: consent,
                receivingRuntime: runtime,
                contextEvents: [],
                receivedAt: incidentDate
            )
        )

        XCTAssertEqual(first.idempotencyKey, second.idempotencyKey)
        XCTAssertEqual(first.report.stack?.threads.first?.frames.first?.offsetIntoBinaryTextSegment, 4096)
        XCTAssertEqual(first.report.stack?.threads.first?.frames.first?.imageKind, .application)

        let data = try DiagnosticPolicy.jsonEncoder().encode(first)
        let json = String(decoding: data, as: UTF8.self)
        XCTAssertTrue(json.contains("iPhone17,1"))
        XCTAssertTrue(json.contains("11111111-2222-3333-4444-555555555555"))
        XCTAssertFalse(json.contains("recording title"))
        XCTAssertFalse(json.contains("/Users/"))
        XCTAssertFalse(json.contains("transcript secret"))
    }

    func testLegacyProjectionDropsUnknownAppleTextAndUnreviewedImages() throws {
        let fixture = """
        {
          "callStacks": [
            {
              "binaryName": "BisonNotes AI",
              "binaryUUID": "11111111-2222-3333-4444-555555555555",
              "offsetIntoBinaryTextSegment": "0x1000",
              "exceptionReason": "transcript secret",
              "path": "/Users/champ/recording-title.m4a"
            },
            {
              "binaryName": "UnreviewedUserFramework",
              "binaryUUID": "66666666-7777-8888-9999-000000000000",
              "offsetIntoBinaryTextSegment": 8192,
              "title": "recording title"
            }
          ]
        }
        """

        let stack = try XCTUnwrap(
            LegacyMetricKitStackProjector.project(jsonData: Data(fixture.utf8))
        )
        let data = try DiagnosticPolicy.jsonEncoder().encode(stack)
        let json = String(decoding: data, as: UTF8.self)

        XCTAssertEqual(stack.threads.first?.frames.count, 1)
        XCTAssertTrue(json.contains("11111111-2222-3333-4444-555555555555"))
        XCTAssertTrue(json.contains("4096"))
        XCTAssertFalse(json.contains("transcript secret"))
        XCTAssertFalse(json.contains("/Users/"))
        XCTAssertFalse(json.contains("UnreviewedUserFramework"))
        XCTAssertFalse(json.contains("recording title"))
    }

    func testConsentRevocationClearsEventsQueueAndTokenState() async throws {
        let suiteName = "PrivacyPreservingCrashReportingTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let now = consentDate

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("diagnostics-\(UUID().uuidString)", isDirectory: true)
        let eventStore = DiagnosticEventStore(
            fileURL: directory.appendingPathComponent("events.json"),
            now: { now }
        )
        let queue = DiagnosticUploadQueue(
            fileURL: directory.appendingPathComponent("queue.json"),
            uploader: nil,
            now: { now }
        )
        let service = DiagnosticReportingService(
            consentStore: DiagnosticConsentStore(userDefaults: defaults),
            eventStore: eventStore,
            uploadQueue: queue,
            runtime: runtime,
            now: { now }
        )

        await service.startSession()
        let initialEventCount = await eventStore.count()
        XCTAssertEqual(initialEventCount, 0)

        await service.setConsent(enabled: true)
        let enabledEventCount = await eventStore.count()
        XCTAssertGreaterThan(enabledEventCount, 0)

        await service.setConsent(enabled: false)
        XCTAssertFalse(DiagnosticConsentStore(userDefaults: defaults).snapshot(now: consentDate).isEnabled)
        let revokedEventCount = await eventStore.count()
        let revokedQueueCount = await queue.count()
        XCTAssertEqual(revokedEventCount, 0)
        XCTAssertEqual(revokedQueueCount, 0)
    }

    func testEventStoreCapsEventsAndDropsCorruptStorage() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("diagnostics-\(UUID().uuidString)", isDirectory: true)
        let eventURL = directory.appendingPathComponent("events.json")
        let now = incidentDate
        let store = DiagnosticEventStore(fileURL: eventURL, now: { now })
        let epoch = UUID()
        let session = UUID()

        for index in 0..<80 {
            await store.append(makeEvent(
                eventID: UUID(),
                epoch: epoch,
                session: session,
                occurredAt: incidentDate.addingTimeInterval(TimeInterval(index))
            ))
        }

        let eventCount = await store.count()
        let eventByteCount = await store.encodedByteCount()
        XCTAssertLessThanOrEqual(eventCount, DiagnosticPolicy.maximumStructuredEvents)
        XCTAssertLessThanOrEqual(eventByteCount, DiagnosticPolicy.maximumEventStoreBytes)

        let duplicateID = UUID()
        let duplicateEvent = makeEvent(
            eventID: duplicateID,
            epoch: epoch,
            session: session,
            occurredAt: incidentDate
        )
        await store.append(duplicateEvent)
        await store.append(duplicateEvent)
        let storedEvents = await store.allEvents()
        let duplicateCount = storedEvents.filter { $0.eventID == duplicateID }.count
        XCTAssertEqual(duplicateCount, 1)

        let corruptURL = directory.appendingPathComponent("corrupt.json")
        try Data("not-json".utf8).write(to: corruptURL)
        let corruptStore = DiagnosticEventStore(fileURL: corruptURL, now: { now })
        let corruptEventCount = await corruptStore.count()
        XCTAssertEqual(corruptEventCount, 0)
    }

    func testUploadQueueAcceptsOnlyMatchingAcknowledgement() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("diagnostics-\(UUID().uuidString)", isDirectory: true)
        let now = incidentDate
        let requestRecorder = RequestRecorder()
        let uploader = DiagnosticUploader(
            endpoint: try XCTUnwrap(URL(string: "http://127.0.0.1/diagnostics")),
            transport: { request in
                await requestRecorder.record(request)
                guard let body = request.httpBody,
                      let envelope = try? DiagnosticPolicy.jsonDecoder().decode(
                        CrashEnvelope.self,
                        from: body
                      ) else {
                    return DiagnosticHTTPResponse(statusCode: 400, headers: [:], body: Data())
                }
                let acknowledgement: [String: Any] = [
                    "accepted": true,
                    "eventID": envelope.idempotencyKey.uuidString
                ]
                return DiagnosticHTTPResponse(
                    statusCode: 200,
                    headers: [:],
                    body: try JSONSerialization.data(withJSONObject: acknowledgement)
                )
            }
        )
        let queue = DiagnosticUploadQueue(
            fileURL: directory.appendingPathComponent("queue.json"),
            uploader: uploader,
            now: { now },
            jitterProvider: { 0 }
        )
        let consent = DiagnosticConsentSnapshot(
            isEnabled: true,
            epoch: UUID(),
            enabledAt: consentDate
        )
        let envelope = try XCTUnwrap(
            CrashEnvelopeBuilder.build(
                input: makeInput(),
                consent: consent,
                receivingRuntime: runtime,
                contextEvents: [],
                receivedAt: incidentDate
            )
        )

        let enqueued = await queue.enqueue(envelope)
        XCTAssertTrue(enqueued)
        await queue.process(consent: consent)

        let queueCount = await queue.count()
        let requestCount = await requestRecorder.count
        let idempotencyHeader = await requestRecorder.idempotencyHeader
        XCTAssertEqual(queueCount, 0)
        XCTAssertEqual(requestCount, 1)
        XCTAssertEqual(idempotencyHeader, envelope.idempotencyKey.uuidString)
    }

    func testUploaderRetriesTransientResponseAndHonorsRetryAfter() async throws {
        let uploader = DiagnosticUploader(
            endpoint: try XCTUnwrap(URL(string: "http://127.0.0.1/diagnostics")),
            transport: { _ in
                DiagnosticHTTPResponse(
                    statusCode: 429,
                    headers: ["Retry-After": "120"],
                    body: Data()
                )
            }
        )
        let consent = DiagnosticConsentSnapshot(
            isEnabled: true,
            epoch: UUID(),
            enabledAt: consentDate
        )
        let envelope = try XCTUnwrap(
            CrashEnvelopeBuilder.build(
                input: makeInput(),
                consent: consent,
                receivingRuntime: runtime,
                contextEvents: [],
                receivedAt: incidentDate
            )
        )

        let outcome = await uploader.upload(envelope)
        guard case .retry(let delay) = outcome else {
            return XCTFail("Expected a retry outcome for HTTP 429")
        }
        XCTAssertEqual(delay, 120)
    }

    func testAmbiguousContextDoesNotAttachCurrentOperation() throws {
        let epoch = UUID()
        let firstSession = UUID()
        let secondSession = UUID()
        let events = [
            makeEvent(eventID: UUID(), epoch: epoch, session: firstSession, occurredAt: incidentDate),
            makeEvent(eventID: UUID(), epoch: epoch, session: secondSession, occurredAt: incidentDate)
        ]
        let consent = DiagnosticConsentSnapshot(
            isEnabled: true,
            epoch: epoch,
            enabledAt: consentDate
        )

        let envelope = try XCTUnwrap(
            CrashEnvelopeBuilder.build(
                input: makeInput(),
                consent: consent,
                receivingRuntime: runtime,
                contextEvents: events,
                receivedAt: incidentDate
            )
        )

        XCTAssertEqual(envelope.operation, .unknown)
        XCTAssertEqual(envelope.phase, .unknown)
        XCTAssertEqual(envelope.report.provenance.contextAssociation, .unknown)
        XCTAssertNotEqual(envelope.sessionToken, firstSession)
        XCTAssertNotEqual(envelope.sessionToken, secondSession)
    }

    func testProductionUploadIsNotConfiguredAndInsecureRemoteTransportIsRejected() throws {
        XCTAssertNil(DiagnosticUploadConfiguration.productionDisabled.endpoint)
        XCTAssertNil(
            DiagnosticUploadConfiguration(endpoint: URL(string: "http://example.com"))
                .endpoint
        )
        XCTAssertNotNil(
            DiagnosticUploadConfiguration(endpoint: URL(string: "https://example.com"))
                .endpoint
        )
    }

    private var runtime: DiagnosticRuntimeInfo {
        DiagnosticRuntimeInfo(
            appVersion: "3.0",
            appBuild: "42",
            osVersion: "27.0.0",
            platform: .iOS,
            hardwareModel: "iPhone17,1"
        )
    }

    private func makeInput() -> DiagnosticReportInput {
        DiagnosticReportInput(
            kind: .appleCrash,
            source: .modernMetricKit,
            incidentStart: incidentDate,
            incidentEnd: incidentDate,
            affectedRuntime: runtime,
            failure: DiagnosticFailure(
                exceptionType: 1,
                exceptionCode: 10,
                signal: 11,
                terminationCategory: .badAccess
            ),
            stack: DiagnosticStack(threads: [
                DiagnosticStackThread(frames: [
                    DiagnosticStackFrame(
                        imageUUID: UUID(uuidString: "11111111-2222-3333-4444-555555555555")!,
                        offsetIntoBinaryTextSegment: 4096,
                        imageKind: .application
                    )
                ])
            ])
        )
    }

    private func makeEvent(
        eventID: UUID,
        epoch: UUID,
        session: UUID,
        occurredAt: Date
    ) -> DiagnosticEvent {
        DiagnosticEvent(
            eventID: eventID,
            consentEpoch: epoch,
            sessionToken: session,
            occurredAt: occurredAt,
            applicationVersion: runtime.appVersion,
            applicationBuild: runtime.appBuild,
            operation: .recordingFinalize,
            phase: .begin,
            result: .unknown,
            state: DiagnosticState(
                foregroundState: .foreground,
                isRecording: true,
                isSyncing: false
            ),
            measurements: DiagnosticMeasurements(
                operationCount: .one,
                duration: .unknown,
                memoryPressure: .unknown,
                thermalState: .unknown
            ),
            report: nil
        )
    }
}

private actor RequestRecorder {
    private(set) var count = 0
    private(set) var idempotencyHeader: String?

    func record(_ request: URLRequest) {
        count += 1
        idempotencyHeader = request.value(forHTTPHeaderField: "Idempotency-Key")
    }
}
