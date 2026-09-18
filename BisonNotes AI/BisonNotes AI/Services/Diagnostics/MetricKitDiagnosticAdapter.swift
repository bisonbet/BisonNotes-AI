//
//  MetricKitDiagnosticAdapter.swift
//  BisonNotes AI
//

import Foundation
import MetricKit

struct DiagnosticReportInput: Codable, Sendable, Equatable {
    let kind: DiagnosticReportKind
    let resourceKind: DiagnosticResourceKind?
    let source: DiagnosticSource
    let incidentStart: Date
    let incidentEnd: Date
    let affectedRuntime: DiagnosticRuntimeInfo
    let failure: DiagnosticFailure?
    let stack: DiagnosticStack?

    init(
        kind: DiagnosticReportKind,
        resourceKind: DiagnosticResourceKind? = nil,
        source: DiagnosticSource,
        incidentStart: Date,
        incidentEnd: Date,
        affectedRuntime: DiagnosticRuntimeInfo,
        failure: DiagnosticFailure? = nil,
        stack: DiagnosticStack? = nil
    ) {
        self.kind = kind
        self.resourceKind = resourceKind
        self.source = source
        self.incidentStart = min(incidentStart, incidentEnd)
        self.incidentEnd = max(incidentStart, incidentEnd)
        self.affectedRuntime = affectedRuntime
        self.failure = failure
        self.stack = stack
    }
}

/// Keeps raw Apple data exclusively on the user-initiated detailed-export path.
/// Automatic projection never reads this store.
final class ManualMetricKitPayloadStore: @unchecked Sendable {
    static let shared = ManualMetricKitPayloadStore()

    private struct StoredPayload: Codable {
        let receivedAt: Date
        let payload: Data
    }

    private let fileURL: URL
    private let lock = NSLock()

    init(fileURL: URL = ManualMetricKitPayloadStore.defaultFileURL()) {
        self.fileURL = fileURL
    }

    func append(_ payloads: [Data], receivedAt: Date = Date()) {
        guard !payloads.isEmpty else { return }
        lock.lock()
        defer { lock.unlock() }

        var records = loadLocked()
        let cutoff = receivedAt.addingTimeInterval(-DiagnosticPolicy.manualPayloadRetention)
        records.removeAll { $0.receivedAt < cutoff }
        records.append(contentsOf: payloads.map { StoredPayload(receivedAt: receivedAt, payload: $0) })
        records.sort { $0.receivedAt < $1.receivedAt }
        if records.count > DiagnosticPolicy.maximumManualPayloads {
            records.removeFirst(records.count - DiagnosticPolicy.maximumManualPayloads)
        }
        while records.reduce(0, { $0 + $1.payload.count }) > DiagnosticPolicy.maximumManualPayloadBytes,
              !records.isEmpty {
            records.removeFirst()
        }
        persistLocked(records)
    }

    func payloadData(now: Date = Date()) -> [Data] {
        lock.lock()
        defer { lock.unlock() }

        let cutoff = now.addingTimeInterval(-DiagnosticPolicy.manualPayloadRetention)
        let records = loadLocked().filter { $0.receivedAt >= cutoff }
        if records.count != loadLocked().count {
            persistLocked(records)
        }
        return records.map(\.payload)
    }

    private func loadLocked() -> [StoredPayload] {
        guard let data = try? Data(contentsOf: fileURL) else { return [] }
        let decoder = DiagnosticPolicy.jsonDecoder()
        if let records = try? decoder.decode([StoredPayload].self, from: data) {
            return records
        }

        // Migrate the old raw [[String: Any]] file without allowing its fields
        // into the automatic schema.
        guard let json = try? JSONSerialization.jsonObject(with: data),
              let dictionaries = json as? [[String: Any]] else {
            return []
        }
        return dictionaries.compactMap { dictionary in
            guard JSONSerialization.isValidJSONObject(dictionary),
                  let payload = try? JSONSerialization.data(withJSONObject: dictionary) else {
                return nil
            }
            return StoredPayload(receivedAt: Date(), payload: payload)
        }
    }

    private func persistLocked(_ records: [StoredPayload]) {
        guard let data = try? DiagnosticPolicy.jsonEncoder().encode(records) else { return }
        DiagnosticStorageSupport.prepareDirectory(for: fileURL)
        do {
            try data.write(to: fileURL, options: .atomic)
            DiagnosticStorageSupport.protectAndExcludeFromBackup(fileURL)
        } catch {
            // Detailed export remains best effort and must not affect app work.
        }
    }

