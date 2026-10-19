# Post-review fix wave report

## Outcome

Implemented the consolidated review fixes for the migration safety experience. The normal manual app-migration routes now share the reviewed-plan flow; cancellation, capacity, batch, progress, and terminal-task presentation no longer overstate what the service has proved. `AppMigrator.validateTarget` and the migration filesystem/rollback/journal/cancellation behavior were left unchanged.

## Findings mapped to changes

1. **Manual migration entry points bypassed plan review / space-free destinations could be flattened.**
   - `AppRowView`'s normal “迁移” action, selected-app migration in `AppListView`, the MigrationPanel batch action, and Health Check retry now submit `MigrationPlanRequest`s to the shared review sheet.
   - `SpaceFreePlanSheet` now returns explicit `(app, destination)` assignments. The request and summary retain each app's destination, and execution uses each reviewed item's own `destinationPath` and `createsLink`.
   - Offline volume metadata is retained long enough for review to block the selected UUID. A different disk reusing the same mount path is not substituted when a stable UUID was captured.
   - `AutoRemigrateService` remains a direct, non-interactive background flow; no review sheet was added to it.

2. **Cancellation copy claimed source safety and cleanup for recovery-required results.**
   - Only `cancelled == true`, `success == false`, and `error == "已取消"` maps to the safe-cancel result.
   - Other cancelled results preserve the service error and map to recovery-required copy. A legacy `.cancelled` task without a result also maps conservatively; it does not claim the source or partial-copy state is safe.
   - The in-progress stop label now says the UI is waiting for file-state confirmation rather than promising safe cleanup before the service returns.

3. **Review copy assumed same-volume backup and checked per-item capacity only.**
   - Added a side-effect-free capacity fact helper derived from the same backup-root convention and byte formulas used by the existing service validation.
   - The review presents same-volume or alternate-volume backup placement and the relevant capacity for each volume. It aggregates all plan items by volume before declaring the plan ready, including shared alternate backup capacity.
   - `AppMigrator.validateTarget` remains the live service-time authority and was not edited; plan facts are advisory and can become stale after approval.

4. **MigrationPanel retained only the last batch outcome.**
   - Added per-item results with pending, succeeded, failed, cancelled, and not-started states. The reviewed batch records every service outcome, continues after ordinary failures, stops on cancellation/recovery interruption, and marks remaining items not started.
   - The execution card renders the complete result list instead of replacing earlier outcomes with the latest one.

5. **Progress callbacks lacked actual phase values and could leave or regress the phase display.**
   - Extended `AppMigrator.migrate` / `migrateInternal` with an optional phase-progress callback for actual preflight, copy, verification, and backup/switch points; the existing progress callback remains source-compatible.
   - Legacy callbacks advance the display to copy, while service phases are monotonic and callback updates are scoped to the task ID so delayed callbacks cannot update a later task. Stage changes update their labels even when percentage updates are throttled.
   - The stage labels now describe the service's actual order; no startup verification phase was invented.

6. **Legacy, restore, and retry terminal tasks could lose the card or display stale results.**
   - `AppState` associates outcomes with task IDs, synthesizes a conservative fallback from terminal task status when a producer has no result, and clears stale outcomes when a new task begins.
   - Fallback titles distinguish migration, restore, relocation, and uninstall; failure details retain the task's real error. Completed restore/legacy paths now set terminal status before clearing the task where needed.

## RED / GREEN evidence

- **Initial RED:** the new presentation tests were run before the implementation and failed to compile because the assignment model, detailed phase type, recovery-required outcome, and batch result model did not yet exist.
- **First implementation RED:** the focused suite exposed three assertion failures: the test incorrectly expected a same-volume capacity budget not to include its backup role (it correctly does), and two checks found safe-cleanup wording in a cancelled-task fallback. The expectation and fallback copy were corrected.
- **Volume-identity RED:** `testReviewedPlanDoesNotSubstituteDifferentVolumeAtReusedMountPoint` failed with “expected blocked” while UUID lookup fell back to a reused path. Strict UUID matching fixed it.
- **Aggregate-capacity RED:** both shared-destination and shared-alternate-backup tests failed with “expected blocked” when each item's capacity fit individually but the total plan did not. Per-volume aggregation fixed both.
- **Focused GREEN:**
  `swift test --scratch-path /Volumes/Samsung990/Projects/suishouqian-xcode/.build --filter 'MigrationPlanPresentationTests|CancellationTests|MigrationPlannerTests'`
  — 37 tests, 0 failures (24 presentation, 6 cancellation, 7 planner tests).
- **Full GREEN:**
  `swift test --scratch-path /Volumes/Samsung990/Projects/suishouqian-xcode/.build`
  — 271 tests, 0 failures.
