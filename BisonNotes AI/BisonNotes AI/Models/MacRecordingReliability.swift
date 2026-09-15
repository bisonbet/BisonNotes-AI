//
//  MacRecordingReliability.swift
//  BisonNotes AI
//
//  Deterministic state and file-preservation helpers for Mac recording.
//

import Foundation

/// The small, platform-neutral part of native Mac microphone selection.
///
/// Core Audio device IDs are UInt32 values on macOS, but keeping this ordering
/// helper independent of CoreAudio lets the fallback policy be covered by the
/// regular cross-platform reliability tests.
struct MacRecordingInputCandidate: Equatable, Sendable {
    let deviceID: UInt32
    let name: String
}

/// Why a microphone recovery attempt is starting.
///
/// The distinction matters because the exclusion below is a hard filter
/// (`recordingInputCandidates(excluding:)` drops the device outright rather than
/// deprioritizing it), so a device left out is not tried at all.
enum MacInputRecoveryTrigger: Equatable, Sendable {
    /// The bound input stopped producing audio, or stopped resolving.
    case currentInputFailed
    /// A device became available while the recording was waiting for one.
    case deviceBecameAvailable
}

enum MacRecordingInputSelection {
    /// The input the next recovery attempt must skip, if any.
    ///
    /// Core Audio can hand a reconnected microphone the same device ID it had
    /// before, so the ID the recording was last bound to is only evidence of a bad
    /// device while that device is the one that just failed. On a reconnection it
    /// is just as likely to be the device the user plugged back in.
    ///
    /// Carrying the exclusion into a reconnection is what left a recording stuck:
    /// the failure path never clears `macInputDeviceID`, so a mic that came back
    /// with its old ID was filtered out of its own recovery, and with no other
    /// input present the recording stayed in `waitingForMicrophone` for good.
    static func excludedDeviceID(
        currentInputDeviceID: UInt32?,
        trigger: MacInputRecoveryTrigger
    ) -> UInt32? {
        switch trigger {
        case .currentInputFailed:
            return currentInputDeviceID
        case .deviceBecameAvailable:
            return nil
        }
    }

    /// Orders startup candidates without changing the user's persisted choice:
    /// use that choice first, then the current system default, then other
    /// available inputs. Virtual meeting bridges are tried before unrelated
    /// secondary devices once the preferred/default routes have failed.
    static func orderedDeviceIDs(
        preferredDeviceID: UInt32?,
        defaultDeviceID: UInt32?,
        available: [MacRecordingInputCandidate]
    ) -> [UInt32] {
        let uniqueAvailable = uniqueCandidates(available)
        let availableIDs = Set(uniqueAvailable.map(\.deviceID))
        var orderedIDs: [UInt32] = []

        func appendIfAvailable(_ deviceID: UInt32?) {
            guard let deviceID,
                  availableIDs.contains(deviceID),
                  !orderedIDs.contains(deviceID) else { return }
            orderedIDs.append(deviceID)
        }

        appendIfAvailable(preferredDeviceID)
        appendIfAvailable(defaultDeviceID)

        for candidate in uniqueAvailable.sorted(by: isPreferredFallbackOrder) {
            appendIfAvailable(candidate.deviceID)
        }

        // A default Core Audio input can briefly be absent from AVCapture's
        // discovery list while a virtual driver is being registered. It is
        // still a valid input candidate, so keep it in the returned order.
        if let defaultDeviceID, !orderedIDs.contains(defaultDeviceID) {
            let preferredIsAvailable = preferredDeviceID.map(availableIDs.contains) ?? false
            orderedIDs.insert(defaultDeviceID, at: preferredIsAvailable ? min(1, orderedIDs.count) : 0)
        }

        return orderedIDs
    }

    private static func uniqueCandidates(
        _ candidates: [MacRecordingInputCandidate]
    ) -> [MacRecordingInputCandidate] {
        var seen = Set<UInt32>()
        return candidates.filter { seen.insert($0.deviceID).inserted }
    }

    private static func isPreferredFallbackOrder(
        _ lhs: MacRecordingInputCandidate,
        _ rhs: MacRecordingInputCandidate
    ) -> Bool {
        let lhsBridge = isMeetingAudioBridge(lhs.name)
        let rhsBridge = isMeetingAudioBridge(rhs.name)
        if lhsBridge != rhsBridge {
            return lhsBridge
        }
        return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
    }

