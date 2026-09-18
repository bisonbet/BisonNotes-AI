//
//  DiagnosticModels.swift
//  BisonNotes AI
//
//  The automatic diagnostic pipeline deliberately uses a small, closed schema.
//  Do not add free-form strings, arbitrary dictionaries, recording identifiers,
//  or raw Apple payloads to these types.
//

import Foundation

#if canImport(Darwin)
import Darwin
#endif

enum DiagnosticPolicy {
    static let schemaVersion = 1

    static let maximumStructuredEvents = 64
    static let maximumEventStoreBytes = 32 * 1024
    static let eventRetention: TimeInterval = 48 * 60 * 60

    static let maximumQueuedEnvelopes = 20
    static let maximumQueueBytes = 2 * 1024 * 1024
    static let maximumEnvelopeBytes = 128 * 1024
    static let queueRetention: TimeInterval = 7 * 24 * 60 * 60

    static let maximumManualPayloads = 5
    static let maximumManualPayloadBytes = 1024 * 1024
    static let manualPayloadRetention: TimeInterval = 7 * 24 * 60 * 60

    static let serverRetentionDays = 14
    static let maximumStackThreads = 32
    static let maximumFramesPerThread = 64
    static let maximumStackFrames = 256
    static let maximumFrameOffset = UInt64(1) << 48

    static func jsonEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }

    static func jsonDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}

private enum DiagnosticValueSanitizer {
    static func version(_ value: String?, fallback: String = "unknown") -> String {
        bounded(value, maximumLength: 64, allowed: { scalar in
            isASCIIAlphaNumeric(scalar) || scalar == 45 || scalar == 46 || scalar == 95 || scalar == 43
        }, fallback: fallback)
    }

    static func hardwareModel(_ value: String?, fallback: String = "unknown") -> String {
        let candidate = bounded(value, maximumLength: 48, allowed: { scalar in
            isASCIIAlphaNumeric(scalar) || scalar == 44 || scalar == 45 || scalar == 46 || scalar == 95
        }, fallback: "")

        // Apple hardware identifiers look like iPhone17,1 or Mac15,7. Reject
        // display names and unexpected strings rather than transmitting them.
        guard candidate.range(of: "^[A-Za-z]+[0-9]+,[0-9]+$", options: .regularExpression) != nil else {
            return fallback
        }
        return candidate
    }

    static func bounded(
        _ value: String?,
        maximumLength: Int,
        allowed: (UInt32) -> Bool,
        fallback: String
    ) -> String {
        guard let value else { return fallback }

        let scalars = value.unicodeScalars.prefix(maximumLength).compactMap { scalar -> UnicodeScalar? in
            allowed(scalar.value) ? scalar : nil
        }
        let result = String(String.UnicodeScalarView(scalars))
        return result.isEmpty ? fallback : result
    }

    private static func isASCIIAlphaNumeric(_ scalar: UInt32) -> Bool {
        (48...57).contains(scalar) || (65...90).contains(scalar) || (97...122).contains(scalar)
    }
}

enum DiagnosticPlatform: String, Codable, Sendable {
    case iOS = "ios"
    case macOS = "macos"
    case unknown

    static var current: DiagnosticPlatform {
        #if os(iOS)
        return .iOS
        #elseif os(macOS)
        return .macOS
        #else
        return .unknown
        #endif
    }
}

enum DiagnosticForegroundState: String, Codable, Sendable {
    case foreground
    case background
    case inactive
    case unknown
}

enum DiagnosticOperation: String, Codable, Sendable {
    case icloudSync = "icloud_sync"
    case recordingFinalize = "recording_finalize"
    case liveTranscription = "live_transcription"
    case backgroundProcessing = "background_processing"
    case idle
    case unknown
}

enum DiagnosticPhase: String, Codable, Sendable {
    case begin
    case progress
    case end
    case unknown
}

