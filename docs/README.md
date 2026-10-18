# Documentation index

Reviewed on 2026-10-18 for version 3.0. This index tells apart current
documentation, engineering records that are still active, and files that have
been retired. Retiring a plan does not mean its manual or release gates passed;
the testing and evidence documents below are still authoritative for those.

## Product documentation

- [Features and usage](features.md): how each feature works in 3.0.
- [User guides](user-guide/README.md): one complete guide per app release,
  which in-app Help opens for the installed version, plus the publishing
  process and the website's redirect setup.
- [Release history](release-history.md): highlights by release.
- [Mistral AI free setup](mistral-free-setup.md).

## Development and release

- [Development](development.md): requirements, build and test, architecture,
  configuration, and the CloudKit schema.
- [Regression testing regimen](testing-regimen.md): where release validation
  starts. It separates source, build, simulator/XCTest, signed-app, hardware,
  provider, CloudKit, accessibility, and two-device evidence.
- [Accessibility matrix](accessibility-matrix.md), [App Store accessibility
  notes](app-store-accessibility.md), and the [public accessibility
  page](accessibility.html).

## Active engineering records

These stay because they hold an open acceptance gate, a compatibility contract,
or evidence that isn't recorded anywhere else:

- [v3.0 reliability hardening](v3.0-reliability-hardening-plan.md), its phase
  records ([phase 0](v3.0-reliability-hardening-phase0.md),
  [B1](v3.0-reliability-hardening-b1.md), [B2](v3.0-reliability-hardening-b2.md),
  [C](v3.0-reliability-hardening-c.md), [D](v3.0-reliability-hardening-d.md),
  [E](v3.0-reliability-hardening-e.md)), and the
  [qualification record](v3.0-reliability-hardening-qualification.md), which is
  not yet release qualified.
- [Post-commit convention](post-commit-convention-plan.md): the background to
  the `afterCommit` rule in `CLAUDE.md`.
- [Local speaker labels](local-speaker-labels-delegation-plan.md): the
  completed-file workflow, plus model, license, quality, performance, and
  accessibility gates.
- [Transcript cleanup](transcript-cleanup-implementation-plan.md): the contract
  for original and cleaned text, with physical-model and two-device checks still
  pending.
- [Live transcription callback fix](live-transcription-callback-fix.md):
  diagnostic history.

## Retired files

These were removed because their work is finished or their instructions are
out of date. Their contents are still in Git history; no history was rewritten.

| Retired file | Removed in |
| --- | --- |
| `accessibility-implementation-plan.md`, `advanced-troubleshooting-implementation-plan.md`, `macos-migration-plan.md`, `swift-6-migration-delegation-plan.md`, `v2.4-dead-code-cleanup-delegation-plan.md`, `v2.5-follow-up-agent-plan.md` | v2.5 documentation cleanup |
| `code-quality-cleanup-delegation-plan.md`, `for-v2.5.md`, `icloud-sync-performance-plan.md`, `ios-audio-interruption-recovery-delegation-plan.md`, `issue-106-av-sync-test-regimen.md`, `llama-cpp-removal-migration.md`, `macos-phase-3-exit-report.md`, `macos-phase-3.3-deferred-parity-audit.md`, `macos-phase-4.1-data-continuity-report.md`, `macos-window-presentation-audit.md`, `macos-window-ux-delegation-plan.md`, `swift-6-migration-evidence.md` | Commit `5fa21603` ("Clean up a lot of dead files") |

The iCloud sync rules from the retired performance plan are now recorded in
`CLAUDE.md` and covered by tests.

## Safeguards kept after cleanup

Cleaning up documentation is not permission to remove runtime migration,
recovery, `.location` sidecar, attachment, archive-bookmark, CloudKit tombstone,
Watch transfer, or legacy-provider compatibility code. A failed read is not an
empty library, missing audio is not proof that something was deleted, and a
build or simulator run is not proof from a signed device, hardware, a provider,
CloudKit, or an accessibility check. Any future storage migration must keep
those boundaries and use the current testing regimen.