    private static func isMeetingAudioBridge(_ name: String) -> Bool {
        let normalizedName = name.lowercased()
        return [
            "zoom",
            "teams",
            "virtual",
            "blackhole",
            "loopback",
            "soundflower",
            "aggregate"
        ].contains(where: { normalizedName.contains($0) })
    }
}

/// The two formats `AVAudioEngine` reports for its input node.
///
/// `inputFormat(forBus:)` describes the hardware the AUHAL is bound to;
/// `outputFormat(forBus:)` describes what the node will hand a tap.
struct MacInputFormatSnapshot: Equatable, Sendable {
    let hardwareSampleRate: Double
    let hardwareChannelCount: UInt32
    let nodeSampleRate: Double
    let nodeChannelCount: UInt32
}

enum MacInputTapFormatReadiness: Equatable, Sendable {
    /// Either format is missing, so no microphone input is enabled at all.
    case unavailable
    /// The node's output format can be tapped.
    case usable
    /// The node is bound to hardware running at a different rate, and will
    /// deliver nothing.
    case sampleRateMismatch
}

/// Decides whether `AVAudioEngine`'s input node can actually be tapped.
///
/// Setting `kAudioOutputUnitProperty_CurrentDevice` rebinds the AUHAL, but the
/// node keeps reporting a 48 kHz output format regardless of the device it was
/// just bound to. Tapping a node whose hardware runs at another rate produces a
/// tap that never fires: the segment records zero frames until the capture
/// watchdog tears it down five seconds later, which cost the head of every
/// recording on a device that did not already run at 48 kHz.
///
/// Measured against real inputs, and both halves of this are load-bearing:
///
/// - **Rate disagreement is fatal and cannot be worked around.** A 16 kHz device
///   bound to a 48 kHz node delivers zero frames when tapped with the node
///   format *and* when tapped with the hardware format, and fails `start()`
///   outright with `kAudioUnitErr_FormatNotSupported` when tapped with `nil`.
///   There is no format to choose; the device is simply uncapturable while the
///   rates disagree, so the only useful answer is to reject it immediately and
///   let the caller's fallback try the next input.
/// - **Channel disagreement is normal and must be ignored.** The built-in
///   MacBook microphone reports 1 hardware channel against the node's 2, as does
///   an iPhone Continuity microphone, and both capture perfectly. Rejecting on
///   channel count would refuse the most common input on a Mac.
///
/// Nothing here is worth waiting for: the node does not reconcile on a timer or
/// on `prepare()`, so this is a single synchronous decision, never a poll.
enum MacInputTapFormatPolicy {
    /// Sample rates are reported as doubles, so compare them with a tolerance
    /// rather than exactly. Nothing in Core Audio distinguishes rates this close.
    static let sampleRateTolerance: Double = 0.5

    static func readiness(for snapshot: MacInputFormatSnapshot) -> MacInputTapFormatReadiness {
        guard snapshot.hardwareSampleRate > 0, snapshot.hardwareChannelCount > 0,
              snapshot.nodeSampleRate > 0, snapshot.nodeChannelCount > 0 else {
            return .unavailable
        }
        guard abs(snapshot.hardwareSampleRate - snapshot.nodeSampleRate) <= sampleRateTolerance else {
            return .sampleRateMismatch
        }
        return .usable
    }

    /// Describes a rejected input for the error the start throws. Naming both
    /// rates is what makes the failure diagnosable from a log.
    static func mismatchDescription(for snapshot: MacInputFormatSnapshot) -> String {
        "The microphone runs at \(snapshot.hardwareSampleRate) Hz but the audio engine " +
        "is bound at \(snapshot.nodeSampleRate) Hz, so it would capture nothing."
    }
}

struct RecordingCaptureHealthSnapshot: Equatable, Sendable {
    let monitoringStartedAt: Date?
    let firstWriteAt: Date?
    let lastWriteAt: Date?
    let lastWriteFailureAt: Date?
    let lastWriteError: String?
    let segmentFramesWritten: Int64
    let totalFramesWritten: Int64
}

enum RecordingCaptureHealthAssessment: Equatable, Sendable {
    case inactive
    case starting
    case healthy
    case noInitialAudio
    case stalled
    case writeFailed(String)
}

