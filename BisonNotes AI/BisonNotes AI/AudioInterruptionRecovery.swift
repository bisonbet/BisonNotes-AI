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
    /// An `.ended` event iOS did not tag with `.shouldResume`.
    ///
    /// The system has not authorized reacquiring the microphone, so this
    /// trigger preserves the finalized segment and waits instead of activating.
    case interruptionEndedWithoutResume
    case routeChange
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

            while !Task.isCancelled {
                if result == .deferredUntilForeground {
                    self.phase = .deferredUntilForeground
                }
                guard let followUp = self.takeFollowUp(after: result, for: currentRequest) else {
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

    /// Whether a request that arrived mid-flight is worth retaining.
    ///
    /// A foreground request is the bounded follow-up for a deferral. An ended
    /// interruption is retained too: a second interruption makes the active
    /// operation yield, and coalescing its `.ended` event away would leave the
    /// recording interrupted with nothing left to restart it.
    private func shouldKeepAsFollowUp(_ request: AudioRecoveryRequest) -> Bool {
        switch request.trigger {
        case .foregroundReconciliation,
             .interruptionEnded,
             .interruptionEndedWithoutResume:
            return true
        case .routeChange, .unexpectedBackgroundStop:
            return false
        }
    }

    /// The one follow-up this result authorizes, if such a request is held.
    ///
    /// A foreground request only follows a deferral; an ended interruption also
    /// follows an operation that yielded to the interruption that produced it.
    /// A recovered or terminated operation takes no follow-up, and the pending
    /// slot is always emptied so a retained request can run at most once.
    private func takeFollowUp(
        after result: AudioRecoveryExecutionResult,
        for request: AudioRecoveryRequest
    ) -> AudioRecoveryRequest? {
        let retained = pendingRequest
        pendingRequest = nil
        guard let retained,
              retained.recordingSessionID == request.recordingSessionID else {
            return nil
        }

        switch retained.trigger {
        case .foregroundReconciliation:
            return result == .deferredUntilForeground ? retained : nil
        case .interruptionEnded, .interruptionEndedWithoutResume:
            return result == .deferredUntilForeground || result == .cancelled
                ? retained
                : nil
        case .routeChange, .unexpectedBackgroundStop:
            return nil
        }
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

    /// The activation retry budget for one recovery.
    ///
    /// The Phone app can hold the audio session for many seconds after CallKit
    /// reports the call ended, so the budget deliberately spans ~15s of bounded
    /// backoff. Giving up sooner terminates a recording that would have resumed.
    /// This is the single owner of the bound: call sites must read it rather
    /// than restating the number.
    static let maximumActivationAttempts = 10

    /// The activation retry budget for an error code this app does not map.
    ///
    /// An unmapped code is no evidence that waiting helps, so it may not spend
    /// the call-length budget above: one retry absorbs a transient race, and
    /// anything past that preserves the segment instead of reactivating an
    /// unsupported or contract-violating session another eight times.
    ///
    /// This is a deliberate, recorded deviation from the recovery plan's §5.4,
    /// which groups unknown with permanent errors: see "Accepted deviation:
    /// unmapped error codes retry twice" in
    /// docs/ios-audio-interruption-recovery-delegation-plan.md. Change both
    /// together, or neither.
    static let maximumUnknownActivationAttempts = 2

    static func disposition(
        for category: AudioActivationFailureCategory,
        attempt: Int,
        appIsBackgrounding: Bool,
        maximumAttempts: Int = AudioActivationFailure.maximumActivationAttempts
    ) -> AudioActivationDisposition {
        switch category {
        case .insufficientPriority:
            return appIsBackgrounding
                ? .deferUntilForeground
                : (attempt < maximumAttempts ? .retry : .fail)
        case .busy, .mediaServicesReset, .transient:
            return attempt < maximumAttempts ? .retry : .fail
        // An unmapped error code is not evidence that the session is
        // permanently unavailable, so it is not terminal on the first attempt.
        // It is not evidence that the session will recover either, so it gets
        // its own short bound rather than the full transient budget.
        case .unknown:
            return attempt < min(maximumAttempts, maximumUnknownActivationAttempts)
                ? .retry
                : .fail
        case .permanent:
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
