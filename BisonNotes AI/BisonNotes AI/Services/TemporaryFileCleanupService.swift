//
//  TemporaryFileCleanupService.swift
//  BisonNotes AI
//
//  Conservative cleanup for temporary audio artifacts left behind by failed,
//  cancelled, or killed processing jobs.
//

import Foundation

final class TemporaryFileCleanupService {
    static let shared = TemporaryFileCleanupService()

    private let fileManager = FileManager.default
    private let defaultMaxAge: TimeInterval = 6 * 60 * 60

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
        if name.hasPrefix("cleaned_") && ext == "m4a" { return true }
        if name.hasPrefix("catalyst_export_") && ext == "m4a" { return true }
        if name.hasPrefix("catalyst_mic_export_") && ext == "m4a" { return true }
        if name.hasPrefix("catalyst_meeting_mix_") && ext == "m4a" { return true }
        if name.hasSuffix("-system.m4a") { return true }
        if name.hasPrefix("temp_merge_") && ext == "m4a" { return true }

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
