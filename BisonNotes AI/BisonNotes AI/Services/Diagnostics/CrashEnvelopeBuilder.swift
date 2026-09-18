//
//  CrashEnvelopeBuilder.swift
//  BisonNotes AI
//

import CryptoKit
import Foundation
import MetricKit

struct CrashEnvelopeBuilder {
    static func build(
        input: DiagnosticReportInput,
        consent: DiagnosticConsentSnapshot,
        receivingRuntime: DiagnosticRuntimeInfo,
        contextEvents: [DiagnosticEvent],
        receivedAt: Date
    ) -> CrashEnvelope? {
        guard consent.isEnabled,
              let consentEpoch = consent.epoch,
              let enabledAt = consent.enabledAt,
              input.incidentStart >= enabledAt else {
            // A delayed Apple delivery may cover a period before opt-in. Do
            // not send any portion of that report after consent is granted.
            return nil
        }

        let interval = DateInterval(start: input.incidentStart, end: input.incidentEnd)
        let matchingContext = contextMatch(
            input: input,
            events: input.source == .lifecycleHeuristic ? [] : contextEvents,
            interval: interval
        )

        let operation = matchingContext.event?.operation ?? .unknown
        let phase = matchingContext.event?.phase ?? .unknown
        let result = matchingContext.event?.result ?? .unknown
        let state = matchingContext.event?.state ?? DiagnosticState(
            foregroundState: .unknown,
            isRecording: false,
            isSyncing: false
        )
        let measurements = matchingContext.event?.measurements ?? DiagnosticMeasurements(
            operationCount: .unknown,
            duration: .unknown,
            memoryPressure: .unknown,
            thermalState: .unknown
        )

        let provenance = DiagnosticProvenance(
            source: input.source,
            incidentStart: input.incidentStart,
            incidentEnd: input.incidentEnd,
            affectedRuntime: input.affectedRuntime,
            receiptAt: receivedAt,
            contextAssociation: matchingContext.association
        )
        let report = DiagnosticReportDetails(
            kind: input.kind,
            resourceKind: input.resourceKind,
            failure: input.failure,
            stack: input.stack,
            provenance: provenance
        )

        let sessionToken = matchingContext.event?.sessionToken ?? UUID()
        guard let eventID = DiagnosticEventIdentifier.make(
            input: input,
            consentEpoch: consentEpoch
        ) else {
            return nil
        }
        let envelope = CrashEnvelope(
            schemaVersion: DiagnosticPolicy.schemaVersion,
            idempotencyKey: eventID,
            consentEpoch: consentEpoch,
            sessionToken: sessionToken,
            receivedAt: receivedAt,
            affectedRuntime: input.affectedRuntime,
            receivingRuntime: receivingRuntime,
            operation: operation,
            phase: phase,
            result: result,
            state: state,
            measurements: measurements,
            report: report
        )

        guard envelope.encodedSize ?? (DiagnosticPolicy.maximumEnvelopeBytes + 1)
                <= DiagnosticPolicy.maximumEnvelopeBytes else {
            return nil
        }
        return envelope
    }

    private static func contextMatch(
        input: DiagnosticReportInput,
        events: [DiagnosticEvent],
        interval: DateInterval
    ) -> (association: DiagnosticContextAssociation, event: DiagnosticEvent?) {
        let candidates = events.filter { event in
            event.report == nil
                && event.applicationVersion == input.affectedRuntime.appVersion
                && event.applicationBuild == input.affectedRuntime.appBuild
                && interval.contains(event.occurredAt)
        }
        let sessions = Set(candidates.map(\.sessionToken))
        guard sessions.count == 1,
              let event = candidates.max(by: { $0.occurredAt < $1.occurredAt }) else {
            return (.unknown, nil)
        }
        return (.matched, event)
    }
}

private enum DiagnosticEventIdentifier {
    private struct FingerprintMaterial: Codable {
        let input: DiagnosticReportInput
        let consentEpoch: UUID
    }