    private static func defaultFileURL() -> URL {
        let directory = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? FileManager.default.temporaryDirectory
        return directory.appendingPathComponent("metrickit_diagnostics.json")
    }
}

enum LegacyMetricKitStackProjector {
    static func project(_ tree: MXCallStackTree) -> DiagnosticStack? {
        project(jsonData: tree.jsonRepresentation())
    }

    /// Internal fixture seam. The parser walks only dictionaries containing the
    /// reviewed symbolication keys and never copies arbitrary Apple JSON fields.
    static func project(jsonData: Data, bundle: Bundle = .main) -> DiagnosticStack? {
        guard let object = try? JSONSerialization.jsonObject(with: jsonData) else {
            return nil
        }
        var frames = [DiagnosticStackFrame]()
        collectFrames(from: object, bundle: bundle, into: &frames)
        guard !frames.isEmpty else { return nil }
        return DiagnosticStack(threads: [DiagnosticStackThread(frames: frames)])
    }

    private static func collectFrames(
        from value: Any,
        bundle: Bundle,
        into frames: inout [DiagnosticStackFrame]
    ) {
        guard frames.count < DiagnosticPolicy.maximumStackFrames else { return }

        if let dictionary = value as? [String: Any] {
            let imageName = (dictionary["binaryName"] as? String)
                ?? (dictionary["binaryImageName"] as? String)
            if let imageName,
               let kind = DiagnosticImageAllowlist.kind(for: imageName, bundle: bundle),
               let uuid = uuid(from: dictionary["binaryUUID"] ?? dictionary["binaryUuid"]),
               let offset = offset(from: dictionary["offsetIntoBinaryTextSegment"]
                    ?? dictionary["offsetIntoBinaryText"]
                    ?? dictionary["offset"]) {
                frames.append(DiagnosticStackFrame(
                    imageUUID: uuid,
                    offsetIntoBinaryTextSegment: offset,
                    imageKind: kind
                ))
            }
            for child in dictionary.values {
                collectFrames(from: child, bundle: bundle, into: &frames)
            }
        } else if let array = value as? [Any] {
            for child in array {
                collectFrames(from: child, bundle: bundle, into: &frames)
            }
        }
    }

    private static func uuid(from value: Any?) -> UUID? {
        guard let string = value as? String else { return nil }
        return UUID(uuidString: string)
    }

    private static func offset(from value: Any?) -> UInt64? {
        if let number = value as? NSNumber, number.doubleValue.isFinite, number.doubleValue >= 0 {
            return number.uint64Value
        }
        guard let string = value as? String else { return nil }
        if let decimal = UInt64(string) { return decimal }
        let normalized = string.hasPrefix("0x") ? String(string.dropFirst(2)) : string
        return UInt64(normalized, radix: 16)
    }
}

private enum DiagnosticImageAllowlist {
    private static let reviewedFrameworks: Set<String> = [
        "appkit", "avfoundation", "audiotoolbox", "coreaudio", "corefoundation",
        "foundation", "metrickit", "swiftui", "uikit", "libswiftcore.dylib",
        "libswift_concurrency.dylib"
    ]

    static func kind(for rawName: String, bundle: Bundle) -> DiagnosticImageKind? {
        let basename = rawName
            .split(separator: "/")
            .last
            .map(String.init) ?? rawName
        let normalized = basename
            .replacingOccurrences(of: ".framework", with: "", options: .caseInsensitive)
            .lowercased()

        var applicationNames = Set(["bisonnotes ai", "bisonnotes_ai", "bisonnotes"])
        if let executable = bundle.object(forInfoDictionaryKey: "CFBundleExecutable") as? String {
            applicationNames.insert(executable.lowercased())
        }
        if let executable = bundle.executableURL?.lastPathComponent {
            applicationNames.insert(executable.lowercased())
        }

        if applicationNames.contains(normalized) {
            return .application
        }
        if reviewedFrameworks.contains(normalized) {
            return .reviewedFramework
        }
        return nil
    }
}

enum MetricKitDiagnosticAdapter {
    static func inputs(from payloads: [MXDiagnosticPayload]) -> [DiagnosticReportInput] {
        payloads.flatMap { inputs(from: $0) }
    }

