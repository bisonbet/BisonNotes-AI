//
//  TemporaryFileCleanupService.swift
//  BisonNotes AI
//
//  Conservative cleanup for temporary audio artifacts left behind by failed,
//  cancelled, or killed processing jobs.
//

import Foundation

@MainActor
final class TemporaryFileCleanupService {
    static let shared = TemporaryFileCleanupService()

    private let fileManager = FileManager.default
    private let defaultMaxAge: TimeInterval = 6 * 60 * 60
    /// Floor for the iCloud audio staging directory. See `scheduleAudioStagingCleanup`.
    private static let audioStagingMinimumAge: TimeInterval = 6 * 60 * 60

    private init() {}

    @discardableResult
    func cleanupStaleFiles(maxAge: TimeInterval? = nil) -> (deletedCount: Int, reclaimedBytes: Int64) {
        let cutoff = Date().addingTimeInterval(-(maxAge ?? defaultMaxAge))
        var deletedCount = 0
        var reclaimedBytes: Int64 = 0
        var errors: [String] = []

        for candidate in cleanupCandidates() {
            guard isKnownTemporaryFile(candidate.url),
                  isSafeChild(candidate.url, of: candidate.allowedRoot),
                  isOlderThanCutoff(candidate.url, cutoff: cutoff) else {
                continue
            }

            let size = fileSize(candidate.url)
            do {
                try fileManager.removeItem(at: candidate.url)
                deletedCount += 1
                reclaimedBytes += size
            } catch {
                errors.append("\(candidate.url.lastPathComponent): \(error.localizedDescription)")
            }
        }

        cleanupAudioChunksDirectory(cutoff: cutoff, deletedCount: &deletedCount, reclaimedBytes: &reclaimedBytes, errors: &errors)
        cleanupWebImportsDirectory(
            cutoff: cutoff,
            deletedCount: &deletedCount,
            reclaimedBytes: &reclaimedBytes,
            errors: &errors
        )
        scheduleAudioStagingCleanup(cutoff: cutoff)

        if deletedCount > 0 {
            AppLog.shared.fileManagement("Cleaned up \(deletedCount) stale temporary file(s), reclaimed \(formatBytes(reclaimedBytes))")
        }

        if !errors.isEmpty {
            AppLog.shared.fileManagement("Temporary cleanup skipped \(errors.count) file(s): \(errors.joined(separator: "; "))", level: .error)
        }

        return (deletedCount, reclaimedBytes)
    }

    private struct CleanupCandidate {
        let url: URL
        let allowedRoot: URL
    }

    private func cleanupCandidates() -> [CleanupCandidate] {
        var candidates: [CleanupCandidate] = []

        let tempRoot = fileManager.temporaryDirectory
        candidates.append(contentsOf: directChildren(of: tempRoot).map {
            CleanupCandidate(url: $0, allowedRoot: tempRoot)
        })

        if let documentsRoot = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first {
            candidates.append(contentsOf: directChildren(of: documentsRoot).map {
                CleanupCandidate(url: $0, allowedRoot: documentsRoot)
            })
        }

        return candidates
    }

    private func cleanupAudioChunksDirectory(cutoff: Date,
                                             deletedCount: inout Int,
                                             reclaimedBytes: inout Int64,
                                             errors: inout [String]) {
        let chunksRoot = fileManager.temporaryDirectory.appendingPathComponent("AudioChunks", isDirectory: true)
        guard isSafeChild(chunksRoot, of: fileManager.temporaryDirectory),
              let contents = try? fileManager.contentsOfDirectory(
                at: chunksRoot,
                includingPropertiesForKeys: [.contentModificationDateKey, .creationDateKey, .fileSizeKey, .isRegularFileKey],
                options: [.skipsHiddenFiles]
              ) else {
            return
        }

        for url in contents where isKnownAudioChunkFile(url) && isOlderThanCutoff(url, cutoff: cutoff) {
            let size = fileSize(url)
            do {
                try fileManager.removeItem(at: url)
                deletedCount += 1
                reclaimedBytes += size
            } catch {
                errors.append("\(url.lastPathComponent): \(error.localizedDescription)")
            }
        }

        removeDirectoryIfEmpty(chunksRoot)
    }

