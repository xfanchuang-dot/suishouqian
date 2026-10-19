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