    static func inputs(from payload: MXDiagnosticPayload) -> [DiagnosticReportInput] {
        var inputs = [DiagnosticReportInput]()

        for diagnostic in payload.crashDiagnostics ?? [] {
            inputs.append(DiagnosticReportInput(
                kind: .appleCrash,
                source: .legacyMetricKit,
                incidentStart: payload.timeStampBegin,
                incidentEnd: payload.timeStampEnd,
                affectedRuntime: runtime(for: diagnostic),
                failure: DiagnosticFailure(
                    exceptionType: boundedInt32(diagnostic.exceptionType),
                    exceptionCode: boundedUInt64(diagnostic.exceptionCode),
                    signal: boundedInt32(diagnostic.signal),
                    terminationCategory: .unknown
                ),
                stack: LegacyMetricKitStackProjector.project(diagnostic.callStackTree)
            ))
        }

        for diagnostic in payload.hangDiagnostics ?? [] {
            inputs.append(DiagnosticReportInput(
                kind: .appleHang,
                source: .legacyMetricKit,
                incidentStart: payload.timeStampBegin,
                incidentEnd: payload.timeStampEnd,
                affectedRuntime: runtime(for: diagnostic),
                stack: LegacyMetricKitStackProjector.project(diagnostic.callStackTree)
            ))
        }

        for diagnostic in payload.cpuExceptionDiagnostics ?? [] {
            inputs.append(resourceInput(
                kind: .cpuException,
                payload: payload,
                diagnostic: diagnostic,
                stack: diagnostic.callStackTree
            ))
        }

        for diagnostic in payload.diskWriteExceptionDiagnostics ?? [] {
            inputs.append(resourceInput(
                kind: .diskWriteException,
                payload: payload,
                diagnostic: diagnostic,
                stack: diagnostic.callStackTree
            ))
        }

        #if os(iOS)
        if #available(iOS 16.0, *) {
            for diagnostic in payload.appLaunchDiagnostics ?? [] {
                inputs.append(DiagnosticReportInput(
                    kind: .resourceDiagnostic,
                    resourceKind: .appLaunch,
                    source: .legacyMetricKit,
                    incidentStart: payload.timeStampBegin,
                    incidentEnd: payload.timeStampEnd,
                    affectedRuntime: runtime(for: diagnostic),
                    stack: LegacyMetricKitStackProjector.project(diagnostic.callStackTree)
                ))
            }
        }
        #endif

        return inputs
    }

    private static func resourceInput(
        kind: DiagnosticResourceKind,
        payload: MXDiagnosticPayload,
        diagnostic: MXDiagnostic,
        stack: MXCallStackTree
    ) -> DiagnosticReportInput {
        DiagnosticReportInput(
            kind: .resourceDiagnostic,
            resourceKind: kind,
            source: .legacyMetricKit,
            incidentStart: payload.timeStampBegin,
            incidentEnd: payload.timeStampEnd,
            affectedRuntime: runtime(for: diagnostic),
            stack: LegacyMetricKitStackProjector.project(stack)
        )
    }

    private static func runtime(for diagnostic: MXDiagnostic) -> DiagnosticRuntimeInfo {
        DiagnosticRuntimeInfo(
            appVersion: diagnostic.applicationVersion,
            appBuild: diagnostic.metaData.applicationBuildVersion,
            osVersion: diagnostic.metaData.osVersion,
            platform: .current,
            hardwareModel: diagnostic.metaData.deviceType
        )
    }

    private static func boundedInt32(_ value: NSNumber?) -> Int32? {
        guard let value else { return nil }
        let raw = value.int64Value
        guard raw >= Int64(Int32.min), raw <= Int64(Int32.max) else { return nil }
        return Int32(raw)
    }

    private static func boundedUInt64(_ value: NSNumber?) -> UInt64? {
        guard let value, value.int64Value >= 0 else { return nil }
        return value.uint64Value
    }
}