enum DiagnosticOperationResult: String, Codable, Sendable {
    case success
    case failure
    case cancelled
    case unknown
}

enum DiagnosticReportKind: String, Codable, Sendable {
    case appleCrash = "apple_crash"
    case appleHang = "apple_hang"
    case resourceDiagnostic = "resource_diagnostic"
    case unexpectedTermination = "unexpected_termination"
}

enum DiagnosticResourceKind: String, Codable, Sendable {
    case cpuException = "cpu_exception"
    case diskWriteException = "disk_write_exception"
    case memoryException = "memory_exception"
    case appLaunch = "app_launch"
}

enum DiagnosticSource: String, Codable, Sendable {
    case legacyMetricKit = "legacy_metrickit"
    case modernMetricKit = "modern_metrickit"
    case lifecycleHeuristic = "lifecycle_heuristic"
}

enum DiagnosticContextAssociation: String, Codable, Sendable {
    case matched
    case unknown
    case notApplicable = "not_applicable"
}

enum DiagnosticTerminationCategory: String, Codable, Sendable {
    case badAccess = "bad_access"
    case abnormal
    case illegalInstruction = "illegal_instruction"
    case watchdog
    case taskTimeout = "task_timeout"
    case fileLock = "file_lock"
    case memory
    case unknown

    static func fromAppleValue(_ value: String?) -> DiagnosticTerminationCategory {
        guard let value else { return .unknown }
        let normalized = value
            .lowercased()
            .replacingOccurrences(of: " ", with: "_")
            .replacingOccurrences(of: "-", with: "_")

        switch normalized {
        case "bad_access", "badaccess": return .badAccess
        case "abnormal": return .abnormal
        case "illegal_instruction", "illegalinstruction": return .illegalInstruction
        case "watchdog": return .watchdog
        case "task_timeout", "tasktimeout": return .taskTimeout
        case "file_lock", "filelock": return .fileLock
        case "memory", "memory_exception", "memoryexception": return .memory
        default: return .unknown
        }
    }
}

enum DiagnosticCountBucket: String, Codable, Sendable {
    case none
    case one
    case twoToFive = "two_to_five"
    case sixToTen = "six_to_ten"
    case moreThanTen = "more_than_ten"
    case unknown

    static func from(_ count: Int?) -> DiagnosticCountBucket {
        guard let count, count >= 0 else { return .unknown }
        switch count {
        case 0: return .none
        case 1: return .one
        case 2...5: return .twoToFive
        case 6...10: return .sixToTen
        default: return .moreThanTen
        }
    }
}

enum DiagnosticDurationBucket: String, Codable, Sendable {
    case lessThanOneSecond = "less_than_one_second"
    case oneToTenSeconds = "one_to_ten_seconds"
    case tenToSixtySeconds = "ten_to_sixty_seconds"
    case oneToFiveMinutes = "one_to_five_minutes"
    case moreThanFiveMinutes = "more_than_five_minutes"
    case unknown

    static func from(_ duration: TimeInterval?) -> DiagnosticDurationBucket {
        guard let duration, duration.isFinite, duration >= 0 else { return .unknown }
        switch duration {
        case ..<1: return .lessThanOneSecond
        case ..<10: return .oneToTenSeconds
        case ..<60: return .tenToSixtySeconds
        case ..<300: return .oneToFiveMinutes
        default: return .moreThanFiveMinutes
        }
    }
}

enum DiagnosticMemoryPressure: String, Codable, Sendable {
    case normal
    case warning
    case critical
    case unknown
}

enum DiagnosticThermalState: String, Codable, Sendable {
    case nominal
    case fair
    case serious
    case critical
    case unknown
}

enum DiagnosticImageKind: String, Codable, Sendable {
    case application
    case reviewedFramework = "reviewed_framework"
}

struct DiagnosticRuntimeInfo: Codable, Sendable, Equatable {
    let appVersion: String
    let appBuild: String
    let osVersion: String
    let platform: DiagnosticPlatform
    let hardwareModel: String