    private func cleanupWebImportsDirectory(
        cutoff: Date,
        deletedCount: inout Int,
        reclaimedBytes: inout Int64,
        errors: inout [String]
    ) {
        let importsRoot = fileManager.temporaryDirectory
            .appendingPathComponent("BisonNotesWebImports", isDirectory: true)
        guard isSafeChild(importsRoot, of: fileManager.temporaryDirectory) else { return }

        for url in directChildren(of: importsRoot) where isOlderThanCutoff(url, cutoff: cutoff) {
            let size = fileSize(url)
            do {
                try fileManager.removeItem(at: url)
                deletedCount += 1
                reclaimedBytes += size
            } catch {
                errors.append("\(url.lastPathComponent): \(error.localizedDescription)")
            }
        }

        removeDirectoryIfEmpty(importsRoot)
    }

    /// `TemporaryDirectoryAssetStaging` removes its own run directory from a `defer`,
    /// but a crash or a kill mid-upload leaves a full copy of every staged recording
    /// behind — the staging copies are the recordings themselves, so a single orphaned
    /// run can be gigabytes.
    ///
    /// That size is why this one runs off the main actor while the rest of this
    /// service stays inline: `cleanupStaleFiles()` is called straight from the launch
    /// and activation handlers, and measuring then recursively deleting gigabytes
    /// there would block the UI for the whole traversal. Its totals are logged when
    /// it finishes rather than folded into this call's return value.
    private func scheduleAudioStagingCleanup(cutoff: Date) {
        // A run directory's timestamp only moves when the run stages another file, so
        // a sync that is slow between files must not look abandoned. This keeps its
        // own floor rather than trusting the caller's `maxAge`, which is 30 minutes
        // on the background-processing path.
        let stagingCutoff = min(cutoff, Date().addingTimeInterval(-Self.audioStagingMinimumAge))
        Task.detached(priority: .utility) {
            let sweep = AudioStagingCleanupSweep()
            // A backup stages every changed recording before its first upload
            // batch goes out, so a large library on a slow connection can hold a
            // run directory open for longer than the minimum age. Deleting it
            // then takes the files the remaining batches still need. Read
            // immediately before each removal, as the cache sweeps do.
            let result = await sweep.run(cutoff: stagingCutoff) {
                await MainActor.run {
                    SummaryManager.shared.getiCloudManager().operationCoordinator.isRunning
                }
            }

            if result.deletedCount > 0 {
                AppLog.shared.fileManagement(
                    "Cleaned up \(result.deletedCount) orphaned iCloud audio staging run(s), "
                    + "reclaimed \(ByteCountFormatter.string(fromByteCount: result.reclaimedBytes, countStyle: .file))"
                )
            }
            if !result.errors.isEmpty {
                AppLog.shared.fileManagement(
                    "Staging cleanup skipped \(result.errors.count) run(s): \(result.errors.joined(separator: "; "))",
                    level: .error
                )
            }
        }
    }

    private func directChildren(of directory: URL) -> [URL] {
        (try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey, .creationDateKey, .fileSizeKey, .isRegularFileKey],
            options: [.skipsHiddenFiles]
        )) ?? []
    }

    private func isKnownTemporaryFile(_ url: URL) -> Bool {
        let name = url.lastPathComponent
        let ext = url.pathExtension.lowercased()

        if name.hasPrefix("fluidaudio_input_") && ext == "caf" { return true }
        // Mac scratch recordings (raw PCM) staged in temp during native macOS capture.
        // Normally removed on finalize/retry, but a crash or kill mid-capture orphans
        // large .caf files named after the final recording, e.g.
        // apprecording-<ts>-<uuid>.caf and apprecording-<ts>-<uuid>-input-<N>.caf.
        // The age gate protects an in-progress recording's live scratch file.
        if name.hasPrefix("apprecording-") && ext == "caf" { return true }
        if name.hasPrefix("cleaned_") && ext == "m4a" { return true }
        if name.hasPrefix("mac_export_") && ext == "m4a" { return true }
        if name.hasPrefix("mac_segments_") && ext == "m4a" { return true }
        if name.hasPrefix("mac_meeting_mix_") && ext == "m4a" { return true }
        // Retain legacy prefixes so upgrades clean temporary files left by Catalyst builds.
        if name.hasPrefix("catalyst_export_") && ext == "m4a" { return true }
        if name.hasPrefix("catalyst_mic_export_") && ext == "m4a" { return true }
        if name.hasPrefix("catalyst_meeting_mix_") && ext == "m4a" { return true }
        if name.hasSuffix("-system.m4a") { return true }
        if name.hasPrefix("temp_merge_") && ext == "m4a" { return true }
        // Diagnostic exports are written for the share sheet and are multi-megabyte.
        // `LogExporter` clears the previous ones each time it exports; this catches
        // the ones a crash or a dismissed share sheet left behind.
        if LogExporter.isExportFileName(name) { return true }

        return false
    }

    private func isKnownAudioChunkFile(_ url: URL) -> Bool {
        url.lastPathComponent.hasPrefix("chunk_") && url.pathExtension.lowercased() == "m4a"
    }

    private func isOlderThanCutoff(_ url: URL, cutoff: Date) -> Bool {
        guard isRegularFile(url),
              let ageDate = modificationOrCreationDate(url) else {
            return false
        }

        return ageDate < cutoff
    }

    private func isRegularFile(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
    }

    private func modificationOrCreationDate(_ url: URL) -> Date? {
        let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .creationDateKey])
        return values?.contentModificationDate ?? values?.creationDate
    }

    private func fileSize(_ url: URL) -> Int64 {
        let values = try? url.resourceValues(forKeys: [.fileSizeKey])
        return Int64(values?.fileSize ?? 0)
    }

    private func isSafeChild(_ url: URL, of root: URL) -> Bool {
        let childPath = url.standardizedFileURL.path
        let rootPath = root.standardizedFileURL.path
        return childPath == rootPath || childPath.hasPrefix(rootPath + "/")
    }

    private func removeDirectoryIfEmpty(_ directory: URL) {
        guard let contents = try? fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil),
              contents.isEmpty else {
            return
        }

        try? fileManager.removeItem(at: directory)
    }

    private func formatBytes(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}

