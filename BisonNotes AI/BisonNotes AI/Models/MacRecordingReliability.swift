//
//  MacRecordingReliability.swift
//  BisonNotes AI
//
//  Deterministic state and file-preservation helpers for Mac recording.
//

import Foundation

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