/// Thread-safe because AVAudioEngine updates it from its real-time tap while the
/// main actor reads it from the health watchdog.
final class RecordingCaptureHealth: @unchecked Sendable {
    private let lock = NSLock()
    private var monitoringStartedAt: Date?
    private var firstWriteAt: Date?
    private var lastWriteAt: Date?
    private var lastWriteFailureAt: Date?
    private var lastWriteError: String?
    private var segmentFramesWritten: Int64 = 0
    private var totalFramesWritten: Int64 = 0

    func resetSession(at date: Date = Date()) {
        lock.withLock {
            monitoringStartedAt = date
            firstWriteAt = nil
            lastWriteAt = nil
            lastWriteFailureAt = nil
            lastWriteError = nil
            segmentFramesWritten = 0
            totalFramesWritten = 0
        }
    }

    func beginSegment(at date: Date = Date()) {
        lock.withLock {
            monitoringStartedAt = date
            firstWriteAt = nil
            lastWriteAt = nil
            lastWriteFailureAt = nil
            lastWriteError = nil
            segmentFramesWritten = 0
        }
    }

    func suspend() {
        lock.withLock {
            monitoringStartedAt = nil
            firstWriteAt = nil
            lastWriteAt = nil
            lastWriteFailureAt = nil
            lastWriteError = nil
            segmentFramesWritten = 0
        }
    }

    /// Returns true only for the first successful write in the current segment.
    @discardableResult
    func recordSuccessfulWrite(frameCount: Int64, at date: Date = Date()) -> Bool {
        guard frameCount > 0 else { return false }
        return lock.withLock {
            let isFirstWrite = firstWriteAt == nil
            if isFirstWrite {
                firstWriteAt = date
            }
            lastWriteAt = date
            lastWriteFailureAt = nil
            lastWriteError = nil
            segmentFramesWritten += frameCount
            totalFramesWritten += frameCount
            return isFirstWrite
        }
    }

    /// Returns true only for the first failure after a successful write or segment start.
    @discardableResult
    func recordWriteFailure(_ description: String, at date: Date = Date()) -> Bool {
        lock.withLock {
            let shouldLog = lastWriteFailureAt == nil
            lastWriteFailureAt = date
            lastWriteError = description
            return shouldLog
        }
    }

    func snapshot() -> RecordingCaptureHealthSnapshot {
        lock.withLock {
            RecordingCaptureHealthSnapshot(
                monitoringStartedAt: monitoringStartedAt,
                firstWriteAt: firstWriteAt,
                lastWriteAt: lastWriteAt,
                lastWriteFailureAt: lastWriteFailureAt,
                lastWriteError: lastWriteError,
                segmentFramesWritten: segmentFramesWritten,
                totalFramesWritten: totalFramesWritten
            )
        }
    }

    func assessment(
        at date: Date = Date(),
        firstBufferTimeout: TimeInterval,
        stallTimeout: TimeInterval
    ) -> RecordingCaptureHealthAssessment {
        let state = snapshot()
        guard let monitoringStartedAt = state.monitoringStartedAt else {
            return .inactive
        }
        if let error = state.lastWriteError,
           let failureAt = state.lastWriteFailureAt,
           state.lastWriteAt == nil || failureAt >= state.lastWriteAt ?? .distantPast {
            return .writeFailed(error)
        }
        guard let firstWriteAt = state.firstWriteAt else {
            return date.timeIntervalSince(monitoringStartedAt) >= firstBufferTimeout
                ? .noInitialAudio
                : .starting
        }
        let lastWriteAt = state.lastWriteAt ?? firstWriteAt
        return date.timeIntervalSince(lastWriteAt) >= stallTimeout ? .stalled : .healthy
    }
}

enum MacRecordingFinalizationPlan: Equatable, Sendable {
    case mixMicrophoneAndSystem
    case microphoneOnly
    case systemOnly
    case unavailable

    static func choose(hasMicrophoneAudio: Bool, hasSystemAudio: Bool) -> Self {
        switch (hasMicrophoneAudio, hasSystemAudio) {
        case (true, true):
            return .mixMicrophoneAndSystem
        case (true, false):
            return .microphoneOnly
        case (false, true):
            return .systemOnly
        case (false, false):
            return .unavailable
        }
    }
}

struct RecordingRecoveryResult: Equatable, Sendable {
    let directoryURL: URL
    let preservedFileURLs: [URL]
}

