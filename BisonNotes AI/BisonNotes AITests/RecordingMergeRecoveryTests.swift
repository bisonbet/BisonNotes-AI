//
//  RecordingMergeRecoveryTests.swift
//  BisonNotes AITests
//
//  Pins both production bugs that lived in the failed-merge disposition.
//

import XCTest
@testable import BisonNotes_AI

final class RecordingMergeRecoveryTests: XCTestCase {
    private let mainURL = URL(fileURLWithPath: "/Documents/recording.m4a")
    private let secondSegment = URL(fileURLWithPath: "/Documents/recording_seg2.m4a")
    private let thirdSegment = URL(fileURLWithPath: "/Documents/recording_seg3.m4a")
    private let backupURL = URL(fileURLWithPath: "/Documents/merge_backup_ABC.m4a")

    private var segments: [URL] { [mainURL, secondSegment, thirdSegment] }

    private func disposition(mergeCompleted: Bool) -> MergeFailureDisposition {
        RecordingMergeRecoveryPolicy.disposition(
            mergeCompleted: mergeCompleted,
            segments: segments,
            mainURL: mainURL,
            backupURL: backupURL
        )
    }

    // MARK: - Bug 1: preserving too much duplicated the recording

    /// After a completed merge, `mainURL` holds the finished output and the
    /// backup holds the original first segment. Snapshotting the whole set made
    /// the next recovery pass merge the completed recording together with its
    /// own inputs, so the saved audio contained everything twice.
    func testCompletedMergePreservesOnlyTheMergedOutput() {
        XCTAssertEqual(disposition(mergeCompleted: true).preserve, [mainURL])
    }

    /// The precise regression: neither the backup nor any source segment may
    /// appear in the snapshot once the merge has completed.
    func testCompletedMergeNeverPreservesItsOwnInputs() {
        let preserved = Set(disposition(mergeCompleted: true).preserve)

        XCTAssertFalse(preserved.contains(backupURL))
        XCTAssertFalse(preserved.contains(secondSegment))
        XCTAssertFalse(preserved.contains(thirdSegment))
    }

    // MARK: - Bug 2: releasing too little orphaned full-size audio

    /// The success path discards the backup and superseded sources only after
    /// Core Data acknowledges the merge. When the metadata save is what failed
    /// that never ran, so anything neither preserved nor released stayed on disk
    /// at full size with nothing referencing it — a later recovery saves only
    /// `mainURL` and retires the recovery state without reclaiming it.
    func testCompletedMergeReleasesTheBackupAndSupersededSources() {
        let result = disposition(mergeCompleted: true)

        XCTAssertEqual(result.releaseBackup, backupURL)
        XCTAssertEqual(result.releaseSegments, [secondSegment, thirdSegment])
    }

    /// Every artifact must be accounted for. Anything in neither list is exactly
    /// the orphan this policy exists to prevent.
    func testCompletedMergeLeavesNothingUnaccountedFor() {
        let result = disposition(mergeCompleted: true)
        let accountedFor = Set(result.preserve)
            .union(result.releaseSegments)
            .union(result.releaseBackup.map { [$0] } ?? [])

        XCTAssertEqual(accountedFor, Set(segments).union([backupURL]))
    }

    /// The merged output is never released — it is the only copy of the audio.
    func testCompletedMergeNeverReleasesTheMergedOutput() {
        let result = disposition(mergeCompleted: true)

        XCTAssertNotEqual(result.releaseBackup, mainURL)
        XCTAssertFalse(result.releaseSegments.contains(mainURL))
    }

    // MARK: - Before the merge completes, nothing may be released