// MARK: - Audio Staging Sweep

/// Removes iCloud audio staging runs that a crash or kill orphaned.
///
/// Deliberately not main-actor isolated: an orphaned run holds a full copy of
/// every recording it staged, so measuring and deleting one can take long enough
/// to be visible in the UI. Constructed inside the detached task, so nothing
/// non-`Sendable` crosses an isolation boundary.
struct AudioStagingCleanupSweep {

    struct Result {
        var deletedCount = 0
        var reclaimedBytes: Int64 = 0
        var errors: [String] = []
    }

    private let fileManager = FileManager()

    /// - Parameter isCloudSyncActive: consulted again before every removal, so a
    ///   backup that starts mid-sweep keeps the run directory it is uploading from.
    func run(
        cutoff: Date,
        isCloudSyncActive: @Sendable () async -> Bool
    ) async -> Result {
        var result = Result()
        let tempRoot = fileManager.temporaryDirectory
        let stagingRoot = tempRoot.appendingPathComponent("iCloudAudioStaging", isDirectory: true)
        guard isSafeChild(stagingRoot, of: tempRoot) else { return result }

        for runDirectory in directChildren(of: stagingRoot) {
            guard isDirectory(runDirectory),
                  let ageDate = modificationOrCreationDate(runDirectory),
                  ageDate < cutoff else {
                continue
            }

            if await isCloudSyncActive() { return result }

            let size = directorySize(runDirectory)
            do {
                try fileManager.removeItem(at: runDirectory)
                result.deletedCount += 1
                result.reclaimedBytes += size
            } catch {
                result.errors.append("\(runDirectory.lastPathComponent): \(error.localizedDescription)")
            }
        }

        removeDirectoryIfEmpty(stagingRoot)
        return result
    }

    private func directChildren(of directory: URL) -> [URL] {
        (try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isDirectoryKey, .contentModificationDateKey, .creationDateKey],
            options: [.skipsHiddenFiles]
        )) ?? []
    }

    private func isDirectory(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
    }

    private func isRegularFile(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
    }

    private func modificationOrCreationDate(_ url: URL) -> Date? {
        let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .creationDateKey])
        return values?.contentModificationDate ?? values?.creationDate
    }

    private func directorySize(_ directory: URL) -> Int64 {
        guard let enumerator = fileManager.enumerator(
            at: directory,
            includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey]
        ) else { return 0 }

        var total: Int64 = 0
        for case let url as URL in enumerator where isRegularFile(url) {
            total += Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        }
        return total
    }

    private func isSafeChild(_ url: URL, of root: URL) -> Bool {
        let childPath = url.standardizedFileURL.path
        let rootPath = root.standardizedFileURL.path
        return childPath == rootPath || childPath.hasPrefix(rootPath + "/")
    }

    private func removeDirectoryIfEmpty(_ directory: URL) {
        guard let contents = try? fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil),
              contents.isEmpty else {
            return
        }
        try? fileManager.removeItem(at: directory)
    }
}
