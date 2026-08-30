//
//  CacheMaintenanceTests.swift
//  BisonNotes AITests
//
//  Covers the rules that bound the two caches which grew to 29 GB on macOS:
//  the Hugging Face blob cache behind MLX model downloads, and the persisted
//  log files. See `CacheMaintenanceService` and `LogTrimPolicy`.
//

import XCTest
@testable import BisonNotes_AI

final class CacheMaintenanceTests: XCTestCase {

    // MARK: - Hub repository directory naming

    func testHubRepoDirectoryNameMatchesHuggingFaceLayout() {
        XCTAssertEqual(
            CacheMaintenancePolicy.hubRepoDirectoryName(forModelID: "prism-ml/Ternary-Bonsai-27B-mlx-2bit"),
            "models--prism-ml--Ternary-Bonsai-27B-mlx-2bit"
        )
    }

    func testModelIDRoundTripsThroughDirectoryName() {
        let modelID = "mlx-community/Qwen3-4B-4bit"
        let directory = CacheMaintenancePolicy.hubRepoDirectoryName(forModelID: modelID)
        XCTAssertEqual(CacheMaintenancePolicy.modelID(forHubRepoDirectoryName: directory), modelID)
    }

    /// A repository name may itself contain `--`; only the first separator after
    /// the prefix divides namespace from name.
    func testModelIDKeepsDoubleDashesInsideRepositoryName() {
        XCTAssertEqual(
            CacheMaintenancePolicy.modelID(forHubRepoDirectoryName: "models--org--name--with--dashes"),
            "org/name--with--dashes"
        )
    }

    func testModelIDRejectsNonModelDirectories() {
        XCTAssertNil(CacheMaintenancePolicy.modelID(forHubRepoDirectoryName: ".metadata"))
        XCTAssertNil(CacheMaintenancePolicy.modelID(forHubRepoDirectoryName: "datasets--org--name"))
        XCTAssertNil(CacheMaintenancePolicy.modelID(forHubRepoDirectoryName: "models--org"))
        XCTAssertNil(CacheMaintenancePolicy.modelID(forHubRepoDirectoryName: "models----name"))
        XCTAssertNil(CacheMaintenancePolicy.modelID(forHubRepoDirectoryName: "random-file.txt"))
    }

    // MARK: - What may be pruned from the blob cache

    /// The blobs of an installed model are a byte-for-byte second copy: the app
    /// resolves models out of `downloadBase` and never reads the blob cache.
    func testInstalledModelBlobsArePrunedAsDuplicates() {
        XCTAssertEqual(
            CacheMaintenancePolicy.hubPruneReason(
                directoryName: "models--org--installed",
                installedModelIDs: ["org/installed"],
                isDownloadInFlight: false
            ),
            .duplicateOfInstalledModel
        )
    }

    /// Blobs no installed model claims are what a "delete" in Settings used to
    /// leave behind — 3.3 GB of them on the machine that prompted this.
    func testUnclaimedBlobsArePrunedAsOrphans() {
        XCTAssertEqual(
            CacheMaintenancePolicy.hubPruneReason(
                directoryName: "models--org--deleted",
                installedModelIDs: ["org/installed"],
                isDownloadInFlight: false
            ),
            .orphaned
        )
    }

    /// The blob cache is also the resume state for an interrupted download, so a
    /// sweep must never run while one is in flight.
    func testNothingIsPrunedWhileADownloadIsInFlight() {
        XCTAssertNil(
            CacheMaintenancePolicy.hubPruneReason(
                directoryName: "models--org--installed",
                installedModelIDs: ["org/installed"],
                isDownloadInFlight: true
            )
        )
        XCTAssertNil(
            CacheMaintenancePolicy.hubPruneReason(
                directoryName: "models--org--deleted",
                installedModelIDs: [],
                isDownloadInFlight: true
            )
        )
    }

    func testNonModelDirectoriesAreNeverPruned() {
        XCTAssertNil(
            CacheMaintenancePolicy.hubPruneReason(
                directoryName: ".metadata",
                installedModelIDs: [],
                isDownloadInFlight: false
            )
        )
    }

    // MARK: - CloudKit asset cache budget

    private func entry(_ id: String, ageHours: Double, megabytes: Int64) -> CacheMaintenancePolicy.AssetEntry {
        CacheMaintenancePolicy.AssetEntry(
            identifier: id,
            byteCount: megabytes * 1024 * 1024,
            modifiedAt: Date().addingTimeInterval(-ageHours * 3600)
        )
    }