    /// The export or the file swap failed, so there is no finished output and
    /// every surviving input is still load-bearing.
    func testIncompleteMergePreservesEveryInputAndReleasesNothing() {
        let result = disposition(mergeCompleted: false)

        // The backup sits at the main segment's position, not at the end — see
        // testBackupTakesTheMainSegmentPositionRatherThanBeingAppended.
        XCTAssertEqual(result.preserve, [mainURL, backupURL, secondSegment, thirdSegment])
        XCTAssertEqual(Set(result.preserve), Set(segments).union([backupURL]))
        XCTAssertNil(result.releaseBackup)
        XCTAssertTrue(result.releaseSegments.isEmpty)
    }

    /// When both halves of the file swap fail, the backup can be the only copy
    /// of the original first segment, so it must be preserved rather than
    /// treated as litter.
    func testIncompleteMergePreservesTheBackupAsARecoveryInput() {
        XCTAssertTrue(disposition(mergeCompleted: false).preserve.contains(backupURL))
    }

    /// The backup holds whatever was at `mainURL`, which is the *first* segment.
    /// Appending it meant that when the move aside succeeded and the move back
    /// failed, the existence filter dropped the missing `mainURL` and left
    /// [segment2, segment3, backup] — replaying the beginning of the recording
    /// at the end. It has to occupy `mainURL`'s position instead.
    func testBackupTakesTheMainSegmentPositionRatherThanBeingAppended() {
        let preserve = disposition(mergeCompleted: false).preserve

        guard let backupIndex = preserve.firstIndex(of: backupURL),
              let secondIndex = preserve.firstIndex(of: secondSegment) else {
            return XCTFail("Expected both the backup and the later segments: \(preserve)")
        }
        XCTAssertLessThan(
            backupIndex, secondIndex,
            "The backup stands in for the first segment and must precede later ones"
        )
    }

    /// The surviving half of the pair keeps the first position either way, so
    /// dropping whichever file is absent still yields the recording's real order.
    func testEitherSurvivorOfTheSwapLeadsTheRecoveryOrder() {
        let preserve = disposition(mergeCompleted: false).preserve

        // The move-back succeeded: the backup is gone, mainURL survives.
        XCTAssertEqual(
            preserve.filter { $0 != backupURL },
            [mainURL, secondSegment, thirdSegment]
        )
        // The move-back failed: mainURL is gone, the backup holds segment one.
        XCTAssertEqual(
            preserve.filter { $0 != mainURL },
            [backupURL, secondSegment, thirdSegment]
        )
    }

    /// A backup recorded for a merge whose segment list does not name `mainURL`
    /// still has to survive, even though there is no position to substitute.
    func testBackupIsStillPreservedWhenTheMainSegmentIsNotListed() {
        let result = RecordingMergeRecoveryPolicy.disposition(
            mergeCompleted: false,
            segments: [secondSegment, thirdSegment],
            mainURL: mainURL,
            backupURL: backupURL
        )

        XCTAssertTrue(result.preserve.contains(backupURL))
    }

    // MARK: - Shapes the merge can actually produce

    /// A merge with no backup (nothing existed at `mainURL` to move aside)
    /// still releases its superseded sources.
    func testCompletedMergeWithoutABackupStillReleasesSources() {
        let result = RecordingMergeRecoveryPolicy.disposition(
            mergeCompleted: true,
            segments: segments,
            mainURL: mainURL,
            backupURL: nil
        )

        XCTAssertEqual(result.preserve, [mainURL])
        XCTAssertNil(result.releaseBackup)
        XCTAssertEqual(result.releaseSegments, [secondSegment, thirdSegment])
    }

    /// Path spelling must not decide identity: a segment list carrying an
    /// unstandardized `mainURL` must still recognize it as the merged output
    /// rather than releasing the recording.
    func testMergedOutputIsMatchedByStandardizedPath() {
        let unstandardized = URL(fileURLWithPath: "/Documents/./recording.m4a")
        let result = RecordingMergeRecoveryPolicy.disposition(
            mergeCompleted: true,
            segments: [unstandardized, secondSegment],
            mainURL: mainURL,
            backupURL: nil
        )

        XCTAssertEqual(result.releaseSegments, [secondSegment])
    }
}