- **Build:**
  `swift build --scratch-path /Volumes/Samsung990/Projects/suishouqian-xcode/.build`
  — succeeded.
- **Diff hygiene:** `git diff --check` — passed.

The first repeated test attempt also hit a transient I/O error in the shared Swift build database; a rerun succeeded, and the final full test and build runs completed successfully.

## Changed files

- `Sources/Suishouqian/App.swift`
- `Sources/Suishouqian/Models/AppItem.swift`
- `Sources/Suishouqian/Services/AppMigrator.swift`
- `Sources/Suishouqian/Services/AutoRemigrateService.swift`
- `Sources/Suishouqian/Views/AppListView.swift`
- `Sources/Suishouqian/Views/AppRowView.swift`
- `Sources/Suishouqian/Views/HealthCheckView+Advisors.swift`
- `Sources/Suishouqian/Views/HealthCheckView+Issues.swift`
- `Sources/Suishouqian/Views/MigrationExecutionView.swift`
- `Sources/Suishouqian/Views/MigrationPanel.swift`
- `Sources/Suishouqian/Views/MigrationPlanPresentation.swift`
- `Sources/Suishouqian/Views/MigrationPlanReviewSheet.swift`
- `Sources/Suishouqian/Views/OverviewPanel.swift`
- `Sources/Suishouqian/Views/SpaceFreePlanSheet.swift`
- `Tests/SuishouqianTests/MigrationPlanPresentationTests.swift`

No dependency or lockfile changes were made.

## Self-review

- Reviewed the `AppMigrator.swift` diff: changes are limited to the pure capacity facts, the optional progress contract, and phase notifications. There is no diff inside `validateTarget`; filesystem mutations, rollback decisions, journal writes, and cancellation branches remain as before.
- Searched all direct `migrator.migrate` call sites. The standard manual “迁移” routes use the shared plan review. Remaining direct paths are the explicit automated remigration background flow, the history undo/recovery path, and the pure-relocation helper; they are not the normal manual migration entry points under this finding.
- Per-volume review capacity is advisory and aggregates current free-space snapshots. The existing service validation still rechecks actual capacity immediately before migration.
- The batch-result test exercises the result-state mapping for early failure, later success, cancellation, and not-started rows. The UI path itself remains a SwiftUI interaction and is not driven by an end-to-end UI automation test in this package.

## Residual concerns

- A disk can be removed or its free space can change between review and execution; the existing service-time validation remains responsible for safely rejecting that state.
- Existing compiler warnings in unrelated code were present during test compilation; they did not prevent the full suite or build from succeeding.

---

# Round 2 post-review fix wave (2026-10-19)

## Context

The first wave was re-reviewed at `e6988a1` and returned **Request changes** with three Important and three Minor findings. A second fix wave started on the same worktree; the previous agent hit its usage limit mid-wave, leaving uncommitted edits and no final verification. This wave completed that work.

## Findings mapped to changes

1. **Pure relocation still bypassed plan review** — `AppRowView.moveToExternal` now submits `MigrationPlanRequest(apps: [app], createsLink: false)`. The reviewed execution path is the only manual dispatcher; `runRelocation`/`moveToExternal` custom chain is gone. `createsLink` is carried through `MigrationPlanRequestItem` and `MigrationPlanItem`, and the review sheet shows the “建链/不建链” outcome.
2. **Reviewed destination identity was a path, not a volume** — `MigrationPlanItem` now carries `destinationVolumeUUID`. Execution re-reads the UUID from the reviewed mount path for the whole batch before any item starts and again immediately before each dispatch (`MigrationPanel.executeReviewedPlan`). `AppMigrator.validateTarget` takes `expectedVolumeUUID` and re-reads it at the write boundary, before any filesystem mutation. Plans whose destination UUID cannot be read are blocked at review time rather than approved and rejected later.
3. **Legacy paths did not report real phases** — `relocate`, `relocateCore`, `restore`, `moveBackToInternal`, and the legacy `migrate` paths now report actual `MigrationPhase` values through an optional `phaseProgress` callback; every direct caller (row restore/relocate/move-back, list restore, migration panel, retire wizard, history undo) passes it. Legacy progress callbacks advance to the neutral `.transferring` phase, rendered as “正在传输”; no unknown operation is labelled as copy/verify/switch.
4. **Restore success showed “已释放 0 B”** — `MigrationOutcome` exposes `reportedFreedBytes` only when the service reported a positive value; success cards and accessibility labels omit the amount otherwise. Restore flows still do not retain the service result, so a real positive amount is not displayed (see residual concerns).
5. **Single reviewed-batch success lost “查看应用”** — `MigrationPlanPresentation.shouldOfferOpenAppsAction` keeps the shortcut for one successful item; per-item results still take precedence for multi-item batches.
6. **Duplicate App Store confirmation** — the App Store consequence and guidance are now rendered inside the single plan-review sheet (`updateImpactCard`). `HealthCheckView+Issues` and `AppRowView` no longer pre-alert before opening the sheet; `MigrationAdvisor.confirmRelocation` was removed. Batch selection still uses one `resolveBatch` decision, because it chooses which apps to include rather than confirming a plan.