#if os(iOS) || os(macOS)
@available(iOS 27.0, macOS 27.0, *)
enum ModernMetricKitDiagnosticProjector {
    static func input(from report: MetricKit.DiagnosticReport) -> DiagnosticReportInput {
        let runtime = DiagnosticRuntimeInfo(
            appVersion: report.environment.applicationVersion,
            appBuild: report.environment.applicationBuildVersion,
            osVersion: report.environment.osVersion.number,
            platform: .current,
            hardwareModel: report.environment.deviceType
        )

        switch report.result {
        case .crash(let diagnostic):
            return DiagnosticReportInput(
                kind: .appleCrash,
                source: .modernMetricKit,
                incidentStart: report.timeRange.start,
                incidentEnd: report.timeRange.end,
                affectedRuntime: runtime,
                failure: DiagnosticFailure(
                    exceptionType: boundedInt32(diagnostic.exceptionType),
                    exceptionCode: diagnostic.exceptionCode,
                    signal: boundedInt32(diagnostic.signal),
                    terminationCategory: DiagnosticTerminationCategory.fromAppleValue(
                        diagnostic.terminationCategory?.rawValue
                    )
                ),
                stack: project(diagnostic.callStackTree)
            )

        case .hang(let diagnostic):
            return DiagnosticReportInput(
                kind: .appleHang,
                source: .modernMetricKit,
                incidentStart: report.timeRange.start,
                incidentEnd: report.timeRange.end,
                affectedRuntime: runtime,
                stack: project(diagnostic.callStackTree)
            )

        case .cpuException(let diagnostic):
            return resourceInput(
                kind: .cpuException,
                report: report,
                runtime: runtime,
                stack: diagnostic.callStackTree
            )

        case .diskWriteException(let diagnostic):
            return resourceInput(
                kind: .diskWriteException,
                report: report,
                runtime: runtime,
                stack: diagnostic.callStackTree
            )

        case .appLaunch(let diagnostic):
            return resourceInput(
                kind: .appLaunch,
                report: report,
                runtime: runtime,
                stack: diagnostic.callStackTree
            )

        #if os(iOS)
        case .memoryException(let diagnostic):
            return resourceInput(
                kind: .memoryException,
                report: report,
                runtime: runtime,
                stack: diagnostic.callStackTree
            )
        #endif

        @unknown default:
            return DiagnosticReportInput(
                kind: .resourceDiagnostic,
                source: .modernMetricKit,
                incidentStart: report.timeRange.start,
                incidentEnd: report.timeRange.end,
                affectedRuntime: runtime
            )
        }
    }

    private static func resourceInput(
        kind: DiagnosticResourceKind,
        report: MetricKit.DiagnosticReport,
        runtime: DiagnosticRuntimeInfo,
        stack: MetricKit.CallStackTree
    ) -> DiagnosticReportInput {
        DiagnosticReportInput(
            kind: .resourceDiagnostic,
            resourceKind: kind,
            source: .modernMetricKit,
            incidentStart: report.timeRange.start,
            incidentEnd: report.timeRange.end,
            affectedRuntime: runtime,
            stack: project(stack)
        )
    }

    private static func project(_ tree: MetricKit.CallStackTree) -> DiagnosticStack? {
        var threads = [DiagnosticStackThread]()
        var didDropFrame = false

        for thread in tree.callStackThreads.prefix(DiagnosticPolicy.maximumStackThreads) {
            var frames = [DiagnosticStackFrame]()
            for root in thread.rootFrames {
                collect(root, tree: tree, into: &frames)
            }
            if frames.isEmpty {
                didDropFrame = true
            }
            threads.append(DiagnosticStackThread(frames: frames))
        }

        guard !threads.isEmpty else { return nil }
        return DiagnosticStack(threads: threads, truncated: didDropFrame)
    }

    private static func collect(
        _ frame: MetricKit.CallStackFrame,
        tree: MetricKit.CallStackTree,
        into frames: inout [DiagnosticStackFrame]
    ) {
        guard frames.count < DiagnosticPolicy.maximumStackFrames else { return }
        if let uuid = frame.binaryUUID,
           let offset = frame.offsetIntoBinaryTextSegment,
           let binaryName = tree.binaryInfo[uuid]?.name,
           let imageKind = DiagnosticImageAllowlist.kind(for: binaryName, bundle: .main) {
            frames.append(DiagnosticStackFrame(
                imageUUID: uuid,
                offsetIntoBinaryTextSegment: offset,
                imageKind: imageKind
            ))
        }
        for child in frame.subFrames {
            collect(child, tree: tree, into: &frames)
        }
    }

    private static func boundedInt32(_ value: Int?) -> Int32? {
        guard let value, value >= Int(Int32.min), value <= Int(Int32.max) else { return nil }
        return Int32(value)
    }
}

@available(iOS 27.0, macOS 27.0, *)
final class ModernMetricKitStreamAdapter: @unchecked Sendable {
    private let manager: MetricKit.MetricManager
    private var task: Task<Void, Never>?

    init(handler: @escaping @Sendable (MetricKit.DiagnosticReport) -> Void) {
        let manager = MetricKit.MetricManager()
        self.manager = manager
        self.task = Task { [manager, handler] in
            for await report in manager.diagnosticReports {
                handler(report)
            }
        }
    }

    deinit {
        task?.cancel()
    }
}
#endif