    init(
        appVersion: String?,
        appBuild: String?,
        osVersion: String?,
        platform: DiagnosticPlatform = .current,
        hardwareModel: String?
    ) {
        self.appVersion = DiagnosticValueSanitizer.version(appVersion)
        self.appBuild = DiagnosticValueSanitizer.version(appBuild)
        self.osVersion = DiagnosticValueSanitizer.version(osVersion)
        self.platform = platform
        self.hardwareModel = DiagnosticValueSanitizer.hardwareModel(hardwareModel)
    }

    static func current(bundle: Bundle = .main) -> DiagnosticRuntimeInfo {
        let version = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        let build = bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String
        let operatingSystem = ProcessInfo.processInfo.operatingSystemVersion
        return DiagnosticRuntimeInfo(
            appVersion: version,
            appBuild: build,
            osVersion: "\(operatingSystem.majorVersion).\(operatingSystem.minorVersion).\(operatingSystem.patchVersion)",
            platform: .current,
            hardwareModel: hardwareModelIdentifier()
        )
    }

    private static func hardwareModelIdentifier() -> String {
        #if canImport(Darwin)
        var size = 0
        guard sysctlbyname("hw.machine", nil, &size, nil, 0) == 0, size > 1 else {
            return "unknown"
        }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname("hw.machine", &buffer, &size, nil, 0) == 0 else {
            return "unknown"
        }
        let bytes = buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
        return String(bytes: bytes, encoding: .utf8) ?? "unknown"
        #else
        return "unknown"
        #endif
    }
}

struct DiagnosticState: Codable, Sendable, Equatable {
    let foregroundState: DiagnosticForegroundState
    let isRecording: Bool
    let isSyncing: Bool
}

struct DiagnosticMeasurements: Codable, Sendable, Equatable {
    let operationCount: DiagnosticCountBucket
    let duration: DiagnosticDurationBucket
    let memoryPressure: DiagnosticMemoryPressure
    let thermalState: DiagnosticThermalState
}

struct DiagnosticFailure: Codable, Sendable, Equatable {
    let exceptionType: Int32?
    let exceptionCode: UInt64?
    let signal: Int32?
    let terminationCategory: DiagnosticTerminationCategory

    init(
        exceptionType: Int32? = nil,
        exceptionCode: UInt64? = nil,
        signal: Int32? = nil,
        terminationCategory: DiagnosticTerminationCategory = .unknown
    ) {
        self.exceptionType = exceptionType
        self.exceptionCode = exceptionCode
        self.signal = signal
        self.terminationCategory = terminationCategory
    }
}

struct DiagnosticStackFrame: Codable, Sendable, Equatable, Hashable {
    let imageUUID: UUID
    let offsetIntoBinaryTextSegment: UInt64
    let imageKind: DiagnosticImageKind

    init(imageUUID: UUID, offsetIntoBinaryTextSegment: UInt64, imageKind: DiagnosticImageKind) {
        self.imageUUID = imageUUID
        self.offsetIntoBinaryTextSegment = min(
            offsetIntoBinaryTextSegment,
            DiagnosticPolicy.maximumFrameOffset
        )
        self.imageKind = imageKind
    }
}

struct DiagnosticStackThread: Codable, Sendable, Equatable {
    let frames: [DiagnosticStackFrame]

    init(frames: [DiagnosticStackFrame]) {
        self.frames = Array(frames.prefix(DiagnosticPolicy.maximumFramesPerThread))
    }
}

struct DiagnosticStack: Codable, Sendable, Equatable {
    let threads: [DiagnosticStackThread]
    let truncated: Bool