## Additional hardening found during verification

- `MigrationPanel` now associates a destination-identity failure with the current task ID, so clearing `migrationTask` at the end of the batch cannot replace the failure card with the previous task’s fallback outcome.
- `AppState.isMigrationActive` includes `isExecutingReviewedPlan`, closing the pre-check window in which the batch had started but no task existed yet and row actions were still enabled. Every remaining `migrationTask == nil/!= nil` gate that controls whether a **new** operation can start (migration panel primary/secondary actions, retire wizard, history undo, selected-app buttons, space-free confirmation) now uses `!isMigrationActive`.
- Batch interruption copy says “本批剩余条目未开始” instead of “其余”, so it stays truthful when earlier items already completed.
- `updateImpactCard` gates on `updateMechanism == .appStore` rather than on `updateConsequence(linkBack:) != nil`. App Store items derive `createsLink == false`, for which `updateConsequence` returns nil; gating on it made the card unreachable. The card now always shows the App Store guidance and adds the extra link-back consequence only when it applies.
- `executeReviewedPlan` rejects a second approved plan while a batch is already executing (`!isMigrationActive`).

## RED / GREEN evidence

- **RED 1:** `Tests/SuishouqianTests/CancellationTests.swift` no longer compiled after `validateTarget` gained `expectedVolumeUUID`; the override signature was updated.
- **RED 2:** `testRelocateCoreMovesCopyVerifiesAndRemovesSource` asserted an exact phase array, but ditto reports several copy progress callbacks; the assertion now deduplicates consecutive phases before comparing the monotonic order.
- **GREEN (focused):** `swift test --filter 'MigrationPlanPresentationTests|CancellationTests|MigrationPlannerTests|RelocateTests'` — 45 tests, 0 failures.
- **GREEN (full):** `swift test --scratch-path /Volumes/Samsung990/Projects/suishouqian-xcode/.build` — **278 tests, 0 failures**.
- **Build:** `swift build --scratch-path /Volumes/Samsung990/Projects/suishouqian-xcode/.build` — succeeded.
- **Diff hygiene:** `git diff --check` — passed.

## Changed files in this wave

- `Sources/Suishouqian/App.swift`
- `Sources/Suishouqian/Models/AppItem.swift`
- `Sources/Suishouqian/Services/AppMigrator.swift`
- `Sources/Suishouqian/Views/AppListView.swift`
- `Sources/Suishouqian/Views/AppRowView.swift`
- `Sources/Suishouqian/Views/HealthCheckView+Advisors.swift`
- `Sources/Suishouqian/Views/HealthCheckView+Issues.swift`
- `Sources/Suishouqian/Views/MigrationAdvisor.swift`
- `Sources/Suishouqian/Views/MigrationExecutionView.swift`
- `Sources/Suishouqian/Views/MigrationPanel.swift`
- `Sources/Suishouqian/Views/MigrationPlanPresentation.swift`
- `Sources/Suishouqian/Views/MigrationPlanReviewSheet.swift`
- `Sources/Suishouqian/Views/OverviewPanel.swift`
- `Sources/Suishouqian/Views/SpaceFreePlanSheet.swift`
- `Tests/SuishouqianTests/CancellationTests.swift`
- `Tests/SuishouqianTests/MigrationPlanPresentationTests.swift`
- `Tests/SuishouqianTests/RelocateTests.swift`

## Residual concerns

- Restore/retire flows do not retain the service’s `spaceSaved`; the UI suppresses the amount instead of showing a wrong “0 B”. The prior review allowed either preserving the result or suppressing the amount.
- Review capacity facts are snapshots; `AppMigrator.validateTarget` remains the live authority at write time.
- `DataMigrator` progress still uses the legacy callback and therefore renders the neutral “传输中” phase rather than data-specific phases.
- The UUID check pins the reviewed volume at execution and at the write boundary; it cannot detect a cloned volume that presents the same UUID (outside this review’s threat model).
- The SwiftUI review sheet itself is not covered by end-to-end UI automation in this package; the pure presentation logic is unit tested.

## Verification status

`swift build` succeeded; full suite 278 tests / 0 failures; `git diff --check` clean. Independent re-review by a read-only reviewer: **merge-ready** — all six findings closed or accepted as the documented residual, no Critical/Important, one duplicate-SwiftUI-ID nit in the update-impact card fixed before commit.