    /// Nothing younger than the minimum age is touched, whatever the cache weighs:
    /// that gate is what stands in for an in-flight check.
    func testAssetsInsideTheMinimumAgeAreNeverPruned() {
        let entries = (0..<10).map { entry("recent-\($0)", ageHours: 0.1, megabytes: 1_000) }
        let doomed = CacheMaintenancePolicy.assetsToPrune(entries, now: Date())
        XCTAssertTrue(doomed.isEmpty)
    }

    /// The defect this bounds: the cache was seen growing from 9.8 GB to 32 GB in
    /// about an hour, so age alone does not hold it down — the budget does.
    func testCacheOverBudgetIsPrunedOldestFirstUntilUnderBudget() {
        // 6 GB eligible, well inside the maximum age, against a 2 GB budget.
        let entries = (0..<6).map { entry("asset-\($0)", ageHours: Double(12 - $0), megabytes: 1_024) }
        let doomed = CacheMaintenancePolicy.assetsToPrune(entries, now: Date())

        XCTAssertEqual(doomed.count, 4, "should stop as soon as the cache is under budget")
        XCTAssertEqual(doomed.map(\.identifier), ["asset-0", "asset-1", "asset-2", "asset-3"])
    }

    func testCacheUnderBudgetAndInsideMaximumAgeIsLeftAlone() {
        let entries = [entry("a", ageHours: 5, megabytes: 100), entry("b", ageHours: 3, megabytes: 100)]
        XCTAssertTrue(CacheMaintenancePolicy.assetsToPrune(entries, now: Date()).isEmpty)
    }

    /// Past the maximum age an asset goes even when the cache is tiny.
    func testAssetsPastTheMaximumAgeArePrunedRegardlessOfBudget() {
        let entries = [entry("stale", ageHours: 48, megabytes: 1), entry("fresh", ageHours: 2, megabytes: 1)]
        let doomed = CacheMaintenancePolicy.assetsToPrune(entries, now: Date())
        XCTAssertEqual(doomed.map(\.identifier), ["stale"])
    }

    /// An unknown age must not be read as "old enough to delete".
    func testAssetWithNoTimestampIsKeptEvenOverBudget() {
        let entries = [
            CacheMaintenancePolicy.AssetEntry(identifier: "unknown", byteCount: 8 * 1024 * 1024 * 1024, modifiedAt: nil)
        ]
        XCTAssertTrue(CacheMaintenancePolicy.assetsToPrune(entries, now: Date()).isEmpty)
    }

    // MARK: - Persisted log budgets

    /// The defect: 476 lines held 4.1 MB because one line was 354 KB.
    func testOneHugeLineIsClampedToItsByteBudget() {
        let line = String(repeating: "x", count: 400_000)
        let clamped = LogTrimPolicy.clamp(line, maxBytes: 8 * 1024)
        XCTAssertLessThanOrEqual(clamped.utf8.count, 8 * 1024)
        XCTAssertTrue(clamped.hasSuffix("…[truncated]"))
    }

    func testShortLineIsLeftAlone() {
        XCTAssertEqual(LogTrimPolicy.clamp("a short line", maxBytes: 8 * 1024), "a short line")
    }

    /// Clamping counts UTF-8 bytes, not characters, and must not split one.
    func testClampNeverSplitsAMultiByteCharacter() {
        let line = String(repeating: "é", count: 500)
        let clamped = LogTrimPolicy.clamp(line, maxBytes: 64)
        XCTAssertLessThanOrEqual(clamped.utf8.count, 64)
        XCTAssertNotNil(clamped.range(of: "…[truncated]"))
    }

    /// A persisted line must stay on one line, or the line-count cap means nothing.
    func testClampFlattensEmbeddedNewlines() {
        let clamped = LogTrimPolicy.clamp("first\nsecond", maxBytes: 1024)
        XCTAssertFalse(clamped.contains("\n"))
    }

    func testTrimDropsOldestLinesPastTheLineCount() {
        let lines = (1...10).map { "line \($0)" }
        let kept = LogTrimPolicy.trim(lines: lines, maxLines: 3, maxBytes: .max)
        XCTAssertEqual(kept, ["line 8", "line 9", "line 10"])
    }

    func testTrimDropsOldestLinesPastTheByteBudget() {
        let lines = (1...10).map { _ in String(repeating: "x", count: 100) }
        let kept = LogTrimPolicy.trim(lines: lines, maxLines: .max, maxBytes: 350)
        XCTAssertEqual(kept.count, 3)
    }