    static func make(input: DiagnosticReportInput, consentEpoch: UUID) -> UUID? {
        guard let data = try? DiagnosticPolicy.jsonEncoder().encode(
            FingerprintMaterial(input: input, consentEpoch: consentEpoch)
        ) else {
            return nil
        }
        let digest = SHA256.hash(data: data)
        let bytes = Array(digest.prefix(16))
        guard bytes.count == 16 else { return nil }
        let uuid: uuid_t = (
            bytes[0], bytes[1], bytes[2], bytes[3],
            bytes[4], bytes[5], bytes[6], bytes[7],
            bytes[8], bytes[9], bytes[10], bytes[11],
            bytes[12], bytes[13], bytes[14], bytes[15]
        )
        return UUID(uuid: uuid)
    }
}

actor DiagnosticReportingService {
    static let shared = DiagnosticReportingService()

    private struct RuntimeContext: Sendable {
        let consentEpoch: UUID
        let sessionToken: UUID
        let runtime: DiagnosticRuntimeInfo
        var foregroundState: DiagnosticForegroundState
        var isRecording: Bool
        var isSyncing: Bool
        var operation: DiagnosticOperation
        var phase: DiagnosticPhase
        var result: DiagnosticOperationResult
        var operationStartedAt: Date?
        var operationCount: Int
    }

    private let consentStore: DiagnosticConsentStore
    private let eventStore: DiagnosticEventStore
    private let uploadQueue: DiagnosticUploadQueue
    private let runtime: DiagnosticRuntimeInfo
    private let now: @Sendable () -> Date
    private var context: RuntimeContext?

    init(
        consentStore: DiagnosticConsentStore = .shared,
        eventStore: DiagnosticEventStore = DiagnosticEventStore(),
        uploadQueue: DiagnosticUploadQueue = DiagnosticUploadQueue(
            uploader: DiagnosticUploadConfiguration.productionDisabled.endpoint.map {
                DiagnosticUploader(endpoint: $0)
            }
        ),
        runtime: DiagnosticRuntimeInfo = .current(),
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.consentStore = consentStore
        self.eventStore = eventStore
        self.uploadQueue = uploadQueue
        self.runtime = runtime
        self.now = now
    }

    func startSession() async {
        let consent = consentStore.snapshot(now: now())
        guard consent.isEnabled, let epoch = consent.epoch else {
            context = nil
            await eventStore.clear()
            await uploadQueue.clear()
            return
        }
        await startSession(epoch: epoch, at: now())
        await uploadQueue.process(consent: consent)
    }

    func setConsent(enabled: Bool) async {
        let changedAt = now()
        let consent = consentStore.setEnabled(enabled, now: changedAt)
        context = nil
        await eventStore.clear()
        await uploadQueue.clear()
        guard enabled, let epoch = consent.epoch else { return }
        await startSession(epoch: epoch, at: changedAt)
    }

    func updateLifecycle(_ state: DiagnosticForegroundState) async {
        guard var context, consentIsCurrent(context.consentEpoch) else { return }
        context.foregroundState = state
        context.phase = .progress
        context.result = .unknown
        self.context = context
        await appendContextEvent(context, at: now())
    }

    func processPending() async {
        let consent = consentStore.snapshot(now: now())
        await uploadQueue.process(consent: consent)
    }

    func beginOperation(
        _ operation: DiagnosticOperation,
        isRecording: Bool? = nil,
        isSyncing: Bool? = nil,
        operationCount: Int? = nil
    ) async {
        guard var context, consentIsCurrent(context.consentEpoch) else { return }
        let timestamp = now()
        context.operation = operation
        context.phase = .begin
        context.result = .unknown
        context.operationStartedAt = timestamp
        context.operationCount += operationCount ?? 1
        if let isRecording { context.isRecording = isRecording }
        if let isSyncing { context.isSyncing = isSyncing }
        self.context = context
        await appendContextEvent(context, at: timestamp)
    }

    func finishOperation(
        _ operation: DiagnosticOperation,
        result: DiagnosticOperationResult,
        isRecording: Bool? = nil,
        isSyncing: Bool? = nil
    ) async {
        guard var context, consentIsCurrent(context.consentEpoch) else { return }
        let timestamp = now()
        context.operation = operation
        context.phase = .end
        context.result = result
        if let isRecording { context.isRecording = isRecording }
        if let isSyncing { context.isSyncing = isSyncing }
        self.context = context
        await appendContextEvent(context, at: timestamp)
    }

    func updateRecordingState(_ isRecording: Bool) async {
        guard var context, consentIsCurrent(context.consentEpoch) else { return }
        context.isRecording = isRecording
        context.phase = .progress
        self.context = context
        await appendContextEvent(context, at: now())
    }

    func ingest(_ input: DiagnosticReportInput, receivedAt: Date? = nil) async {
        let receipt = receivedAt ?? now()
        let consent = consentStore.snapshot(now: receipt)
        guard consent.isEnabled,
              let enabledAt = consent.enabledAt,
              input.incidentStart >= enabledAt else {
            return
        }

        let contextEvents: [DiagnosticEvent]
        if input.source == .lifecycleHeuristic {
            contextEvents = []
        } else {
            let interval = DateInterval(start: input.incidentStart, end: input.incidentEnd)
            contextEvents = await eventStore.events(
                overlapping: interval,
                applicationVersion: input.affectedRuntime.appVersion,
                applicationBuild: input.affectedRuntime.appBuild
            )
        }

        guard let envelope = CrashEnvelopeBuilder.build(
            input: input,
            consent: consent,
            receivingRuntime: runtime,
            contextEvents: contextEvents,
            receivedAt: receipt
        ) else {
            return
        }
        guard !(await eventStore.containsEventID(envelope.idempotencyKey)) else {
            return
        }
        await eventStore.append(envelope.diagnosticEvent)
        _ = await uploadQueue.enqueue(envelope)
        await uploadQueue.process(consent: consent)
    }

    func ingestLegacyPayloads(_ payloads: [MXDiagnosticPayload]) async {
        for input in MetricKitDiagnosticAdapter.inputs(from: payloads) {
            await ingest(input)
        }
    }

    #if os(iOS) || os(macOS)
    @available(iOS 27.0, macOS 27.0, *)
    func ingestModernReport(_ report: MetricKit.DiagnosticReport) async {
        await ingest(ModernMetricKitDiagnosticProjector.input(from: report))
    }
    #endif

    func recordUnexpectedTerminationHeuristic() async {
        let timestamp = now()
        guard consentStore.recordUnexpectedTerminationIfEligible(now: timestamp) else { return }

        let input = DiagnosticReportInput(
            kind: .unexpectedTermination,
            source: .lifecycleHeuristic,
            incidentStart: timestamp,
            incidentEnd: timestamp,
            affectedRuntime: runtime
        )
        await ingest(input, receivedAt: timestamp)
    }

    private func startSession(epoch: UUID, at timestamp: Date) async {
        let context = RuntimeContext(
            consentEpoch: epoch,
            sessionToken: UUID(),
            runtime: runtime,
            foregroundState: .unknown,
            isRecording: false,
            isSyncing: false,
            operation: .idle,
            phase: .begin,
            result: .unknown,
            operationStartedAt: nil,
            operationCount: 0
        )
        self.context = context
        await appendContextEvent(context, at: timestamp)
    }

    private func appendContextEvent(_ context: RuntimeContext, at timestamp: Date) async {
        let consent = consentStore.snapshot(now: timestamp)
        guard consent.isEnabled,
              consent.epoch == context.consentEpoch else {
            return
        }

        let event = DiagnosticEvent(
            eventID: UUID(),
            consentEpoch: context.consentEpoch,
            sessionToken: context.sessionToken,
            occurredAt: timestamp,
            applicationVersion: context.runtime.appVersion,
            applicationBuild: context.runtime.appBuild,
            operation: context.operation,
            phase: context.phase,
            result: context.result,
            state: DiagnosticState(
                foregroundState: context.foregroundState,
                isRecording: context.isRecording,
                isSyncing: context.isSyncing
            ),
            measurements: DiagnosticMeasurements(
                operationCount: DiagnosticCountBucket.from(context.operationCount),
                duration: DiagnosticDurationBucket.from(
                    context.operationStartedAt.map { timestamp.timeIntervalSince($0) }
                ),
                memoryPressure: .unknown,
                thermalState: currentThermalState()
            ),
            report: nil
        )
        await eventStore.append(event)
    }

    private func consentIsCurrent(_ epoch: UUID) -> Bool {
        let consent = consentStore.snapshot(now: now())
        return consent.isEnabled && consent.epoch == epoch
    }

    private func currentThermalState() -> DiagnosticThermalState {
        switch ProcessInfo.processInfo.thermalState {
        case .nominal: return .nominal
        case .fair: return .fair
        case .serious: return .serious
        case .critical: return .critical
        @unknown default: return .unknown
        }
    }
}
