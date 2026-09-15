//
//  RecordingMergeRecovery.swift
//  BisonNotes AI
//
//  What a failed segment merge keeps and what it releases.
//

import Foundation

/// The disposition of every artifact a failed merge leaves behind.
///
/// Split by removal mechanism rather than into one list: the backup is an
/// owned recording-attempt artifact and the sources are segment files, and the
/// two are retired through different calls.
struct MergeFailureDisposition: Equatable, Sendable {
    /// Artifacts the deferred recovery snapshot must point at, so a later pass
    /// can reclaim them.
    let preserve: [URL]
    /// The merge backup to discard, if it is no longer the only copy of
    /// anything.
    let releaseBackup: URL?
    /// Source segments whose audio now lives inside a preserved artifact.
    let releaseSegments: [URL]
}

/// Decides what survives when a segment merge fails.
///
/// Both halves of this have been wrong in production, in the same few lines,
/// and they fail in opposite directions — which is why the decision lives here
/// as one value rather than as two independent statements at the call site.
///
/// - **Preserving too much duplicates the recording.** Once the merge has
///   completed, `segments` no longer describes inputs: its `mainURL` entry *is*
///   the finished output that replaced the original first segment, and the
///   backup holds that original. Snapshotting the whole set made the next
///   recovery pass merge the completed recording together with its own inputs.
/// - **Releasing too little orphans full-size audio.** The success path
///   discards the backup and the superseded sources only once Core Data
///   acknowledges the merge. When the metadata save is what failed, that never
///   ran — so anything neither preserved nor released is left on disk with
///   nothing referencing it, and a later recovery that saves only `mainURL`
///   retires the recovery state without ever reclaiming it.
///
/// Before the merge completes there is no finished output, so every surviving
/// input is still load-bearing and nothing may be released.
enum RecordingMergeRecoveryPolicy {
    static func disposition(
        mergeCompleted: Bool,
        segments: [URL],
        mainURL: URL,
        backupURL: URL?
    ) -> MergeFailureDisposition {
        guard mergeCompleted else {
            // The export or the file swap failed, so there is no finished output
            // and every surviving input is still load-bearing.
            guard let backupURL else {
                return MergeFailureDisposition(
                    preserve: segments,
                    releaseBackup: nil,
                    releaseSegments: []
                )
            }

            // The backup stands in for `mainURL`, so it takes that position
            // rather than being appended. `mainURL` is the *first* segment: if
            // the move aside succeeded and the move back then failed, appending
            // the backup left `preserveFailedMergeSegments` filtering out the
            // now-missing `mainURL` and snapshotting the inputs in the order
            // [segment2, segment3, backup] — which replays the beginning of the
            // recording at the end.
            //
            // Keeping both entries is safe because at most one of them exists:
            // the backup is created by *moving* `mainURL` aside and removed by
            // moving it back, so the pair is never on disk together and the
            // caller's existence filter selects whichever survived.
            var preserve: [URL] = []
            var didSubstitute = false
            for segment in segments {
                preserve.append(segment)
                if segment.standardizedFileURL == mainURL.standardizedFileURL {
                    preserve.append(backupURL)
                    didSubstitute = true
                }
            }
            if !didSubstitute {
                preserve.append(backupURL)
            }
            return MergeFailureDisposition(
                preserve: preserve,
                releaseBackup: nil,
                releaseSegments: []
            )
        }

        // The merged output is at `mainURL` and contains every input's audio.
        return MergeFailureDisposition(
            preserve: [mainURL],
            releaseBackup: backupURL,
            releaseSegments: segments.filter {
                $0.standardizedFileURL != mainURL.standardizedFileURL
            }
        )
    }
}