enum RecordingRecoveryStore {
    static func preserve(
        files: [URL],
        intendedFinalURL: URL,
        reason: String,
        rootDirectory: URL? = nil,
        now: Date = Date(),
        fileManager: FileManager = .default
    ) throws -> RecordingRecoveryResult {
        let root = try rootDirectory ?? defaultRootDirectory(fileManager: fileManager)
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let recordingName = intendedFinalURL.deletingPathExtension().lastPathComponent
        let directoryURL = root.appendingPathComponent(
            "\(recordingName)-\(formatter.string(from: now))-\(UUID().uuidString.prefix(8))",
            isDirectory: true
        )
        try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)

        var preservedURLs: [URL] = []
        for sourceURL in files where fileManager.fileExists(atPath: sourceURL.path) {
            let destinationURL = uniqueDestination(
                for: sourceURL.lastPathComponent,
                in: directoryURL,
                fileManager: fileManager
            )
            do {
                try fileManager.moveItem(at: sourceURL, to: destinationURL)
            } catch {
                try fileManager.copyItem(at: sourceURL, to: destinationURL)
            }
            preservedURLs.append(destinationURL)
        }

        let manifest = """
        BisonNotes recording recovery
        Intended recording: \(intendedFinalURL.lastPathComponent)
        Preserved: \(ISO8601DateFormatter().string(from: now))
        Reason: \(reason)
        Files: \(preservedURLs.map(\.lastPathComponent).joined(separator: ", "))
        """
        let manifestURL = directoryURL.appendingPathComponent("Recovery Info.txt")
        try Data(manifest.utf8).write(to: manifestURL, options: .atomic)

        return RecordingRecoveryResult(
            directoryURL: directoryURL,
            preservedFileURLs: preservedURLs
        )
    }

    static func diagnosticInventory(
        rootDirectory: URL? = nil,
        fileManager: FileManager = .default
    ) -> String {
        let root: URL
        do {
            root = try rootDirectory ?? defaultRootDirectory(fileManager: fileManager)
        } catch {
            return "Recovery inventory unavailable: \(error.localizedDescription)"
        }
        guard fileManager.fileExists(atPath: root.path) else {
            return "No recording recovery sessions."
        }

        let keys: Set<URLResourceKey> = [.isDirectoryKey, .contentModificationDateKey]
        let sessions = (try? fileManager.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: Array(keys),
            options: [.skipsHiddenFiles]
        )) ?? []
        let directories = sessions.filter {
            (try? $0.resourceValues(forKeys: keys).isDirectory) == true
        }.sorted {
            let left = try? $0.resourceValues(forKeys: keys).contentModificationDate
            let right = try? $1.resourceValues(forKeys: keys).contentModificationDate
            return (left ?? .distantPast) > (right ?? .distantPast)
        }
        guard !directories.isEmpty else { return "No recording recovery sessions." }

        var lines = ["Recording recovery sessions: \(directories.count)"]
        for directory in directories.prefix(10) {
            let files = (try? fileManager.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: [.fileSizeKey],
                options: [.skipsHiddenFiles]
            )) ?? []
            let totalBytes = files.reduce(Int64(0)) { partialResult, fileURL in
                let size = try? fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize
                return partialResult + Int64(size ?? 0)
            }
            lines.append("- \(directory.lastPathComponent): \(files.count) files, \(totalBytes) bytes")
        }
        if directories.count > 10 {
            lines.append("- \(directories.count - 10) older sessions omitted")
        }
        return lines.joined(separator: "\n")
    }

    private static func defaultRootDirectory(fileManager: FileManager) throws -> URL {
        guard let applicationSupport = fileManager.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first else {
            throw CocoaError(.fileNoSuchFile)
        }
        return applicationSupport.appendingPathComponent("Recording Recovery", isDirectory: true)
    }

    private static func uniqueDestination(
        for filename: String,
        in directoryURL: URL,
        fileManager: FileManager
    ) -> URL {
        let requestedURL = directoryURL.appendingPathComponent(filename)
        guard fileManager.fileExists(atPath: requestedURL.path) else { return requestedURL }

        let sourceURL = URL(fileURLWithPath: filename)
        let base = sourceURL.deletingPathExtension().lastPathComponent
        let pathExtension = sourceURL.pathExtension
        var index = 2
        while true {
            var candidateURL = directoryURL.appendingPathComponent("\(base)-\(index)")
            if !pathExtension.isEmpty {
                candidateURL.appendPathExtension(pathExtension)
            }
            if !fileManager.fileExists(atPath: candidateURL.path) {
                return candidateURL
            }
            index += 1
        }
    }
}
