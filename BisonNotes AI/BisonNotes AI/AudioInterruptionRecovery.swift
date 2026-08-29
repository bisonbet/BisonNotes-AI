//
//  AudioInterruptionRecovery.swift
//  BisonNotes AI
//
//  Deterministic state and error seams for iOS recording recovery.
//

import Foundation

#if os(iOS)
import AVFoundation

enum AudioRecoveryTrigger: String, Equatable, Sendable {
    case interruptionEnded
    case unexpectedBackgroundStop
    case foregroundReconciliation
}

enum AudioRecoveryPhase: String, Equatable, Sendable {
    case idle
    case interruptedWaiting
    case finalizing
    case activating
    case startingContinuation
    case deferredUntilForeground
    case stoppedOrRecovered
}

struct AudioRecoveryRequest: Equatable, Sendable {
    let id: UUID
    let recordingSessionID: UUID
    let trigger: AudioRecoveryTrigger
    let recordingURL: URL

    init(
        id: UUID = UUID(),
        recordingSessionID: UUID,
        trigger: AudioRecoveryTrigger,
        recordingURL: URL
    ) {
        self.id = id
        self.recordingSessionID = recordingSessionID
        self.trigger = trigger
        self.recordingURL = recordingURL
    }
}

enum AudioRecoveryRequestResult: Equatable, Sendable {
    case started(UUID)
    case coalesced(UUID)
    case ignored
}

enum AudioRecoveryExecutionResult: Equatable, Sendable {
    case recovered
    case deferredUntilForeground
    case stopped
    case cancelled
}

protocol AudioRecoverySleeping: Sendable {
    func sleep(for seconds: TimeInterval) async throws
}

struct TaskAudioRecoverySleeper: AudioRecoverySleeping, Sendable {
    func sleep(for seconds: TimeInterval) async throws {
        guard seconds > 0 else { return }
        try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
    }
}

/// Owns the one in-flight recovery operation for a recording session.
///
/// The coordinator is deliberately MainActor-isolated. Notification handlers,
/// CallKit callbacks, timers, and UI actions all enter through `request`, so a
/// second callback can join the active operation but can never create another
/// retry loop. A foreground request is retained as a bounded follow-up only
/// when the active operation explicitly deferred for foreground execution.
@MainActor
final class AudioInterruptionRecoveryCoordinator {
    typealias Operation = @MainActor @Sendable (AudioRecoveryRequest) async -> AudioRecoveryExecutionResult

    private(set) var phase: AudioRecoveryPhase = .idle
    private(set) var activeRequestID: UUID?
    private(set) var operationCount = 0
    private(set) var coalescedRequestCount = 0

    private var recordingSessionID: UUID?
    private var activeTask: Task<Void, Never>?
    private var pendingRequest: AudioRecoveryRequest?

    func beginRecordingSession(_ id: UUID) {
        cancel(reason: "new recording")
        recordingSessionID = id
        phase = .idle
    }

    func markInterrupted(for recordingSessionID: UUID) {
        guard self.recordingSessionID == recordingSessionID else { return }
        guard activeTask == nil else { return }
        phase = .interruptedWaiting
    }

    func request(
        _ request: AudioRecoveryRequest,
        operation: @escaping Operation
    ) -> AudioRecoveryRequestResult {
        guard request.recordingSessionID == recordingSessionID else {
            return .ignored
        }

        if let activeRequestID {
            coalescedRequestCount += 1
            if shouldKeepAsFollowUp(request) {
                pendingRequest = request
            }
            return .coalesced(activeRequestID)
        }

        operationCount += 1
        activeRequestID = request.id
        activeTask = Task { @MainActor [weak self, operation] in
            guard let self else { return }

			var currentRequest = request
			var result = await operation(currentRequest)

			while result == .deferredUntilForeground, !Task.isCancelled {
				self.phase = .deferredUntilForeground
				guard let followUp = self.takeForegroundFollowUp(for: currentRequest) else {
					break
				}
				self.operationCount += 1
				self.activeRequestID = followUp.id
				currentRequest = followUp
				result = await operation(currentRequest)
			}

            self.complete(currentRequestID: currentRequest.id, result: result)
        }

        return .started(request.id)
    }

    func updatePhase(_ newPhase: AudioRecoveryPhase, for requestID: UUID) {
        guard activeRequestID == requestID else { return }
        phase = newPhase
    }

    func accepts(_ request: AudioRecoveryRequest) -> Bool {
        request.recordingSessionID == recordingSessionID && request.id == activeRequestID
    }

    func accepts(requestID: UUID, recordingSessionID: UUID) -> Bool {
        self.recordingSessionID == recordingSessionID && activeRequestID == requestID
    }

    func waitForCompletion() async {
        await activeTask?.value
    }

    func cancel(reason: String) {
        let cancelledRequestID = activeRequestID ?? pendingRequest?.id
        if let cancelledRequestID {
            AppLog.shared.audioSession(
                "Audio recovery \(cancelledRequestID.uuidString) cancelled: \(reason)",
                level: .debug
            )
        }
        activeTask?.cancel()
        activeTask = nil
        activeRequestID = nil
        pendingRequest = nil
        phase = .stoppedOrRecovered
    }

    func invalidateRecordingSession(reason: String) {
        cancel(reason: reason)
        recordingSessionID = nil
    }

    private func shouldKeepAsFollowUp(_ request: AudioRecoveryRequest) -> Bool {
        request.trigger == .foregroundReconciliation
    }