    init(threads: [DiagnosticStackThread], truncated: Bool = false) {
        var remaining = DiagnosticPolicy.maximumStackFrames
        var normalized = [DiagnosticStackThread]()
        var didTruncate = truncated || threads.count > DiagnosticPolicy.maximumStackThreads

        for thread in threads.prefix(DiagnosticPolicy.maximumStackThreads) {
            guard remaining > 0 else {
                didTruncate = true
                break
            }
            let frames = Array(thread.frames.prefix(remaining))
            if frames.count != thread.frames.count {
                didTruncate = true
            }
            normalized.append(DiagnosticStackThread(frames: frames))
            remaining -= frames.count
        }

        self.threads = normalized
        self.truncated = didTruncate
    }
}

struct DiagnosticProvenance: Codable, Sendable, Equatable {
    let source: DiagnosticSource
    let incidentStart: Date
    let incidentEnd: Date
    let affectedRuntime: DiagnosticRuntimeInfo
    let receiptAt: Date
    let contextAssociation: DiagnosticContextAssociation
}

struct DiagnosticReportDetails: Codable, Sendable, Equatable {
    let kind: DiagnosticReportKind
    let resourceKind: DiagnosticResourceKind?
    let failure: DiagnosticFailure?
    let stack: DiagnosticStack?
    let provenance: DiagnosticProvenance
}

/// A local event is either a bounded context transition or an Apple report
/// projection. It never contains an OSLog line, raw exception text, or a user
/// content identifier.
struct DiagnosticEvent: Codable, Sendable, Equatable {
    let eventID: UUID
    let consentEpoch: UUID
    let sessionToken: UUID
    let occurredAt: Date
    let applicationVersion: String
    let applicationBuild: String
    let operation: DiagnosticOperation
    let phase: DiagnosticPhase
    let result: DiagnosticOperationResult
    let state: DiagnosticState
    let measurements: DiagnosticMeasurements
    let report: DiagnosticReportDetails?
}

struct CrashEnvelope: Codable, Sendable, Equatable {
    let schemaVersion: Int
    let idempotencyKey: UUID
    let consentEpoch: UUID
    let sessionToken: UUID
    let receivedAt: Date
    let affectedRuntime: DiagnosticRuntimeInfo
    let receivingRuntime: DiagnosticRuntimeInfo
    let operation: DiagnosticOperation
    let phase: DiagnosticPhase
    let result: DiagnosticOperationResult
    let state: DiagnosticState
    let measurements: DiagnosticMeasurements
    let report: DiagnosticReportDetails

    var encodedSize: Int? {
        guard let data = try? DiagnosticPolicy.jsonEncoder().encode(self) else { return nil }
        return data.count
    }
}

extension CrashEnvelope {
    var diagnosticEvent: DiagnosticEvent {
        DiagnosticEvent(
            eventID: idempotencyKey,
            consentEpoch: consentEpoch,
            sessionToken: sessionToken,
            occurredAt: receivedAt,
            applicationVersion: receivingRuntime.appVersion,
            applicationBuild: receivingRuntime.appBuild,
            operation: operation,
            phase: phase,
            result: result,
            state: state,
            measurements: measurements,
            report: report
        )
    }
}

struct DiagnosticConsentSnapshot: Sendable, Equatable {
    let isEnabled: Bool
    let epoch: UUID?
    let enabledAt: Date?
}

enum DiagnosticStorageSupport {
    static let directoryName = "AutomaticDiagnostics"
    static let eventStoreFileName = "events.json"
    static let queueFileName = "queue.json"

    static func defaultDirectory(fileManager: FileManager = .default) -> URL? {
        guard let appSupport = fileManager.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first else {
            return nil
        }
        return appSupport.appendingPathComponent(directoryName, isDirectory: true)
    }

    static func prepareDirectory(for fileURL: URL) {
        try? FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
    }

    static func protectAndExcludeFromBackup(_ fileURL: URL) {
        AppFileProtection.apply(to: fileURL)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var mutableURL = fileURL
        try? mutableURL.setResourceValues(values)
    }
}