    /// Even a line that alone exceeds the budget is kept, so logging is never a no-op.
    func testTrimAlwaysKeepsTheNewestLine() {
        let kept = LogTrimPolicy.trim(
            lines: ["old", String(repeating: "x", count: 5_000)],
            maxLines: .max,
            maxBytes: 100
        )
        XCTAssertEqual(kept.count, 1)
        XCTAssertEqual(kept.first?.count, 5_000)
    }

    func testTrimLeavesAnUnderBudgetLogAlone() {
        let lines = ["a", "b", "c"]
        XCTAssertEqual(LogTrimPolicy.trim(lines: lines, maxLines: 100, maxBytes: 10_000), lines)
    }

    // MARK: - Rolling log file, against real files

    private func makeTempLogURL() -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("LogFileTests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return dir.appendingPathComponent("log.txt")
    }

    /// The regression that motivated splitting `PersistentLogFile` out of `AppLog`:
    /// the append handle was opened write-only, so the separator check failed with
    /// EBADF, the append reported failure, and the caller replaced the whole file
    /// with the single newest line — losing all history on every log call.
    func testAppendingKeepsEarlierLines() {
        let url = makeTempLogURL()
        let file = PersistentLogFile(url: url, maxLines: 100, maxBytes: 1_000_000)

        file.append("first")
        file.append("second")
        file.append("third")

        let contents = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        let lines = contents.components(separatedBy: "\n").filter { !$0.isEmpty }
        XCTAssertEqual(lines, ["first", "second", "third"])
    }

    func testAppendCreatesTheFileWhenMissing() {
        let url = makeTempLogURL()
        PersistentLogFile(url: url, maxLines: 100, maxBytes: 1_000_000).append("only")

        XCTAssertEqual(
            (try? String(contentsOf: url, encoding: .utf8))?.trimmingCharacters(in: .newlines),
            "only"
        )
    }

    /// Files written by earlier versions end without a trailing newline. Appending
    /// must not run onto the end of the last line.
    func testAppendAddsTheMissingSeparatorForALegacyFile() throws {
        let url = makeTempLogURL()
        try "old one\nold two".write(to: url, atomically: true, encoding: .utf8)

        PersistentLogFile(url: url, maxLines: 100, maxBytes: 1_000_000).append("new")

        let lines = (try String(contentsOf: url, encoding: .utf8))
            .components(separatedBy: "\n").filter { !$0.isEmpty }
        XCTAssertEqual(lines, ["old one", "old two", "new"])
    }

    /// Over the ceiling the file is compacted well under it, so the rewrite is
    /// occasional rather than per-line — the other half of the 4 MB defect, where
    /// every call read and rewrote the whole file.
    func testFileIsCompactedOnceItExceedsItsByteCeiling() {
        let url = makeTempLogURL()
        let file = PersistentLogFile(url: url, maxLines: 10_000, maxBytes: 4_096)
        let line = String(repeating: "x", count: 200)

        for _ in 0..<100 { file.append(line) }

        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        XCTAssertLessThanOrEqual(size, 4_096)
        XCTAssertGreaterThan(size, 0, "compaction must not empty the file")
    }

    /// Compaction keeps the newest entries, which are the ones a crash report needs.
    func testCompactionKeepsTheNewestLines() {
        let url = makeTempLogURL()
        let file = PersistentLogFile(url: url, maxLines: 5, maxBytes: 200)

        for index in 0..<40 { file.append("line \(index)") }

        let contents = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        XCTAssertTrue(contents.contains("line 39"))
        XCTAssertFalse(contents.contains("line 0\n"))
    }

    // MARK: - Diagnostic export naming

    /// `TemporaryFileCleanupService` deletes by name, so the predicate has to be
    /// exact: these exports sat in tmp at ~9 MB each until nothing removed them.
    func testExportFileNameRecognition() {
        XCTAssertTrue(LogExporter.isExportFileName("BisonNotes-Logs-2026-08-30T18-15-13.txt"))
        XCTAssertFalse(LogExporter.isExportFileName("BisonNotes-Logs-2026-08-30T18-15-13.m4a"))
        XCTAssertFalse(LogExporter.isExportFileName("recording.txt"))
        XCTAssertFalse(LogExporter.isExportFileName("apprecording-1787583442.caf"))
    }
}
