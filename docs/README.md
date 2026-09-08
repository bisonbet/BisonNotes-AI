# Documentation index and v3.0 planning cleanup

Reviewed on 2026-09-07 against `v2.5` at
`d64660ba85dc04e6bc2f1fa88263427cb76b37aa`; the storage plan is on `v3.0`.
Removing an execution plan does not certify its historical manual tests or retire
compatibility code. Historical branch names, prompts and file/line inventories in
retained plans are context, not instructions to reset or rerun completed work.

## Start here

- [SQLite migration plan](sqlite-migration-plan.md): v3.0 storage design, safe migration, backups, sync boundaries, implementation phases and release gates.
- [SQLite migration inventory](sqlite-migration-inventory.md): both Core Data model versions, every attribute/relationship and persistence touchpoints.
- [SQLite migration evidence ledger](sqlite-migration-evidence.md): Phase 0 runtime storage boundary, provenance, baseline commands and decisions still required before backend selection.
- [Regression testing regimen](testing-regimen.md): current build, automated and physical-device release checks.
- [Accessibility matrix](accessibility-matrix.md) and [App Store accessibility](app-store-accessibility.md): current accessibility contracts and evidence boundaries.
- [Current user guide](bisonnotes-ai-guide.html) and [v2.5 release guide](bisonnotes-ai-v2-5.html): user-facing behavior. Older v2.2/v2.3/v2.4 guides remain historical release references.

## Current engineering references

These checked-in files remain relevant to product behavior or migration safety:

| Document | Why it remains |
| --- | --- |
| [Local speaker labels](local-speaker-labels-delegation-plan.md) | Model, accuracy, performance, accessibility, and hardware constraints remain useful when validating transcript data. |
| [Transcript cleanup](transcript-cleanup-implementation-plan.md) | Defines the original/cleaned text preservation contract and physical model/two-device gates. |
| [Live transcription callback fix](live-transcription-callback-fix.md) | Preserves diagnostic provenance and the limits of crash attribution. |
| [Mistral setup](mistral-free-setup.md) | User-facing provider setup instructions. |

Older engineering plans and evidence ledgers were retired from the active v2.5
documentation set. Their exact contents remain recoverable from Git history;
this cleanup does not retire runtime compatibility, migration, backup, sync, or
hardware requirements.

## Removed execution plans

The following files were removed because their implementation instructions were
superseded. Retrieve their exact prior contents with `git show <commit>:docs/<filename>`;
the six-file cleanup was recorded in `6d94fc5d`, and the later historical-docs
cleanup in `5fa21603`. No history was rewritten.

| Removed file | Evidence / retained replacement |
| --- | --- |
| `swift-6-migration-delegation-plan.md` | Its migration target matrix and final runs are historical; old wave/delegation instructions no longer control work. |
| `macos-migration-plan.md` | Its Phase 4.3 says cutover implemented; native-only targets are current. Retain continuity, exit and parity reports; current testing regimen replaces old Catalyst build loops. |
| `accessibility-implementation-plan.md` | Proposed matrix, support helpers, audit suite and public artifacts exist. Current matrix, App Store artifact and testing regimen preserve acceptance requirements; deletion does not assert all manual checks passed. |
| `v2.5-follow-up-agent-plan.md` | Implementation merged in PR #126 (`78e09b7c`); its execution checklist is historical. |
| `v2.4-dead-code-cleanup-delegation-plan.md` | Release README records dead-code implementation complete; old file/line candidate lists must not be rerun. Unchosen policy/retirement decisions are carried forward below. |
| `advanced-troubleshooting-implementation-plan.md` | Implementation merged in PR #128 (`cdaf1563`) with subsequent race fixes; current service/tests enforce behavior. Maintenance safeguards are retained below. |

The later cleanup also retired `code-quality-cleanup-delegation-plan.md`,
`for-v2.5.md`, `icloud-sync-performance-plan.md`,
`ios-audio-interruption-recovery-delegation-plan.md`,
`issue-106-av-sync-test-regimen.md`, `llama-cpp-removal-migration.md`, the
macOS phase/window reports, `macos-window-ux-delegation-plan.md`, and
`swift-6-migration-evidence.md`. Recover those files from commit `5fa21603`
when historical context is needed; do not treat their deletion as proof that
the associated runtime or release gates are complete.

## Carried-forward safeguards and unresolved work

Advanced Troubleshooting stays read-only until the user selects and confirms
specific unreferenced audio. Recheck ownership, file identity, active recording/
combine/restore work and maintenance reservations at deletion time. A failed
fetch/scan is an error, never evidence of an empty library. Archives, external
media, detached metadata, sidecars, local-only records and in-flight files need
explicit classification. Local cleanup must not publish cloud tombstones. Keep
coordinated cloud erase, partial-failure reporting and fresh-backup behavior;
opening diagnostics must never erase or repair data automatically. The v3.0 plan
adds a storage/migration gate to these existing protections.

The retired dead-code plan did **not** decide whether to remove coming-soon engine
state, expose or remove unused cloud-conflict strategies, or redesign ownership of
`EnhancedErrorHandler`. Those remain separately scoped choices requiring current
call-site evidence. In particular, no `.location` fallback or legacy startup
migration is retired by this documentation cleanup; that requires a supported
upgrade-floor decision, lossless migration and recovery tests. Source cleanup
still requires runtime/target/persistence checks, not just a search with no hits.

Native macOS follow-up remains: signed permission/recording cases (including Poly
Sync 10 and hot swap), long hidden-window jobs, archive bookmark restoration,
share/widgets and Settings walkthrough. See the retained reports and current
regimen; this cleanup does not mark them complete. Likewise keep physical
accessibility, provider/model and two-device CloudKit gates separate from build
success. Previously blocked test runs remain historical limitations until rerun.