    private func takeForegroundFollowUp(
        for request: AudioRecoveryRequest
    ) -> AudioRecoveryRequest? {
        guard phase == .deferredUntilForeground,
              let pendingRequest,
              pendingRequest.recordingSessionID == request.recordingSessionID,
              pendingRequest.trigger == .foregroundReconciliation else {
            self.pendingRequest = nil
            return nil
        }

        self.pendingRequest = nil
        return pendingRequest
    }

    private func complete(
        currentRequestID: UUID,
        result: AudioRecoveryExecutionResult
    ) {
        guard activeRequestID == currentRequestID else { return }
        activeTask = nil
        activeRequestID = nil

        let outcome: String
        switch result {
        case .recovered: outcome = "recovered"
        case .deferredUntilForeground: outcome = "deferred"
        case .stopped: outcome = "terminated"
        case .cancelled: outcome = "cancelled"
        }
        AppLog.shared.audioSession(
            "Audio recovery \(currentRequestID.uuidString) completed: \(outcome)",
            level: .debug
        )

        switch result {
        case .deferredUntilForeground:
            phase = .deferredUntilForeground
        case .recovered, .stopped, .cancelled:
            phase = .stoppedOrRecovered
            pendingRequest = nil
        }
    }
}

enum AudioActivationFailureCategory: String, Equatable, Sendable {
    case insufficientPriority
    case busy
    case mediaServicesReset
    case transient
    case permanent
    case unknown
}

enum AudioActivationDisposition: String, Equatable, Sendable {
    case retry
    case deferUntilForeground = "defer"
    case fail
}

struct AudioActivationFailure: Error, Equatable, LocalizedError, Sendable {
    let domain: String
    let code: Int
    let category: AudioActivationFailureCategory
    let attempt: Int
    let disposition: AudioActivationDisposition
    let message: String

    init(error: Error, attempt: Int, appIsBackgrounding: Bool) {
        let nsError = error as NSError
        let category = Self.category(for: nsError)

        self.domain = nsError.domain
        self.code = nsError.code
        self.category = category
        self.attempt = attempt
        self.disposition = Self.disposition(
            for: category,
            attempt: attempt,
            appIsBackgrounding: appIsBackgrounding
        )
        self.message = nsError.localizedDescription
    }

    var errorDescription: String? {
        let evidence = [
            "domain: \(domain)",
            "code: \(code)",
            "category: \(category.rawValue)",
            "attempt: \(attempt)",
            "disposition: \(disposition.rawValue)"
        ].joined(separator: ", ")
        return "Audio session activation failed (\(evidence)): \(message)"
    }

    static func category(for error: NSError) -> AudioActivationFailureCategory {
        switch error.code {
        case AVAudioSession.ErrorCode.insufficientPriority.rawValue:
            return .insufficientPriority
        case AVAudioSession.ErrorCode.isBusy.rawValue:
            return .busy
        case AVAudioSession.ErrorCode.mediaServicesFailed.rawValue,
             AVAudioSession.ErrorCode.resourceNotAvailable.rawValue,
             AVAudioSession.ErrorCode.expiredSession.rawValue:
            return .mediaServicesReset
        case AVAudioSession.ErrorCode.cannotStartRecording.rawValue,
             AVAudioSession.ErrorCode.cannotInterruptOthers.rawValue,
             AVAudioSession.ErrorCode.siriIsRecording.rawValue:
            return .transient
        case AVAudioSession.ErrorCode.missingEntitlement.rawValue,
             AVAudioSession.ErrorCode.incompatibleCategory.rawValue,
             AVAudioSession.ErrorCode.badParam.rawValue:
            return .permanent
        default:
            return .unknown
        }
    }

    static func disposition(
        for category: AudioActivationFailureCategory,
        attempt: Int,
        appIsBackgrounding: Bool,
        maximumAttempts: Int = 3
    ) -> AudioActivationDisposition {
        switch category {
        case .insufficientPriority:
            return appIsBackgrounding
                ? .deferUntilForeground
                : (attempt < maximumAttempts ? .retry : .fail)
        case .busy, .mediaServicesReset, .transient:
            return attempt < maximumAttempts ? .retry : .fail
        case .permanent, .unknown:
            return .fail
        }
    }
}

enum AudioSessionRecoveryError: Error, Equatable, LocalizedError, Sendable {
    case missingConfiguration
    case recorderDidNotStart

    var errorDescription: String? {
        switch self {
        case .missingConfiguration:
            return "The recording audio session has no configuration to activate."
        case .recorderDidNotStart:
            return "The continuation recorder did not start."
        }
    }
}

struct CallInterruptionTracker: Equatable, Sendable {
    private(set) var starts: [UUID: Date] = [:]

    var hasActiveCalls: Bool {
        !starts.isEmpty
    }

    mutating func observeStart(id: UUID, at date: Date) {
        if starts[id] == nil {
            starts[id] = date
        }
    }

    mutating func observeEnd(id: UUID) -> Date? {
        starts.removeValue(forKey: id)
    }

    mutating func removeAll() {
        starts.removeAll()
    }
}

enum CallInterruptionDuration {
    static func seconds(
        callStartedAt: Date?,
        interruptionStartedAt: Date,
        endedAt: Date
    ) -> TimeInterval {
        endedAt.timeIntervalSince(callStartedAt ?? interruptionStartedAt)
    }
}

#endif
