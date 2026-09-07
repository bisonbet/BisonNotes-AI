# Documentation index

Reviewed on 2026-09-07 from branch `v2.5` at
`c0eecb4673e3bc7c09fd9e80d4c15c263c7f86c2`. This index records the documentation
cleanup so a future agent can distinguish a current contract from an old
execution checklist. Removing a plan does not certify its manual or release
gates; the retained evidence and testing documents remain authoritative for
those gates.

## Current product and release documentation

- [Full user guide](bisonnotes-ai-guide.html), versioned release guides
  (`bisonnotes-ai-v2-2.html` through `bisonnotes-ai-v2-5.html`), and
  [Mistral setup](mistral-free-setup.md) are user-facing documentation.
- [Regression testing regimen](testing-regimen.md) is the current validation
  entry point. It separates source, build, simulator/XCTest, signed-app,
  hardware, provider, CloudKit, accessibility, and two-device evidence.
- [Accessibility matrix](accessibility-matrix.md), [App Store accessibility
  artifact](app-store-accessibility.md), and [public accessibility page](accessibility.html)
  are current product/release artifacts.
- [For v2.5](for-v2.5.md) records the implemented follow-ups and their remaining
  release gates; it is retained until that release history is no longer useful.

## Retained engineering contracts and evidence

These files remain because they contain an unresolved acceptance gate, a
compatibility contract, or unique evidence that is not reproduced elsewhere:

- [iCloud sync performance](icloud-sync-performance-plan.md): implemented
  batching/manifest/deletion rules plus the outstanding signed two-device matrix.
- [iOS interruption recovery](ios-audio-interruption-recovery-delegation-plan.md):
  recovery ownership, segment-preservation rules, an unresolved platform cause,
  and physical-phone cases.
- [Local speaker labels](local-speaker-labels-delegation-plan.md): completed-file
  workflow and model/license/quality/performance/accessibility gates.
- [Native Mac window UX](macos-window-ux-delegation-plan.md): detailed close,
  editing, settings, and remaining manual presentation checks.
- [Code quality and hardening](code-quality-cleanup-delegation-plan.md): an
  unfinished backlog containing credential, migration, and caller-verification
  work; it is not treated as completed merely because some packages landed.
- [Transcript cleanup](transcript-cleanup-implementation-plan.md): implemented
  original/cleaned-text contract and still-pending physical model and
  two-device checks.
- [Live transcription callback fix](live-transcription-callback-fix.md) and
  [llama.cpp compatibility migration](llama-cpp-removal-migration.md): diagnostic
  provenance and upgrade compatibility, respectively.
- [Swift 6 evidence](swift-6-migration-evidence.md): target/build history and
  the signed, hardware, provider, CloudKit, and accessibility limits of that
  evidence.
- [Native Mac phase 3 exit](macos-phase-3-exit-report.md), [phase 3.3 parity
  audit](macos-phase-3.3-deferred-parity-audit.md), [phase 4.1 continuity
  report](macos-phase-4.1-data-continuity-report.md), and [window presentation
  audit](macos-window-presentation-audit.md): historical validation and data/
  presentation evidence relevant to future storage work.
- [Issue #106 A/V test regimen](issue-106-av-sync-test-regimen.md): the signed
  native-Mac capture and salvage gate.

## Retired execution plans

These files were removed from the active `v2.5` documentation set because their
implementation work is complete or their instructions are superseded. Their
exact contents remain recoverable from Git history; no history was rewritten.

| Retired file | Reason |
| --- | --- |
| `accessibility-implementation-plan.md` | Its proposed support layer, audit tests, matrix, and public artifact now exist; current acceptance lives in the retained accessibility files and testing regimen. |
| `advanced-troubleshooting-implementation-plan.md` | The implementation landed in PR #128 and later fixes; the old handoff still incorrectly says implementation has not been performed. |
| `macos-migration-plan.md` | Native macOS cutover is complete; continuity, parity, exit, and current testing documents carry the useful evidence and remaining gates. |
| `swift-6-migration-delegation-plan.md` | Swift 6 target work is recorded in the retained evidence ledger and current testing regimen; the old checklist is no longer an execution source. |
| `v2.4-dead-code-cleanup-delegation-plan.md` | The v2.4 deletion work was integrated; its old candidate/line lists must not be rerun against current source. |
| `v2.5-follow-up-agent-plan.md` | The follow-up implementation is recorded in `for-v2.5.md`; its execution checklist is historical. |

## Safeguards retained after cleanup

Documentation cleanup does not authorize removing runtime migration, recovery,
`.location` sidecar, attachment, archive-bookmark, CloudKit tombstone, Watch
transfer, or legacy-provider compatibility code. A failed read is not an empty
library, missing audio is not proof of deletion, and a build or simulator run is
not signed-device, hardware, provider, CloudKit, or accessibility proof. Any
future storage migration must preserve those boundaries and use the current
testing regimen plus the source-of-truth contracts above.
